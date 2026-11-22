import sys
def joaat(s, lower=True):
    h = 0
    for c in (s.lower() if lower else s).encode():
        h = (h + c) & 0xffffffff; h = (h + (h << 10)) & 0xffffffff; h ^= h >> 6
    h = (h + (h << 3)) & 0xffffffff; h ^= h >> 11; h = (h + (h << 15)) & 0xffffffff
    return h
if __name__ == "__main__":
  for s in sys.argv[1:]:
    print('%08x %08x %s' % (joaat(s), joaat(s, False), s))
