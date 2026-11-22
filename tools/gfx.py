import struct, sys, collections

class Bits:
    def __init__(s, b, p): s.b = b; s.p = p * 8
    def u(s, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | ((s.b[s.p >> 3] >> (7 - (s.p & 7))) & 1); s.p += 1
        return v
    def byte(s): return (s.p + 7) >> 3

def tags(b):
    assert b[:3] == b'GFX'
    bt = Bits(b, 8)
    nb = bt.u(5)
    rect = [bt.u(nb) for _ in range(4)]
    p = bt.byte()
    rate, frames = struct.unpack_from('<HH', b, p); p += 4
    out = []
    while p < len(b):
        cl = struct.unpack_from('<H', b, p)[0]; p += 2
        code, ln = cl >> 6, cl & 0x3f
        if ln == 0x3f:
            ln = struct.unpack_from('<I', b, p)[0]; p += 4
        out.append((code, p, ln))
        p += ln
        if code == 0: break
    return rect, rate, frames, out

if __name__ == '__main__':
    for f in sys.argv[1:]:
        b = open(f, 'rb').read()
        rect, rate, frames, ts = tags(b)
        c = collections.Counter(t[0] for t in ts)
        names = []
        for code, p, ln in ts:
            if code in (48, 75, 1005, 91):
                fid = struct.unpack_from('<H', b, p)[0]
                if code in (48, 75):
                    flags = b[p+2]; nl = b[p+4]; names.append('%d:%s' % (code, b[p+5:p+5+nl].decode('latin1')))
                elif code == 91:
                    flags = b[p+2]; e = b.index(0, p+3); names.append('91:%s' % b[p+3:e].decode('latin1'))
                else:
                    names.append('1005:' + b[p+2:p+40].hex())
            if code == 1000:
                names.append('exp:' + b[p:p+min(ln,60)].hex())
            if code == 56:
                n = struct.unpack_from('<H', b, p)[0]; q = p + 2; ex = []
                for _ in range(n):
                    cid = struct.unpack_from('<H', b, q)[0]; e = b.index(0, q+2); ex.append(b[q+2:e].decode('latin1')); q = e + 1
                names.append('export:' + ','.join(ex[:12]) + ('…%d' % len(ex) if len(ex) > 12 else ''))
        print(f, len(b), [r / 20 for r in rect], rate / 256, frames, dict(sorted(c.items())))
        for n in names[:20]: print('   ', n)

def dump_tag(f, code, limit=20):
    b = open(f, 'rb').read()
    _, _, _, ts = tags(b)
    for c, p, ln in ts:
        if c == code:
            print(c, ln, b[p:p+min(ln, 96)].hex(), repr(b[p:p+min(ln, 96)]))
            limit -= 1
            if limit == 0: break
