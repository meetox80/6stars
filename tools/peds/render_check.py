import sys, os, json, math, zlib, struct

COLORS = {
    "head": (222, 180, 150), "eyes": (240, 240, 250), "eyecap": (200, 200, 230), "tshirt": (70, 110, 190),
    "pants": (60, 70, 95), "shoes": (110, 70, 40), "hand": (222, 180, 150),
}


def color_for(name):
    for k in ("eyecap", "eyes", "hand", "tshirt", "pants", "shoes", "head"):
        if k in name:
            return COLORS[k]
    return (180, 180, 180)


def write_png(path, w, h, px):
    raw = b"".join(b"\x00" + bytes(px[y * w * 3:(y + 1) * w * 3]) for y in range(h))
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


def render(data, axis_h, axis_d, sign_d, w, h, scale, cx, cz, light, bones_overlay, flat=True):
    px = bytearray([30, 30, 34] * (w * h))
    zb = [-1e9] * (w * h)
    def proj(p):
        return (cx + p[axis_h] * scale, cz - p[2] * scale, p[axis_d] * sign_d)
    for m in data["meshes"]:
        col = color_for(m["name"])
        P = [proj(p) for p in m["pos"]]
        N = m["nrm"]
        for t in m["tris"]:
            a, b, c = P[t[0]], P[t[1]], P[t[2]]
            minx = max(int(min(a[0], b[0], c[0])), 0)
            maxx = min(int(max(a[0], b[0], c[0])) + 1, w - 1)
            miny = max(int(min(a[1], b[1], c[1])), 0)
            maxy = min(int(max(a[1], b[1], c[1])) + 1, h - 1)
            den = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
            if abs(den) < 1e-12:
                continue
            if flat:
                pa, pb, pc = m["pos"][t[0]], m["pos"][t[1]], m["pos"][t[2]]
                e1 = [pb[k] - pa[k] for k in range(3)]
                e2 = [pc[k] - pa[k] for k in range(3)]
                nn = [e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]]
            else:
                nn = [N[t[0]][k] + N[t[1]][k] + N[t[2]][k] for k in range(3)]
            l = math.sqrt(sum(x * x for x in nn)) or 1
            dl = sum(nn[k] / l * light[k] for k in range(3))
            sh = 0.25 + 0.75 * (abs(dl) if flat else max(0.0, dl))
            cc = (int(col[0] * sh), int(col[1] * sh), int(col[2] * sh))
            for y in range(miny, maxy + 1):
                for x in range(minx, maxx + 1):
                    l1 = ((b[1] - c[1]) * (x - c[0]) + (c[0] - b[0]) * (y - c[1])) / den
                    l2 = ((c[1] - a[1]) * (x - c[0]) + (a[0] - c[0]) * (y - c[1])) / den
                    l3 = 1 - l1 - l2
                    if l1 < 0 or l2 < 0 or l3 < 0:
                        continue
                    z = l1 * a[2] + l2 * b[2] + l3 * c[2]
                    i = y * w + x
                    if z > zb[i]:
                        zb[i] = z
                        px[3 * i:3 * i + 3] = bytes(cc)
    if bones_overlay:
        for name, p in data["bones"]:
            if not name.startswith("SKEL_"):
                continue
            x, y, _ = proj(p)
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    xx, yy = int(x) + dx, int(y) + dy
                    if 0 <= xx < w and 0 <= yy < h:
                        px[3 * (yy * w + xx):3 * (yy * w + xx) + 3] = b"\xff\x30\x30"
    return px


def main():
    d = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    w, h = 520, 1000
    zs = [p[2] for m in d["meshes"] for p in m["pos"]]
    zmin, zmax = min(zs), max(zs)
    scale = (h - 60) / (zmax - zmin)
    cz = h - 30 + zmin * scale
    views = []
    views.append(render(d, 0, 1, -1, w, h, scale, w / 2, cz, (0.3, -0.8, 0.5), False))
    views.append(render(d, 1, 0, 1, w, h, scale, w / 2, cz, (0.6, -0.3, 0.6), False))
    views.append(render(d, 0, 1, -1, w, h, scale, w / 2, cz, (0.3, -0.8, 0.5), True, False))
    W = w * len(views)
    px = bytearray(W * h * 3)
    for vi, v in enumerate(views):
        for y in range(h):
            px[3 * (y * W + vi * w):3 * (y * W + vi * w + w)] = v[3 * y * w:3 * (y + 1) * w]
    write_png(out, W, h, px)
    print("zrange", zmin, zmax)


if __name__ == "__main__":
    main()
