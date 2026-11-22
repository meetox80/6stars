import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rpf import *
import math

SEM_POS, SEM_NORMAL, SEM_TANGENT = 0, 4, 11
SEM_WEIGHT0, SEM_WEIGHT1 = 16, 17
SEM_SKIN0, SEM_SKIN1 = 20, 21
SEM_COLOR0, SEM_COLOR1, SEM_COLOR2 = 24, 25, 26
SEM_UV0, SEM_UV1, SEM_UV2, SEM_UV3 = 28, 29, 30, 31
SEM_EXTRA = 33


def find_base(v, name_off):
    for o in range(0, len(v) - 8, 8):
        if vptr(v, o) == name_off and o >= 0xA8:
            b = o - 0xA8
            if any(vptr(v, b + s) for s in (0x50, 0x58, 0x60, 0x68)):
                return b
    return None


def drawable_name(v, base):
    p = vptr(v, base + 0xA8)
    return cstr(v, p) if p is not None else None


def oct_normal(w):
    a = ((w >> 10) & 1023) / 1023 * 2 - 1
    b = (w & 1023) / 1023 * 2 - 1
    z = 1 - abs(a) - abs(b)
    x, y = a, b
    if z < 0:
        x = (1 - abs(b)) * (1 if a >= 0 else -1)
        y = (1 - abs(a)) * (1 if b >= 0 else -1)
    l = math.sqrt(x * x + y * y + z * z) or 1
    return (y / l, x / l, z / l)


def page_slots(p, vd):
    out = []
    for w in range(24):
        s = u32(p, vd + 4 * w)
        if s == 0 or (s & 0xFF) == 0:
            continue
        out.append((w, s & 0xFF, vd + (s >> 8) * 2, ((s & 0xFF) >> 4) * 2))
    return out


def decl_table(v, g):
    t = vptr(v, g + 0x90)
    if t is None:
        return None
    offs = [u32(v, t + 4 * i) for i in range(52)]
    sizes = list(v[t + 0xD0:t + 0xD0 + 52])
    return offs, sizes


def positions(p, vd, n):
    b = struct.unpack_from("<3f", p, vd + 0x60)
    k = i32(p, vd + 0x6C)
    s = struct.unpack_from("<3f", p, vd + 0x70)
    out = []
    for i in range(n):
        r = p[vd + 0x80 + 8 * i:vd + 0x88 + 8 * i]
        f1 = r[3] << 16 | r[2] << 8 | r[1]
        f2 = r[5] << 16 | r[4] << 8 | r[0]
        f3 = r[7] << 8 | r[6]
        if k == 1:
            out.append((b[1] + f2 * s[1], b[2] + f3 * s[2], b[0] + f1 * s[0]))
        elif k == 0:
            out.append((b[2] + f3 * s[2], b[1] + f2 * s[1], b[0] + f1 * s[0]))
        else:
            out.append((b[0] + f1 * s[0], b[1] + f2 * s[1], b[2] + f3 * s[2]))
    return out


def uv28(p, off, n, rng):
    k = 2 * rng / 65535
    return [(u16(p, off + 4 * i) * k - rng, u16(p, off + 4 * i + 2) * k - rng) for i in range(n)]


def meshlets(p, o, nverts):
    w = u32(p, o)
    if not w & 0x80000000:
        return None
    cnt = w & 0xFFFF
    ntri, nvl = u32(p, o + 4), u32(p, o + 8)
    tri0 = o + 12 + 16 * cnt
    vl0 = tri0 + 4 * ntri
    voffs, toffs = [], []
    vw = tw = 0
    pv = pt = -1
    for m in range(cnt):
        vo = u16(p, o + 12 + 16 * m + 4) + vw
        to = u16(p, o + 12 + 16 * m + 6) + tw
        if vo < pv:
            vw += 0x10000
            vo += 0x10000
        if to < pt:
            tw += 0x10000
            to += 0x10000
        voffs.append(vo)
        toffs.append(to)
        pv, pt = vo, to
    toffs.append(ntri)
    out = []
    for m in range(cnt):
        for t in range(toffs[m], min(toffs[m + 1], ntri)):
            word = u32(p, tri0 + 4 * t)
            idx = [voffs[m] + ((word >> s) & 0x7F) for s in (0, 7, 14)]
            if max(idx) >= nvl:
                continue
            tri = [u16(p, vl0 + 2 * x) for x in idx]
            if max(tri) < nverts and len(set(tri)) == 3:
                out.append(tri)
    return out


def shaders(v, base):
    sg = vptr(v, base + 0x10)
    out = []
    if sg is None:
        return out
    arr = vptr(v, sg + 0x10)
    for i in range(u16(v, sg + 0x18)):
        sh = vptr(v, arr + 8 * i)
        tex = []
        if sh is None:
            out.append((0, tex))
            continue
        tp, params = vptr(v, sh + 0x10), vptr(v, sh + 0x20)
        if tp is not None and params is not None:
            for t in range(v[params + 1]):
                ts = vptr(v, tp + 8 * t)
                rec = vptr(v, ts + 0x30) if ts is not None else None
                if rec is None:
                    continue
                tex.append((u32(v, params + 8 + 8 * t), u64(v, rec + 8)))
        out.append((u32(v, sh), tex))
    return out


class Geometry:
    pass


def decode(v, p, base, lod=0):
    lodp = vptr(v, base + 0x50 + 8 * lod)
    models = vptr(v, lodp)
    res = []
    for mi in range(u16(v, lodp + 8)):
        m = vptr(v, models + 8 * mi)
        garr = vptr(v, m + 8)
        nb = u16(v, m + 0x14)
        bl = vptr(v, m + 0x28)
        bones = [u32(v, bl + 4 * i) for i in range(nb)] if bl is not None else []
        smap = vptr(v, m + 0x20)
        for gi in range(u16(v, m + 0x10)):
            g = vptr(v, garr + 8 * gi)
            vd = pptr(v, g + 0x68)
            vbytes = u32(v, g + 0x58) * 4
            slots = page_slots(p, vd)
            sl = sorted(slots, key=lambda s: s[2])
            n = (sl[1][2] - sl[0][2]) // sl[0][3] if len(sl) > 1 else (vbytes - 0x80) // 8
            ip = vptr(v, vptr(v, g + 0x40))
            idata = pptr(v, ip + 0x18)
            G = Geometry()
            G.model, G.index, G.n, G.bones = mi, gi, n, bones
            G.shader = u16(v, smap + 2 * gi) if smap is not None else 0
            G.slots = slots
            dt = decl_table(v, g)
            G.sem = {}
            if dt:
                offs, sizes = dt
                for sem, (o, sz) in enumerate(zip(offs, sizes)):
                    if sz:
                        G.sem[sem] = (vd + o, sz)
            G.pos = positions(p, vd, n)
            rw = f32(p, vd + 0x7C)
            rng = rw if math.isfinite(rw) and 0 < rw < 1e6 else 4
            G.nrm = [oct_normal(u32(p, G.sem[SEM_NORMAL][0] + 4 * i)) for i in range(n)] if SEM_NORMAL in G.sem else None
            G.uv = uv28(p, G.sem[SEM_UV0][0], n, rng) if SEM_UV0 in G.sem else None
            G.tris = meshlets(p, idata, n)
            G.p, G.vd = p, vd
            res.append(G)
    return res


def raw(G, sem, i):
    o, sz = G.sem[sem]
    return G.p[o + sz * i:o + sz * (i + 1)]


def load_named(a, off, name_off, lod=0):
    v, p = a.resource(off)
    base = find_base(v, name_off)
    return v, p, base, decode(v, p, base, lod)
