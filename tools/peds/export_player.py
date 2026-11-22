import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pedmesh import *
from skel import skeleton, fragment_drawable

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "player01")

COMPONENTS = [
    "player_story000_01_head_mr1_cau_000_m",
    "player_story000_01_head_mr1_cau_000_m_eyes",
    "player_story000_01_head_mr1_cau_000_m_eyecap",
    "player_story000_01_tshirtcrewneck_mr1_000_regular_cc_ft_short_full",
    "player_story000_01_pantsjeans_mr1_002_regular_mw_long_full",
    "player_story000_01_shoesloafers_mr1_000_low_fh_full",
    "hand_mr1_000_tshirt_a02",
]
SKELETON_FRAGMENT = 0x454db010


def names_table():
    rows = {}
    for l in open(os.path.join(HERE, "..", "packs_names.tsv")):
        r = l.rstrip("\n").split("\t")
        rows.setdefault(r[2], []).append((int(r[0], 16), int(r[3], 16)))
    return rows


def slot_format(G, sem):
    o, sz = G.sem[sem]
    for w, f, so, es in G.slots:
        if so == o:
            return f
    return None


def uvs(G, sem):
    if sem not in G.sem:
        return None
    o, sz = G.sem[sem]
    f = slot_format(G, sem)
    p = G.p
    if f == 0x28:
        rw = f32(p, G.vd + 0x7C)
        rng = rw if math.isfinite(rw) and 0 < rw < 1e6 else 4
        return uv28(p, o, G.n, rng)
    if f == 0x42:
        return [struct.unpack_from("<2f", p, o + 8 * i) for i in range(G.n)]
    return None


def skin(G):
    has17 = 17 in G.sem
    w0 = G.sem[16]
    i0 = G.sem[20]
    out = []
    for i in range(G.n):
        w = list(raw(G, 16, i)) + (list(raw(G, 17, i)) if has17 else [])
        if i0[1] == 4:
            idx = list(raw(G, 20, i)) + (list(raw(G, 21, i)) if has17 else [])
        else:
            idx = [x & 0xFFFF for x in struct.unpack("<4I", raw(G, 20, i))]
            if has17:
                idx += [x & 0xFFFF for x in struct.unpack("<4I", raw(G, 21, i))]
        out.append([(G.bones[j] if j < len(G.bones) else None, wt) for j, wt in zip(idx, w) if wt])
    return out


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz)


def qrot(q, v):
    x, y, z, w = q
    vx, vy, vz = v
    tx = 2 * (y * vz - z * vy)
    ty = 2 * (z * vx - x * vz)
    tz = 2 * (x * vy - y * vx)
    return (vx + w * tx + (y * tz - z * ty), vy + w * ty + (z * tx - x * tz), vz + w * tz + (x * ty - y * tx))


def globals_(bones):
    G = [None] * len(bones)
    for b in bones:
        i, par = b["i"], b["parent"]
        if par < 0:
            G[i] = (b["quat"], b["trans"])
        else:
            pq, pt = G[par]
            t = qrot(pq, b["trans"])
            G[i] = (qmul(pq, b["quat"]), (pt[0] + t[0], pt[1] + t[1], pt[2] + t[2]))
    return G


def winding_agreement(G):
    if not G.nrm:
        return None
    ok = tot = 0
    for a, b, c in G.tris:
        pa, pb, pc = G.pos[a], G.pos[b], G.pos[c]
        e1 = [pb[k] - pa[k] for k in range(3)]
        e2 = [pc[k] - pa[k] for k in range(3)]
        n = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0])
        s = [G.nrm[a][k] + G.nrm[b][k] + G.nrm[c][k] for k in range(3)]
        d = sum(n[k] * s[k] for k in range(3))
        if d != 0:
            tot += 1
            ok += d > 0
    return ok / tot if tot else None


def main():
    os.makedirs(OUT, exist_ok=True)
    a = packs()
    rows = names_table()
    sv, _ = a.resource(SKELETON_FRAGMENT, False)
    bones = skeleton(sv, vptr(sv, fragment_drawable(sv) + 0x18))
    gl = globals_(bones)
    byhash = {b["hash"]: b for b in bones}
    json.dump([dict(index=b["i"], name=b["name"], hash="%08x" % b["hash"], tag="%04x" % b["tag"], parent=b["parent"],
                    rotation=b["quat"], translation=b["trans"], scale=b["scale"],
                    bind_position=gl[b["i"]][1]) for b in bones],
              open(os.path.join(OUT, "skeleton_ambient_malebody.json"), "w"), indent=0)
    report = []
    all_v = []
    combined = []
    voff = 1
    for name in COMPONENTS:
        best = None
        for off, noff in rows[name]:
            v, p = a.resource(off)
            base = find_base(v, noff)
            gs = decode(v, p, base, 0)
            n = sum(G.n for G in gs)
            if best is None or n > best[0]:
                best = (n, off, v, p, base, gs)
        n, off, v, p, base, gs = best
        sh = shaders(v, base)
        bmin = [f32(v, base + 0x30 + 4 * i) for i in range(3)]
        comp = dict(name=name, resource="%x" % off, vertices=n, geometries=[])
        lines = ["mtllib player01.mtl"]
        lv = 1
        skins = []
        for G in gs:
            uv = uvs(G, SEM_UV0)
            sk = skin(G)
            missing = sorted(set("%08x" % h for s in sk for h, w in s if h is not None and h not in byhash))
            top_d = []
            for i, s in enumerate(sk):
                h, w = max(s, key=lambda x: x[1])
                b = byhash.get(h)
                if b is not None:
                    bp = gl[b["i"]][1]
                    top_d.append(math.dist(G.pos[i], bp))
            top_d.sort()
            wsum = sorted(set(sum(w for h, w in s) for s in sk))
            geo = dict(index=G.index, model=G.model, vertices=G.n, triangles=len(G.tris), bones=len(G.bones), shader=G.shader,
                       shader_name="%08x" % sh[G.shader][0] if G.shader < len(sh) else None,
                       textures=[dict(param="%08x" % pa, hash="%016x" % th) for pa, th in (sh[G.shader][1] if G.shader < len(sh) else [])],
                       semantics={str(k): dict(bytes=s, format="%02x" % (slot_format(G, k) or 0)) for k, (o, s) in sorted(G.sem.items())},
                       winding_vs_normals=winding_agreement(G),
                       bones_not_in_skeleton=len(missing),
                       weight_sum_range=[wsum[0], wsum[-1]],
                       median_dist_to_top_bone=top_d[len(top_d) // 2] if top_d else None)
            comp["geometries"].append(geo)
            lines.append("g %s_g%d" % (name, G.index))
            lines.append("usemtl %s_s%d" % (name, G.shader))
            for q in G.pos:
                lines.append("v %.5f %.5f %.5f" % q)
                all_v.append((q, name))
            if G.nrm:
                for q in G.nrm:
                    lines.append("vn %.4f %.4f %.4f" % q)
            if uv:
                for q in uv:
                    lines.append("vt %.5f %.5f" % (q[0], 1 - q[1]))
            for t in G.tris:
                lines.append("f " + " ".join("%d/%d/%d" % (lv + i, lv + i, lv + i) if uv and G.nrm else "%d" % (lv + i) for i in t))
            combined.append((name, G, uv, lines))
            lv += G.n
            skins.append([[["%08x" % h if h is not None else None, w] for h, w in s] for s in sk])
        comp["bbox_min_minus_vertex_min"] = [round(bmin[k] - min(min(q[k] for q in G.pos) for G in gs), 4) for k in range(3)]
        open(os.path.join(OUT, name + ".obj"), "w").write("\n".join(lines) + "\n")
        json.dump(dict(component=name, geometries=skins), open(os.path.join(OUT, name + ".skin.json"), "w"))
        report.append(comp)
        print(name, off and "%x" % off, n, [(g["vertices"], g["triangles"], g["bones"], g["bones_not_in_skeleton"], g["winding_vs_normals"] and round(g["winding_vs_normals"], 4), g["median_dist_to_top_bone"] and round(g["median_dist_to_top_bone"], 3), g["weight_sum_range"]) for g in comp["geometries"]])
    json.dump(report, open(os.path.join(OUT, "components.json"), "w"), indent=1)
    mtl = []
    for comp in report:
        for g in comp["geometries"]:
            mtl.append("newmtl %s_s%d" % (comp["name"], g["shader"]))
            for t in g["textures"]:
                if t["param"] == "c8e8c282" and os.path.exists(os.path.join(OUT, "tex", t["hash"] + ".png")):
                    mtl.append("map_Kd tex/%s.png" % t["hash"])
    open(os.path.join(OUT, "player01.mtl"), "w").write("\n".join(mtl) + "\n")
    lines = ["mtllib player01.mtl"]
    base = 1
    for name, G, uv, _ in combined:
        lines.append("g %s_g%d" % (name, G.index))
        lines.append("usemtl %s_s%d" % (name, G.shader))
        for q in G.pos:
            lines.append("v %.5f %.5f %.5f" % q)
        for q in G.nrm:
            lines.append("vn %.4f %.4f %.4f" % q)
        for q in (uv or [(0, 0)] * G.n):
            lines.append("vt %.5f %.5f" % (q[0], 1 - q[1]))
        for t in G.tris:
            lines.append("f " + " ".join("%d/%d/%d" % (base + i, base + i, base + i) for i in t))
        base += G.n
    open(os.path.join(OUT, "player01_bindpose.obj"), "w").write("\n".join(lines) + "\n")
    json.dump(dict(bones=[(b["name"], gl[b["i"]][1]) for b in bones],
                   meshes=[dict(name=name, pos=G.pos, nrm=G.nrm, tris=G.tris) for name, G, uv, _ in combined]),
              open(os.path.join(OUT, "render_input.json"), "w"))


if __name__ == "__main__":
    main()
