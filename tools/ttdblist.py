import sys, struct, mmap
f = open(sys.argv[1], 'rb'); m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
e = struct.unpack_from('<I', m, 0x10)[0] * 256
count = struct.unpack_from('<I', m, e + 8)[0]
d0 = e + 16; h0 = d0 + 16 * count
minw = int(sys.argv[2]) if len(sys.argv) > 2 else 0
for i in range(count):
    d = struct.unpack_from('<8H', m, d0 + 16 * i)
    v = d[0] | d[1] << 16
    w = (v & 0x3FFF) + 1; h = ((v >> 14) & 0x3FFF) + 1
    hs = struct.unpack_from('<Q', m, h0 + 8 * i)[0]
    off = (d[4] | (d[5] & 0x1f) << 16) * 0x1000
    if w * h >= minw:
        print('%016x %d %d %d %x %d' % (hs, w, h, d[2] >> 3, off, i))
