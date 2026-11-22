import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pedmesh import *

def infl(G, i, swap, fmt):
    has17 = 17 in G.sem
    w = list(raw(G, 16, i)) + (list(raw(G, 17, i)) if has17 else [0] * 4)
    if fmt == "u8":
        a, b = list(raw(G, 20, i)), (list(raw(G, 21, i)) if has17 else [0] * 4)
    else:
        a = list(struct.unpack("<4I", raw(G, 21, i)))
        s8 = struct.unpack("<8H", raw(G, 20, i))
        b = [s8[0], s8[2], s8[4], s8[6]]
    idx = (b + a) if swap else (a + b)
    d = {}
    for k in range(8):
        d[idx[k]] = d.get(idx[k], 0) + w[k]
    return d

a = packs()
for off, no in [(int(x.split(":")[0], 16), int(x.split(":")[1], 16)) for x in sys.argv[1:]]:
    v, p, base, gs = load_named(a, off, no)
    for G in gs:
        fmt = "u8" if G.sem[20][1] == 4 else "wide"
        res = []
        for swap in (False, True):
            D = [infl(G, i, swap, fmt) for i in range(G.n)]
            tot = 0
            cnt = 0
            for t in G.tris:
                for x, y in ((t[0], t[1]), (t[1], t[2]), (t[2], t[0])):
                    ks = set(D[x]) | set(D[y])
                    tot += sum(abs(D[x].get(k, 0) - D[y].get(k, 0)) for k in ks)
                    cnt += 1
            res.append(tot / cnt)
        sums = set(sum(list(raw(G, 16, i)) + (list(raw(G, 17, i)) if 17 in G.sem else [])) for i in range(G.n))
        print(drawable_name(v, base)[:50], "geom", G.index, "n", G.n, fmt, "edgeL1 pairing(16-20,17-21)=%.2f swapped=%.2f" % tuple(res), "weight sums", sorted(sums)[:5])
