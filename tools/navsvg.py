import sys, struct
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from nav import Tile
t = Tile(open(sys.argv[1], 'rb').read())
tests = [(2, 0), (2, 3), (10, 0), (10, 1), (10, 2), (10, 6), (10, 11), (10, 17), (10, 22), (6, 12), (6, 27), (6, 25), (6, 1), (6, 2), (6, 3), (8, 29)]
W = 256
cols = 4
out = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" style="background:#222">' % (cols * (W + 10), ((len(tests) + cols - 1) // cols) * (W + 24))]
polys = []
for p in t.polys:
    w = struct.unpack_from('<11I', p)
    s, c = w[1] >> 4, w[1] & 15
    pts = [t.vert(struct.unpack('<H', t.idx[s + k])[0]) for k in range(c)]
    polys.append((w, pts))
for ti, (k, b) in enumerate(tests):
    ox = (ti % cols) * (W + 10); oy = (ti // cols) * (W + 24)
    out.append('<text x="%d" y="%d" fill="#fff" font-size="12">+%d bit %d</text>' % (ox + 4, oy + 14, k * 4, b))
    for w, pts in polys:
        on = (w[k] >> b) & 1
        d = ' '.join('%.1f,%.1f' % (ox + (x - t.mn[0]) / 128 * W, oy + 20 + (1 - (y - t.mn[1]) / 128) * W) for x, y, z in pts)
        out.append('<polygon points="%s" fill="%s"/>' % (d, '#f80' if on else '#567'))
out.append('</svg>')
open(sys.argv[2], 'w').write('\n'.join(out))
