import sys, struct
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from joaat import joaat
v = open(sys.argv[1], 'rb').read()
def vp(x): return x & 0x0FFFFFFF if (x >> 28) == 5 else None
def u64(o): return struct.unpack_from('<Q', v, o)[0]
def cstr(o):
    e = v.index(b'\0', o); return v[o:e].decode('latin1')
ha, hn, ta, tn = vp(u64(0x20)), struct.unpack_from('<H', v, 0x28)[0], vp(u64(0x30)), struct.unpack_from('<H', v, 0x38)[0]
print('count', hn, tn)
hashes = struct.unpack_from('<%dI' % hn, v, ha)
ok = 0
for i in range(tn):
    t = vp(u64(ta + 8 * i))
    np = vp(u64(t + 0x30)); name = cstr(np) or cstr(np + 8)
    w, h, d = struct.unpack_from('<HHH', v, t + 0x38)
    fmt = v[t + 0x3F]
    mips = v[t + 0x40]
    data = u64(t + 0x18)
    if hashes[i] == joaat(name): ok += 1
    if i < int(sys.argv[2]) if len(sys.argv) > 2 else 12:
        print(i, name, w, h, d, 'fmt', fmt, 'mips', mips, 'data %x' % data, 'raw', v[t:t+0x70].hex())
print('hash ok', ok)
