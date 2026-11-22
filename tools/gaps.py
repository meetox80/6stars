import mmap
import sys
import zlib

archive, index_stats, outdir = sys.argv[1:4]
f = open(archive, "rb")
mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
for line in open(index_stats):
    p = line.split()
    if len(p) != 3 or not p[0].startswith("0x"):
        continue
    off, size = int(p[0], 16), int(p[1])
    pos = off
    end = off + size
    parts = 0
    total = 0
    heads = []
    while pos < end - 2:
        if mm[pos] != 0x78:
            pos += 1
            continue
        d = zlib.decompressobj()
        try:
            data = d.decompress(mm[pos:end])
        except zlib.error:
            pos += 1
            continue
        if not d.eof:
            pos += 1
            continue
        used = (end - pos) - len(d.unused_data)
        if parts < 3:
            heads.append((hex(pos), len(data), data[:24].hex()))
            open(f"{outdir}/gap_{pos:011x}.bin", "wb").write(data)
        parts += 1
        total += len(data)
        pos += used
    print(hex(off), size, "streams", parts, "unpacked", total, heads)
