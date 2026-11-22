import sys, os, struct, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser("~/testing/6stars/tools"))
from pso import PSO
from psogeneric import lut_from_names
b = open(sys.argv[1], "rb").read()
p = PSO(b)
lut = lut_from_names()
nm = lambda h: lut.get(h, "0x%08x" % h)
t, o, size = p.blocks[1]
hb = p.blocks[2]
out = {}
for r in range(o, o + size - 23, 8):
    key, = struct.unpack_from("<I", b, r)
    cnt, cap = struct.unpack_from("<II", b, r + 8)
    ptr, = struct.unpack_from("<Q", b, r + 16)
    if key == 0 or cnt == 0 or cnt != cap or cnt > 2000:
        continue
    bi = (ptr & 0xFFFFF) - 1
    off = ptr >> 20
    if bi != 2 or (ptr >> 32) != 0 or off + 4 * cnt > hb[2]:
        continue
    hs = struct.unpack_from("<%dI" % cnt, b, hb[1] + off)
    out[nm(key)] = [nm(h) for h in hs]
json.dump(out, open(sys.argv[2], "w"), indent=1)
for k, v in out.items():
    print(k, len(v), sum(not x.startswith("0x") for x in v))
