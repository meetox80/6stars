import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rpf import *
from collections import Counter
a = packs()
v, p = a.resource(int(sys.argv[1], 16))
vd = int(sys.argv[2], 16)
n = int(sys.argv[3])
for w in (8, 9):
    s = u32(p, vd + 4 * w)
    off = vd + (s >> 8) * 2
    print("slot", w)
    for unit, fmt in ((2, "<H"), (4, "<I")):
        cols = []
        for k in range(0, 16, unit):
            vals = [struct.unpack_from(fmt, p, off + 16 * i + k)[0] for i in range(n)]
            c = Counter(vals)
            cols.append("%d:[%x..%x] d%d top%s" % (k, min(vals), max(vals), len(c), [("%x" % x, y) for x, y in c.most_common(3)]))
        print(" u%d" % (unit * 8))
        for c in cols:
            print("   ", c)
for i in range(int(sys.argv[4]) if len(sys.argv) > 4 else 0):
    s8 = u32(p, vd + 32); s9 = u32(p, vd + 36)
    a8 = struct.unpack_from("<8H", p, vd + (s8 >> 8) * 2 + 16 * i)
    a9 = struct.unpack_from("<4I", p, vd + (s9 >> 8) * 2 + 16 * i)
    print(i, " ".join("%04x" % x for x in a8), "|", " ".join("%3d" % x for x in a9))
