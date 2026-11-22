import sys, struct
class Tile:
    def __init__(s, v):
        s.v = v
        u64 = lambda o: struct.unpack_from('<Q', v, o)[0]
        s.vp = lambda x: x & 0xFFFFFFF
        s.size = struct.unpack_from('<3f', v, 0x60)
        st = s.vp(u64(0xA0))
        s.mn = struct.unpack_from('<3f', v, st); s.mx = struct.unpack_from('<3f', v, st + 16)
        s.cf, s.ver = struct.unpack_from('<II', v, 0x10)
        s.counts = struct.unpack_from('<4I', v, 0xC0)
        s.verts = s.lst(0x70, 6)
        s.idx = s.lst(0x80, 2)
        s.polys = s.lst(0x98, 44)
    def lst(s, lo, esz):
        v = s.v
        L = s.vp(struct.unpack_from('<Q', v, lo)[0])
        cnt = struct.unpack_from('<I', v, L + 8)[0]
        parts = s.vp(struct.unpack_from('<Q', v, L + 0x10)[0]); np = struct.unpack_from('<I', v, L + 0x20)[0]
        out = []
        for k in range(np):
            pi = s.vp(struct.unpack_from('<Q', v, parts + 16 * k)[0]); pc = struct.unpack_from('<I', v, parts + 16 * k + 8)[0]
            out.extend(v[pi + j * esz: pi + (j + 1) * esz] for j in range(pc))
        assert len(out) == cnt, (len(out), cnt)
        return out
    def vert(s, i):
        x, y, z = struct.unpack('<3H', s.verts[i])
        return (s.mn[0] + x * s.size[0] / 65536, s.mn[1] + y * s.size[1] / 65536, s.mn[2] + z * s.size[2] / 65536)
