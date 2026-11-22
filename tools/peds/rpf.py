import mmap
import os
import struct
import zlib
import bisect

HOME = os.path.expanduser("~/testing")
CHAINED = 0x800000


class Entry:
    __slots__ = ("offset", "size", "unpacked", "kind", "head")

    def __init__(self, offset, size, unpacked, kind, head):
        self.offset = offset
        self.size = size
        self.unpacked = unpacked
        self.kind = kind
        self.head = head


class Archive:
    def __init__(self, rpf, idx):
        self.f = open(rpf, "rb")
        self.m = mmap.mmap(self.f.fileno(), 0, access=mmap.ACCESS_READ)
        with open(idx, "rb") as fh:
            d = fh.read()
        magic, ver, size, count, _ = struct.unpack_from("<4sIQQQ", d, 0)
        assert magic == b"RPXI" and ver == 3
        self.entries = []
        for i in range(count):
            o = 32 + 80 * i
            off, sz, unp, kind, pad, hl = struct.unpack_from("<QQQBBB", d, o)
            head = d[o + 32:o + 32 + hl]
            self.entries.append(Entry(off, sz, unp, kind, head))
        self.offsets = [e.offset for e in self.entries]

    def entry_index(self, off):
        i = bisect.bisect_left(self.offsets, off)
        if i < len(self.offsets) and self.offsets[i] == off:
            return i
        return None

    def load(self, e):
        return zlib.decompressobj().decompress(self.m[e.offset:e.offset + e.size])

    def is_start(self, i):
        e = self.entries[i]
        if e.kind != 2 or len(e.head) < 16 or any(e.head[:8]):
            return False
        v = struct.unpack_from("<Q", e.head, 8)[0]
        if (v >> 32) != 0 or (v >> 28) != 5:
            return False
        if i == 0:
            return True
        p = self.entries[i - 1]
        return not (p.kind == 2 and (p.offset + p.size + 15) & ~15 == e.offset)

    def run(self, start):
        r = [start]
        i = start + 1
        while len(r) < 64 and i < len(self.entries):
            prev = self.entries[r[-1]]
            e = self.entries[i]
            if e.kind != 2 or e.offset != (prev.offset + prev.size + 15) & ~15 or self.is_start(i):
                break
            r.append(i)
            i += 1
        return r

    @staticmethod
    def is_bulk(e):
        return e.unpacked > 0 and e.unpacked % 0x10000 == 0

    def bulk_end(self, r, k):
        j = k
        while j < len(r) and self.entries[r[j]].unpacked == CHAINED:
            j += 1
        if j < len(r) and self.is_bulk(self.entries[r[j]]) and self.entries[r[j]].unpacked != CHAINED:
            j += 1
        return j

    def resource(self, off, physical=True):
        start = self.entry_index(off)
        assert start is not None, hex(off)
        r = self.run(start)
        vb = max(self.bulk_end(r, 0), 1)
        data = b"".join(self.load(self.entries[i]) for i in r[:vb])
        vc = vb
        if vb < len(r) and not self.is_bulk(self.entries[r[vb]]) and self.is_bulk(self.entries[r[0]]):
            tail = self.entries[r[vb]].unpacked
            if vb + 1 < len(r) or points_into(data, len(data), len(data) + tail):
                vc = vb + 1
        if vc > vb:
            data += self.load(self.entries[r[vb]])
        pc = vc
        if vc < len(r):
            pc = self.bulk_end(r, vc)
            if pc < len(r) and not self.is_bulk(self.entries[r[pc]]):
                pc += 1
        phys = b""
        if physical:
            phys = b"".join(self.load(self.entries[i]) for i in r[vc:pc])
        return data, phys


def points_into(b, lo, hi):
    n = len(b) // 8
    for (v,) in struct.iter_unpack("<Q", b[:n * 8]):
        if (v >> 32) == 0 and (v >> 28) == 5 and lo <= (v & 0x0FFFFFFF) < hi:
            return True
    return False


def u8(b, o): return b[o]
def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def i16(b, o): return struct.unpack_from("<h", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def i32(b, o): return struct.unpack_from("<i", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]
def f32(b, o): return struct.unpack_from("<f", b, o)[0]


def vptr(b, o):
    if o < 0 or o + 8 > len(b):
        return None
    v = u64(b, o)
    return (v & 0x0FFFFFFF) if (v >> 32) == 0 and (v >> 28) == 5 else None


def pptr(b, o):
    if o < 0 or o + 8 > len(b):
        return None
    v = u64(b, o)
    return (v & 0x0FFFFFFF) if (v >> 32) == 0 and (v >> 28) == 6 else None


def cstr(b, o, n=200):
    e = b.find(b"\0", o, o + n)
    return b[o:e if e >= 0 else o + n].decode("latin1")


def joaat(s):
    h = 0
    for c in s.lower().encode():
        h = (h + c) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h ^= h >> 6
    h = (h + (h << 3)) & 0xFFFFFFFF
    h ^= h >> 11
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h


def packs():
    return Archive(HOME + "/packs.rpf", HOME + "/6stars-data/packs.idx")


def hexdump(b, o, n, base=None):
    out = []
    for r in range(o, min(o + n, len(b)), 16):
        chunk = b[r:r + 16]
        out.append("%06x  %s" % (r if base is None else r - o + base, " ".join("%08x" % u32(chunk, k) for k in range(0, len(chunk) - 3, 4))))
    return "\n".join(out)
