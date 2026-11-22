import json
import mmap
import struct
import sys
import zlib
from multiprocessing import Pool

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from survey import read_index

ARCHIVE = None
SIZES = None


def init(path, sizes):
    global ARCHIVE, SIZES
    f = open(path, "rb")
    ARCHIVE = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    SIZES = sizes


def work(item):
    off, name = item
    try:
        b = zlib.decompress(ARCHIVE[off:off + SIZES[off]])
        sphere = struct.unpack_from("<4f", b, 0x20)
        mn = struct.unpack_from("<3f", b, 0x30)
        mx = struct.unpack_from("<3f", b, 0x40)
        lods = struct.unpack_from("<4f", b, 0x70)
        return [off, name, mn, mx, sphere, lods]
    except (zlib.error, struct.error):
        return None


def main():
    archive, index, survey_path, out = sys.argv[1:5]
    sizes = {o: s for o, s, u, k, h in read_index(index) if k == 2}
    items = []
    for line in open(survey_path):
        d = json.loads(line)
        if d.get("kind") == "drawable":
            items.append((d["off"], d["name"]))
    with Pool(12, initializer=init, initargs=(archive, sizes)) as pool, open(out, "w") as fh:
        for r in pool.imap(work, items, chunksize=256):
            if r:
                fh.write(json.dumps(r) + "\n")


if __name__ == "__main__":
    main()
