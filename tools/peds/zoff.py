import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pedmesh import *
a = packs()
for off, no in [(int(x.split(":")[0], 16), int(x.split(":")[1], 16)) for x in sys.argv[1:]]:
    v, p, base, gs = load_named(a, off, no)
    bmin = [f32(v, base + 0x30 + 4 * i) for i in range(3)]
    bmax = [f32(v, base + 0x40 + 4 * i) for i in range(3)]
    mn = [min(min(q[k] for q in G.pos) for G in gs) for k in range(3)]
    mx = [max(max(q[k] for q in G.pos) for G in gs) for k in range(3)]
    print(drawable_name(v, base)[:55], "dmin-vmin", [round(bmin[k] - mn[k], 4) for k in range(3)], "dmax-vmax", [round(bmax[k] - mx[k], 4) for k in range(3)], "sems", sorted((k, s) for k, (o, s) in gs[0].sem.items()))
