import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rpf import *


def fragment_drawable(v):
    return vptr(v, 0x18)


def skeleton(v, sk):
    nb = u16(v, sk + 0x6C)
    bp = vptr(v, sk + 0x28)
    bones = []
    for i in range(nb):
        o = bp + 0x50 * i
        q = struct.unpack_from("<4f", v, o)
        t = struct.unpack_from("<3f", v, o + 0x10)
        h = u32(v, o + 0x1C)
        s = struct.unpack_from("<3f", v, o + 0x20)
        np_ = vptr(v, o + 0x30)
        name = cstr(v, np_) if np_ is not None else ""
        bones.append(dict(i=i, name=name, hash=h, quat=q, trans=t, scale=s,
                          flags=u16(v, o + 0x40), f2=u16(v, o + 0x42), next=i16(v, o + 0x44), parent=i16(v, o + 0x46),
                          index=u16(v, o + 0x48), tag=u16(v, o + 0x4A), x4c=u16(v, o + 0x4C), x4e=u16(v, o + 0x4E), raw38=u64(v, o + 0x38)))
    return bones


if __name__ == "__main__":
    a = packs()
    off = int(sys.argv[1], 16)
    v, p = a.resource(off, False)
    d = fragment_drawable(v) if len(sys.argv) < 3 else int(sys.argv[2], 16)
    sk = vptr(v, d + 0x18)
    print("drawable", hex(d), "skeleton", hex(sk))
    print(hexdump(v, sk, 0x80))
    for b in skeleton(v, sk):
        print("%3d %-28s par=%4d next=%4d idx=%3d tag=%04x fl=%04x/%x x4c=%x x4e=%x  q=(%.3f %.3f %.3f %.3f) t=(%.3f %.3f %.3f) s=(%.2f %.2f %.2f) h=%08x j=%s" % (
            b["i"], b["name"], b["parent"], b["next"], b["index"], b["tag"], b["flags"], b["f2"], b["x4c"], b["x4e"], *b["quat"], *b["trans"], *b["scale"], b["hash"], "ok" if joaat(b["name"]) == b["hash"] else "-"))
