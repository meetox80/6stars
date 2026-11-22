import sys, struct
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from joaat import joaat

class PSO:
    def __init__(s, b):
        s.b = b; s.sec = {}
        o = 0
        while o + 8 <= len(b):
            t = b[o:o+4]; n = int.from_bytes(b[o+4:o+8], 'big')
            if n < 8 or not t.isalpha(): break
            s.sec[t.decode()] = (o + 8, o + n); o += n
        s.parse_schema(); s.parse_blocks(); s.parse_enums()
    def u32(s, o): return struct.unpack_from('<I', s.b, o)[0]
    def pad(s, o): return s.b[o:o+8] == b'\xaa' * 8
    def parse_schema(s):
        p, end = s.sec['LSCH']
        order = []
        while p + 32 <= end and s.pad(p + 16):
            order.append((s.u32(p), s.b[p+8], s.u32(p+24), s.b[p+30] | s.b[p+31] << 8, s.b[p:p+32].hex()))
            p += 32
        s.structs = {}
        for name, typ, size, count, raw in order:
            mem = []
            for _ in range(count):
                mem.append((s.u32(p), s.u32(p+4), s.u32(p+8), s.u32(p+12))); p += 16
            s.structs[name] = (typ, size, mem, raw)
    def parse_enums(s):
        s.enums = {}
        if 'LENM' not in s.sec: return
        p, end = s.sec['LENM']
        s.enum_raw = s.b[p:end]
    def parse_blocks(s):
        p, end = s.sec['PSIN']
        recs = []
        while p + 16 <= end and s.pad(p + 8):
            recs.append((s.u32(p), s.u32(p+4))); p += 16
        s.blocks = []
        for t, size in recs:
            p = (p + 15) & ~15
            if p + size > end: break
            s.blocks.append((t, p, size)); p += size
    def locate(s, off):
        for i, (t, p, size) in enumerate(s.blocks):
            if p <= off < p + size:
                st = s.structs.get(t)
                if st and st[1]:
                    inst, rel = divmod(off - p, st[1])
                    m = [x for x in st[2] if x[1] <= rel]
                    m = max(m, key=lambda x: x[1]) if m else None
                    return i, t, inst, rel, m
                return i, t, None, off - p, None
        return None

if __name__ == '__main__':
    b = open(sys.argv[1], 'rb').read()
    p = PSO(b)
    print('structs', len(p.structs), 'blocks', len(p.blocks))
    for n, (typ, size, mem, raw) in p.structs.items():
        cnt = sum(sz // size for t, _, sz in p.blocks if t == n) if size else 0
        print('struct %08x type %02x size %d members %d instances %d' % (n, typ, size, len(mem), cnt))
        for m in mem: print('   %08x off %3d type %02x ref %08x' % m)
    names = sys.argv[2:]
    for nm in names:
        for h in (joaat(nm), joaat(nm, False)):
            hb = struct.pack('<I', h); o = b.find(hb)
            while o >= 0:
                print(nm, '%08x' % h, hex(o), p.locate(o)); o = b.find(hb, o + 1)
