import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rpf import *
from concurrent.futures import ProcessPoolExecutor
rpf, idx, pat = sys.argv[1], sys.argv[2], sys.argv[3].encode()
maxhits = int(sys.argv[4]) if len(sys.argv) > 4 else 50
rx = re.compile(pat, re.I)

def work(args):
    lo, hi = args
    a = Archive(rpf, idx)
    out = []
    for i in range(lo, hi):
        e = a.entries[i]
        if e.kind != 2:
            continue
        try:
            d = a.load(e)
        except Exception:
            continue
        for m in rx.finditer(d):
            s = max(0, m.start() - 24)
            out.append((e.offset, m.start(), d[s:m.end() + 40]))
            if len(out) > 2000:
                return out
    return out

def main():
    a = Archive(rpf, idx)
    n = len(a.entries)
    step = 2000
    chunks = [(i, min(n, i + step)) for i in range(0, n, step)]
    hits = 0
    with ProcessPoolExecutor(8) as ex:
        for res in ex.map(work, chunks):
            for off, o, ctx in res:
                hits += 1
                if hits <= maxhits:
                    print("%x +%x %r" % (off, o, ctx))
    print("hits", hits)

if __name__ == '__main__':
    main()
