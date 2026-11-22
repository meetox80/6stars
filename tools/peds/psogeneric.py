import sys, os, json, re
sys.path.insert(0, os.path.expanduser("~/testing/6stars/tools"))
from pso import PSO
from psodump import Dumper
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rpf import joaat

def lut_from_names():
    lut = {}
    here = os.path.dirname(os.path.abspath(__file__))
    words = set()
    for l in open(os.path.join(here, "..", "packs_names.tsv")):
        n = l.split("\t")[2]
        words.add(n)
        parts = n.split("_")
        for i in range(1, len(parts) + 1):
            words.add("_".join(parts[:i]))
        m = re.match(r"player_story000_0[01]_(.*)", n)
        if m:
            words.add(m.group(1))
    for w in words:
        lut.setdefault(joaat(w), w)
    return lut

def main():
    p = PSO(open(sys.argv[1], "rb").read())
    lut = lut_from_names()
    d = Dumper(p, lut)
    print("structs")
    for n, (typ, size, mem, raw) in p.structs.items():
        print(" %08x size %d members %s" % (n, size, [("%08x" % m[0], m[1], "%x" % m[2], "%08x" % m[3]) for m in mem]))
    print("blocks", [("%08x" % t, o, s) for t, o, s in p.blocks])
    t, o, size = p.blocks[int(sys.argv[2]) if len(sys.argv) > 2 else 0]
    json.dump(d.obj(t, o), open(sys.argv[3] if len(sys.argv) > 3 else "/dev/stdout", "w"), indent=1)

if __name__ == '__main__':
    main()
