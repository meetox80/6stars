import sys, os, re, struct
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from joaat import joaat
from pso import PSO
import rbf
vocab = set()
for f in os.listdir(sys.argv[2]):
    b = open(os.path.join(sys.argv[2], f), 'rb').read()
    try: r = rbf.parse(b)
    except Exception: continue
    def walk(n):
        vocab.add(n['name'])
        for k, v in n.get('attrs', []):
            vocab.add(k)
            if v[0] == 's': vocab.add(v[1])
        if 'value' in n and n['value'][0] == 's': vocab.add(n['value'][1])
        t = n.get('text')
        if t is not None and len(t) < 80:
            s = t.rstrip(b'\0').decode('latin1')
            vocab.add(s)
            for w in re.split(r'[ |,]+', s): vocab.add(w)
        for k in n.get('kids', []): walk(k)
    walk(r)
for extra in sys.argv[3:]:
    vocab.update(l.strip() for l in open(extra))
lut = {}
for w in vocab:
    for h in (joaat(w), joaat(w, False)):
        lut.setdefault(h, w)
p = PSO(open(sys.argv[1], 'rb').read())
def nm(h): return lut.get(h, '%08x' % h)
for n, (typ, size, mem, raw) in p.structs.items():
    cnt = sum(sz // size for t, _, sz in p.blocks if t == n) if size else 0
    print('struct %s size %d instances %d' % (nm(n), size, cnt))
    for m in mem: print('   %-28s off %3d type %06x ref %s' % (nm(m[0]), m[1], m[2], nm(m[3])))
print('vocab', len(vocab))
import pickle; pickle.dump(lut, open('/tmp/psolut.pkl', 'wb')) if False else None
