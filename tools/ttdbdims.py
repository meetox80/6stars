import sys, struct, mmap
f = open(sys.argv[1], 'rb'); m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
assert m[:4] == b'RDS5'
e = struct.unpack_from('<I', m, 0x10)[0] * 256
assert m[e:e+4] == b'ETPF'
count = struct.unpack_from('<I', m, e + 8)[0]
d0 = e + 16; h0 = d0 + 16 * count
want = set()
for a in sys.argv[2:]:
    w, h = a.split('x'); want.add((int(w), int(h)))
rows = []
for i in range(count):
    d = struct.unpack_from('<8H', m, d0 + 16 * i)
    v = d[0] | d[1] << 16
    w = (v & 0x3FFF) + 1; h = ((v >> 14) & 0x3FFF) + 1
    fmt = d[2] >> 3
    hs = struct.unpack_from('<Q', m, h0 + 8 * i)[0]
    rows.append((w, h, fmt, hs))
    if (w, h) in want:
        print('%dx%d fmt=%d hash=%016x idx=%d' % (w, h, fmt, hs, i))
print('count', count)
if not want:
    import collections
    c = collections.Counter((w, h) for w, h, _, _ in rows)
    print(c.most_common(30))
