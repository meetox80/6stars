import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rpf import *
import collections
a = Archive(sys.argv[1], sys.argv[2])
roots = collections.Counter()
ex = {}
n = 0
for i, e in enumerate(a.entries):
    if not (len(e.head) >= 0x18 and e.head[0x10:0x14] == b"0DRP" and a.is_start(i)):
        continue
    try:
        v, _ = a.resource(e.offset, False)
    except Exception:
        continue
    sc = vptr(v, 0x28)
    ns = u16(v, 0x48)
    bl = vptr(v, 0x38)
    nb = u16(v, 0x4C)
    if sc is None or bl is None:
        continue
    t0 = u32(v, bl) if nb else 0
    key = (t0, ns)
    roots[t0] += 1
    ex.setdefault(t0, (hex(e.offset), len(v), ns, nb))
    n += 1
print(n)
for k, c in roots.most_common(60):
    print("%08x %6d %s" % (k, c, ex[k]))
