import sys, struct, zlib, mmap
def read_index(path):
    b = open(path, 'rb').read()
    assert b[:4] == b'RPXI'
    n = struct.unpack_from('<Q', b, 16)[0]
    out = []
    for i in range(n):
        o = 32 + i * 80
        off, size, unp = struct.unpack_from('<QQQ', b, o)
        kind = b[o + 24]
        head = b[o + 32:o + 32 + b[o + 26]]
        out.append((off, size, unp, kind, head))
    return out
rpf, idx = sys.argv[1], sys.argv[2]
needles = [s.encode() for s in sys.argv[3:]]
f = open(rpf, 'rb'); m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
for off, size, unp, kind, head in read_index(idx):
    if kind != 2: continue
    try:
        d = zlib.decompressobj().decompress(m[off:off + size + 64])
    except Exception:
        continue
    for nd in needles:
        p = d.find(nd)
        if p >= 0:
            print('%x %s +%x head=%s ctx=%r' % (off, nd.decode(), p, head[:4], d[max(0, p - 40):p + 60]))
