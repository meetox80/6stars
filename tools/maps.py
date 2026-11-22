import json
import mmap
import struct
import sys
import zlib

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from survey import read_index


class Lazy:
    def __init__(self, mm, chunks, start):
        self.mm = mm
        self.chunks = chunks
        self.i = start
        self.buf = bytearray()
        self.extend()

    def extend(self):
        if self.i >= len(self.chunks):
            raise EOFError("archive ended")
        o, s = self.chunks[self.i]
        self.buf += zlib.decompress(self.mm[o:o + s])
        self.i += 1

    def need(self, end):
        while len(self.buf) < end:
            self.extend()


def vptr(r, o):
    r.need(o + 8)
    v = struct.unpack_from("<Q", r.buf, o)[0]
    return (v & 0x0FFFFFFF) if (v >> 32) == 0 and (v >> 28) == 5 else None


class Prd0:
    def __init__(self, r):
        self.r = r
        sc, bl = vptr(r, 0x28), vptr(r, 0x38)
        ns = struct.unpack_from("<I", r.buf, 0x48)[0]
        nb = struct.unpack_from("<H", r.buf, 0x4C)[0]
        r.need(sc + 32 * ns)
        r.need(bl + 16 * nb)
        self.structs = {}
        for i in range(ns):
            o = sc + 32 * i
            name = struct.unpack_from("<I", r.buf, o)[0]
            mp = vptr(r, o + 16)
            size = struct.unpack_from("<I", r.buf, o + 24)[0]
            cnt = struct.unpack_from("<H", r.buf, o + 30)[0]
            ms = []
            if mp:
                r.need(mp + 16 * cnt)
                ms = [struct.unpack_from("<IIII", r.buf, mp + 16 * k) for k in range(cnt)]
            self.structs[name] = (size, ms)
        self.blocks = []
        for i in range(nb):
            o = bl + 16 * i
            t, sz = struct.unpack_from("<II", r.buf, o)
            p = vptr(r, o + 8)
            if p is not None:
                r.need(p + sz)
            self.blocks.append((t, sz, p))

    def arrays(self, name, base, path, out):
        size, ms = self.structs[name]
        prev = None
        b = self.r.buf
        for m in ms:
            if m[0] == 0x100:
                prev = m
                continue
            t = m[2] & 0xFF
            off = base + m[1]
            key = f"{path}/{m[0]:08x}"
            if t in (0x52, 0x5C):
                c = struct.unpack_from("<H", b, off + 8)[0]
                et = f"{prev[2] & 0xFF:x}/{prev[3]:08x}" if prev else "?"
                out[key] = [c, et]
            elif t == 5 and m[3] in self.structs:
                self.arrays(m[3], off, key, out)
            prev = None


def zlib_chunks(index):
    return [(o, s) for o, s, u, k, h in read_index(index) if k == 2]


def main():
    archive, index, out = sys.argv[1:4]
    entries = read_index(index)
    chunks = [(o, s) for o, s, u, k, h in entries if k == 2]
    pos = {o: i for i, (o, s) in enumerate(chunks)}
    starts = [o for o, s, u, k, h in entries if k == 2 and len(h) >= 20 and h[:8] == b"\0" * 8 and h[16:20] == b"0DRP"]
    f = open(archive, "rb")
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    bad = 0
    maps = 0
    with open(out, "w") as fh:
        for off in starts:
            try:
                r = Lazy(mm, chunks, pos[off])
                p = Prd0(r)
                md = [blk for blk in p.blocks if blk[0] == 0xD3593FA6]
                if not md:
                    continue
                maps += 1
                res = {}
                p.arrays(0xD3593FA6, md[0][2], "", res)
                b = r.buf
                name = struct.unpack_from("<I", b, md[0][2] + 8)[0]
                ext = struct.unpack_from("<4f", b, md[0][2] + 0xB0) + struct.unpack_from("<4f", b, md[0][2] + 0xC0)
                fh.write(json.dumps({"off": off, "chunks": r.i - pos[off], "name": f"{name:08x}", "extents": ext,
                                     "arrays": {k: v for k, v in res.items() if v[0]}}) + "\n")
            except (struct.error, EOFError, KeyError, zlib.error, TypeError):
                bad += 1
    print(f"{len(starts)} PRD0 resources, {maps} maps, {bad} failed")


if __name__ == "__main__":
    main()
