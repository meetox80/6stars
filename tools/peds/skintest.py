import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pedmesh import *
from collections import defaultdict
names = [l.split(" ", 1)[1].strip() for f in ("bonenames_packs.txt", "bonenames_anim.txt") for l in open(f)]
names += ["SKEL_Spine%d" % i for i in range(6)] + ["SKEL_L_UpperArm", "SKEL_R_UpperArm", "SKEL_L_Forearm", "SKEL_R_Forearm", "SKEL_L_Clavicle", "SKEL_R_Clavicle", "SKEL_Head", "SKEL_Pelvis"]
d = {joaat(n): n for n in names}
a = packs()
off, noff = int(sys.argv[1], 16), int(sys.argv[2], 16)
v, p, base, geoms = load_named(a, off, noff)
print(drawable_name(v, base), len(geoms))
for G in geoms:
    print("geom", G.model, G.index, "n", G.n, "tris", len(G.tris), "bones", len(G.bones), "sems", {k: G.sem[k][1] for k in G.sem}, "slots", [(w, hex(f)) for w, f, o, e in G.slots])
    for variant in ("A", "B"):
        acc = defaultdict(lambda: [0, 0, 0, 0])
        bad = 0
        for i in range(G.n):
            w = list(raw(G, 16, i)) + list(raw(G, 17, i))
            if variant == "A":
                idx = list(raw(G, 20, i)) + list(raw(G, 21, i))
            else:
                idx = list(raw(G, 21, i)) + list(raw(G, 20, i))
            j = max(range(8), key=lambda k: w[k])
            b = idx[j]
            if b >= len(G.bones):
                bad += 1
                continue
            A = acc[b]
            for k in range(3):
                A[k] += G.pos[i][k]
            A[3] += 1
        print(" variant", variant, "bad", bad)
        for b in sorted(acc, key=lambda b: -acc[b][3])[:12]:
            A = acc[b]
            print("   %3d %-32s n=%5d  %.2f %.2f %.2f" % (b, d.get(G.bones[b], "%08x" % G.bones[b]), A[3], A[0] / A[3], A[1] / A[3], A[2] / A[3]))
    break
