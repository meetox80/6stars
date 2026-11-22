import sys, os, re, struct, json
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from joaat import joaat
from pso import PSO
import rbf

def vocab_from(rbfdir, extra=()):
    vocab = set()
    for f in os.listdir(rbfdir):
        b = open(os.path.join(rbfdir, f), 'rb').read()
        try: r = rbf.parse(b)
        except Exception: continue
        def walk(n):
            vocab.add(n['name'])
            for k, v in n.get('attrs', []):
                vocab.add(k)
                if v[0] == 's': vocab.add(v[1])
            t = n.get('text')
            if t is not None and len(t) < 120:
                s = t.rstrip(b'\0').decode('latin1'); vocab.add(s)
                for w in re.split(r'[ |,]+', s): vocab.add(w)
            for k in n.get('kids', []): walk(k)
        walk(r)
    vocab.update(extra)
    lut = {}
    for w in vocab:
        lut.setdefault(joaat(w), w); lut.setdefault(joaat(w, False), w)
    return lut

class Dumper:
    def __init__(s, p, lut):
        s.p = p; s.lut = lut; s.b = p.b
    def nm(s, h): return s.lut.get(h, '0x%08x' % h)
    def ptr(s, v):
        if v == 0: return None
        bi = (v & 0xFFFFF) - 1; off = v >> 20
        if bi < 0 or bi >= len(s.p.blocks): return None
        t, p, size = s.p.blocks[bi]
        return t, p + off
    def obj(s, t, o, depth=0):
        st = s.p.structs.get(t)
        if not st: return '<?%08x>' % t
        typ, size, mem, _ = st
        out = {'_type': s.nm(t)}
        mems = list(mem)
        i = 0
        while i < len(mems):
            name, off, mt, ref = mems[i]
            if name == 0x100:
                i += 1; continue
            el = mems[i - 1] if i > 0 and mems[i - 1][0] == 0x100 else None
            out[s.nm(name)] = s.val(mt, ref, o + off, el, depth)
            i += 1
        return out
    def val(s, mt, ref, o, el, depth):
        b = s.b; k = mt & 0xFF
        if k == 0x21: return round(struct.unpack_from('<f', b, o)[0], 4)
        if k in (0x10, 0x11, 0x01): return b[o]
        if k in (0x12, 0x13): return struct.unpack_from('<H', b, o)[0]
        if k == 0x14: return struct.unpack_from('<i', b, o)[0]
        if k == 0x15: return struct.unpack_from('<I', b, o)[0]
        if k == 0x4a: return s.nm(struct.unpack_from('<I', b, o)[0])
        if k in (0x60, 0x61, 0x62, 0x64, 0x65):
            w = {0x60: 1, 0x61: 2, 0x62: 4, 0x64: 4, 0x65: 4}[k]
            v = int.from_bytes(b[o:o+w], 'little')
            return s.enum(ref, v)
        if k in (0x30, 0x32, 0x33): return [round(x, 4) for x in struct.unpack_from('<3f', b, o)]
        if k == 0x34: return [round(x, 4) for x in struct.unpack_from('<4f', b, o)]
        if k == 0x05: return s.obj(ref, o, depth + 1)
        if k == 0x07:
            r = s.ptr(struct.unpack_from('<Q', b, o)[0])
            return s.obj(r[0], r[1], depth + 1) if r and depth < 40 else None
        if k == 0x4f: return '0x%x' % struct.unpack_from('<Q', b, o)[0]
        if k == 0x52 or k == 0x5c:
            if k == 0x52:
                pv = struct.unpack_from('<Q', b, o)[0]; cnt = struct.unpack_from('<H', b, o + 8)[0]
            else:
                cnt = struct.unpack_from('<I', b, o)[0]; pv = struct.unpack_from('<Q', b, o + 8)[0]
            r = s.ptr(pv)
            if not r or not el: return {'count': cnt}
            _, eoff, et, eref = el
            items = []
            esz = s.esize(et, eref)
            for j in range(cnt):
                items.append(s.val(et, eref, r[1] + j * esz, None, depth + 1))
            return items
        if k == 0x4f or k == 0x17: return '0x%x' % struct.unpack_from('<Q', b, o)[0]
        return '?%x' % mt
    def esize(s, et, eref):
        k = et & 0xFF
        if k == 0x05: return s.p.structs[eref][1]
        return {0x07: 8, 0x21: 4, 0x4a: 4, 0x14: 4, 0x15: 4, 0x10: 1, 0x11: 1, 0x12: 2, 0x13: 2, 0x62: 4, 0x60: 1, 0x34: 16, 0x30: 16}.get(k, 8)
    def enum(s, ref, v):
        return s.lut.get(v, v) if v > 0xFFFF else ('%s:%d' % (s.nm(ref), v))

if __name__ == '__main__':
    p = PSO(open(sys.argv[1], 'rb').read())
    lut = vocab_from(sys.argv[2])
    d = Dumper(p, lut)
    roots = [blk for blk in p.blocks if blk[0] == 0x5d09873f]
    t, o, size = roots[0]
    root = d.obj(t, o)
    json.dump(root, open(sys.argv[3], 'w'), indent=1)
    print('ok')
