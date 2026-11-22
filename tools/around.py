import sys, struct
sys.path.insert(0, '')
def read_index(path):
    b = open(path, 'rb').read()
    n = struct.unpack_from('<Q', b, 16)[0]
    for i in range(n):
        o = 32 + i * 80
        off, size, unp = struct.unpack_from('<QQQ', b, o)
        yield off, size, unp, b[o + 24], b[o + 32:o + 32 + b[o + 26]]
idx, lo, hi = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
for off, size, unp, kind, head in read_index(idx):
    if lo <= off <= hi:
        print('%x end=%x kind=%d packed=%x unp=%x head=%s' % (off, (off + size + 15) & ~15, kind, size, unp, head[:24].hex()))
