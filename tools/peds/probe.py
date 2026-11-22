import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sys
from rpf import *
a = packs()
off = int(sys.argv[1], 16)
v, p = a.resource(off)
print("virt", hex(len(v)), "phys", hex(len(p)))
print(hexdump(v, 0, int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x200))
