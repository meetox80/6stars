import sys
class Bits:
    def __init__(s, b, byte): s.b = b; s.p = byte * 8
    def u(s, n):
        v = 0
        for _ in range(n):
            byte = s.p >> 3
            bit = (s.b[byte] >> (7 - (s.p & 7))) & 1 if byte < len(s.b) else 0
            v = (v << 1) | bit; s.p += 1
        return v
    def s_(s, n):
        if n == 0: return 0
        v = s.u(n)
        return v - (1 << n) if v & (1 << (n - 1)) else v
    def align(s): s.p = (s.p + 7) & ~7
b = bytes.fromhex(sys.argv[1]); version = int(sys.argv[2])
bt = Bits(b, 2)
n = bt.u(5); r = [bt.s_(n) / 20 for _ in range(4)]; bt.align(); print('bounds', r)
def color():
    c = [bt.u(8) for _ in range(4 if version >= 3 else 3)]; return c
def fills():
    n = bt.u(8)
    out = []
    for _ in range(n):
        t = bt.u(8); print('  fill type', t)
        if t == 0: out.append(color())
        else: raise Exception('type %d' % t)
    return out
def lines():
    n = bt.u(8)
    for _ in range(n): bt.u(16); color()
    print('  lines', n)
print('fills', fills()); lines()
fb, lb = bt.u(4), bt.u(4); print('bits', fb, lb)
end = len(b) * 8
while bt.p < end:
    if bt.u(1) == 0:
        f = bt.u(5)
        if f == 0: print('end at', bt.p // 8, len(b)); break
        rec = []
        if f & 1:
            nn = bt.u(5); rec.append(('move', bt.s_(nn) / 20, bt.s_(nn) / 20))
        if f & 2: rec.append(('f0', bt.u(fb)))
        if f & 4: rec.append(('f1', bt.u(fb)))
        if f & 8: rec.append(('ls', bt.u(lb)))
        if f & 16:
            bt.align(); rec.append(('new', fills())); lines(); fb, lb = bt.u(4), bt.u(4); rec.append(('bits', fb, lb))
        print('style', bin(f), rec)
    elif bt.u(1) == 1:
        nn = bt.u(4) + 2
        if bt.u(1) == 1: d = (bt.s_(nn), bt.s_(nn))
        elif bt.u(1) == 1: d = (0, bt.s_(nn))
        else: d = (bt.s_(nn), 0)
        print('  line', d)
    else:
        nn = bt.u(4) + 2
        print('  curve', [bt.s_(nn) for _ in range(4)])
