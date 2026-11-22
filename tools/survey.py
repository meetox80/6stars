import json
import mmap
import os
import struct
import sys
import zlib
from multiprocessing import Pool


def J(s):
    h = 0
    for c in s.encode():
        h = (h + c) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h ^= h >> 6
    h = (h + (h << 3)) & 0xFFFFFFFF
    h ^= h >> 11
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h


POS = J("Position")
ROT = J("Rotation")
NAMES = {J(n): n for n in "Position Rotation Scale Name Archetype ArchetypeName ModelName Model Flags Entities Entity Guid Parent ParentIndex LodDist LodLevel Extents Min Max Transform Matrix Translation Orientation Placements Instances".split()}


def read_index(path):
    b = open(path, "rb").read()
    n = struct.unpack_from("<Q", b, 16)[0]
    out = []
    for i in range(n):
        r = 32 + i * 80
        off, size, unp = struct.unpack_from("<QQQ", b, r)
        out.append((off, size, unp, b[r + 24], b[r + 32:r + 32 + b[r + 26]]))
    return out


def segments(entries):
    segs = []
    seg = []
    for off, size, unp, kind, head in entries:
        if kind != 2:
            continue
        seg.append((off, size, unp, head))
        if unp != 0x10000:
            segs.append(seg)
            seg = []
    if seg:
        segs.append(seg)
    return segs


def vptr(b, o):
    v = struct.unpack_from("<Q", b, o)[0]
    return (v & 0x0FFFFFFF) if (v >> 32) == 0 and (v >> 28) == 5 else None


ARCHIVE = None


def init(path):
    global ARCHIVE
    f = open(path, "rb")
    ARCHIVE = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)


def inflate(seg):
    return b"".join(zlib.decompress(ARCHIVE[o:o + s]) for o, s, _, _ in seg)


def work(seg):
    try:
        return survey(seg)
    except (struct.error, IndexError):
        return {"off": seg[0][0], "kind": "unparsed"}


def survey(seg):
    head = seg[0][3]
    if len(head) < 24 or head[:8] != b"\0" * 8:
        return None
    try:
        b = inflate(seg)
    except Exception:
        return None
    res = {"off": seg[0][0], "vsize": len(b), "chunks": len(seg)}
    if b[0x10:0x14] == b"0DRP":
        bl, sc = vptr(b, 0x38), vptr(b, 0x28)
        nb = struct.unpack_from("<I", b, 0x48)[0]
        ns = struct.unpack_from("<H", b, 0x4C)[0]
        if bl is None or sc is None or nb > 4096 or ns > 4096:
            return None
        structs = {}
        for i in range(ns):
            o = sc + 32 * i
            if o + 32 > len(b):
                break
            name = struct.unpack_from("<I", b, o)[0]
            mp = vptr(b, o + 16)
            size = struct.unpack_from("<I", b, o + 24)[0]
            cnt = struct.unpack_from("<H", b, o + 30)[0]
            mem = []
            if mp is not None and b[o + 8] in (0, 0x0C):
                for k in range(cnt):
                    mo = mp + 16 * k
                    if mo + 16 > len(b):
                        break
                    mem.append(struct.unpack_from("<IIII", b, mo))
            structs[name] = (b[o + 8], size, mem)
        blocks = []
        for i in range(nb):
            o = bl + 16 * i
            t, sz = struct.unpack_from("<II", b, o)
            blocks.append((t, sz, vptr(b, o + 8)))
        pos_structs = {}
        for name, (typ, size, mem) in structs.items():
            names = {m[0] for m in mem}
            if POS in names:
                pos_structs[name] = {"size": size, "rot": ROT in names,
                                     "members": [[NAMES.get(m[0], f"{m[0]:08x}"), m[1], m[2], m[3]] for m in mem]}
        if pos_structs:
            res["kind"] = "prd0-pos"
            res["pos_structs"] = {f"{k:08x}": v for k, v in pos_structs.items()}
            res["blocks"] = [[f"{t:08x}", sz] for t, sz, _ in blocks if f"{t:08x}" in res["pos_structs"] or t in pos_structs]
        else:
            res["kind"] = "prd0"
            res["structs"] = {f"{k:08x}": [v[1], [f"{m[0]:08x}:{m[1]}:{m[2]:x}" for m in v[2]]] for k, v in structs.items()}
            res["blocks"] = [[f"{t:08x}", sz] for t, sz, _ in blocks]
        return res
    np_ = vptr(b, 0xA8) if len(b) > 0xB0 else None
    if vptr(b, 0x08) is not None and np_ is not None and np_ < len(b):
        end = b.find(b"\0", np_, np_ + 128)
        if end > np_:
            name = b[np_:end]
            if all(32 < c < 127 for c in name):
                res["kind"] = "drawable"
                res["name"] = name.decode()
                return res
    res["kind"] = "other"
    res["head"] = b[:0x60].hex()
    return res


def main():
    archive, index, out = sys.argv[1:4]
    segs = segments(read_index(index))
    print(f"{len(segs)} segments", file=sys.stderr, flush=True)
    stats = {}
    with Pool(12, initializer=init, initargs=(archive,)) as pool, open(out, "w") as fh:
        for i, r in enumerate(pool.imap(work, segs, chunksize=64)):
            if r is None:
                continue
            stats[r["kind"]] = stats.get(r["kind"], 0) + 1
            fh.write(json.dumps(r) + "\n")
            if i % 50000 == 0:
                print(i, stats, file=sys.stderr, flush=True)
    print(json.dumps(stats))


if __name__ == "__main__":
    main()
