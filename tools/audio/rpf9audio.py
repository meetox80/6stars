import argparse
import json
import os
import shlex
import struct
import subprocess
import sys
import time
import zlib

import awc

BLOCK = 0x1000
CHUNK = 1 << 22
MAX_AWC = 1 << 30
ZLIB_HEADS = (b"\x78\xda", b"\x78\x9c", b"\x78\x01", b"\x78\x5e")


def align(n):
    return (n + BLOCK - 1) // BLOCK * BLOCK


class LocalSource:
    def __init__(self, path):
        self.path = path

    def size(self):
        return os.path.getsize(self.path)

    def stream(self, start=0):
        with open(self.path, "rb") as fh:
            fh.seek(start)
            while True:
                c = fh.read(CHUNK)
                if not c:
                    return
                yield c

    def read(self, off, n):
        with open(self.path, "rb") as fh:
            fh.seek(off)
            return fh.read(n)


class SshSource:
    def __init__(self, spec):
        self.host, path = spec.split(":", 1)
        if path.startswith("~/"):
            self.rpath = '"$HOME"/' + shlex.quote(path[2:])
        else:
            self.rpath = shlex.quote(path)

    def _ssh(self, cmd):
        return ["ssh", "-o", "BatchMode=yes", self.host, cmd]

    def size(self):
        out = subprocess.run(self._ssh(f"wc -c < {self.rpath}"), capture_output=True, check=True, text=True)
        return int(out.stdout.strip())

    def stream(self, start=0):
        cmd = f"cat {self.rpath}" if start == 0 else f"dd if={self.rpath} bs={BLOCK} skip={start // BLOCK} 2>/dev/null"
        p = subprocess.Popen(self._ssh(cmd), stdout=subprocess.PIPE)
        try:
            while True:
                c = p.stdout.read(CHUNK)
                if not c:
                    break
                yield c
        finally:
            p.stdout.close()
            p.wait()

    def read(self, off, n):
        first = off // BLOCK
        count = (off + n + BLOCK - 1) // BLOCK - first
        cmd = f"dd if={self.rpath} bs={BLOCK} skip={first} count={count} 2>/dev/null"
        out = subprocess.run(self._ssh(cmd), capture_output=True, check=True).stdout
        return out[off - first * BLOCK:off - first * BLOCK + n]


def open_source(spec):
    if os.path.exists(spec):
        return LocalSource(spec)
    if ":" in spec:
        return SshSource(spec)
    raise SystemExit(f"no such file: {spec}")


class Window:
    def __init__(self, chunks):
        self.it = iter(chunks)
        self.buf = bytearray()
        self.base = 0
        self.eof = False

    def have(self, end):
        while self.base + len(self.buf) < end and not self.eof:
            c = next(self.it, None)
            if c is None:
                self.eof = True
            else:
                self.buf += c
        return self.base + len(self.buf) >= end

    def get(self, off, n):
        self.have(off + n)
        s = off - self.base
        return bytes(self.buf[s:s + n])

    def end(self):
        return self.base + len(self.buf)

    def drop_before(self, off):
        k = off - self.base
        if k > (64 << 20):
            del self.buf[:k]
            self.base = off


def sound_meta(s):
    return {
        "id": f"{s['id']:08x}",
        "kind": s["kind"],
        "codec": awc.CODEC_NAMES.get(s["codec"], f"{s['codec']:#04x}"),
        "streams": s["channels"],
        "channels": s.get("inner_channels", 1),
        "rate": s["rate"],
        "samples": s["samples"],
        "seconds": round(s["samples"] / s["rate"], 3) if s["rate"] else None,
    }


def walk(chunks, progress=None):
    w = Window(chunks)
    pos = 0
    last = time.time()
    while w.have(pos + 16):
        w.drop_before(pos)
        if progress and time.time() - last > 5:
            progress(pos)
            last = time.time()
        head = w.get(pos, 16)
        if head[:4] == b"ADAT":
            hsize = struct.unpack_from("<I", head, 12)[0]
            try:
                if not 0x10 <= hsize <= (16 << 20):
                    raise awc.AwcError(f"implausible header size {hsize:#x}")
                hdr = w.get(pos, hsize)
                size = awc.total_size(hdr)
                if size > MAX_AWC:
                    raise awc.AwcError(f"implausible size {size:#x}")
                if not w.have(pos + size):
                    raise awc.AwcError("truncated at end of archive")
                data = w.get(pos, size)
                parsed = awc.parse(data)
            except (awc.AwcError, struct.error) as e:
                yield {"kind": "awc", "off": pos, "error": str(e)}, None
                pos += BLOCK
                continue
            yield {"kind": "awc", "off": pos, "size": size, "flags": f"{parsed['flags']:#010x}", "sounds": [sound_meta(s) for s in parsed["sounds"]]}, (data, parsed)
            pos = align(pos + size)
        elif head[:4] == b"9FPR":
            toc = struct.unpack_from("<I", head, 4)[0]
            yield {"kind": "rpf9", "off": pos, "toc_size": toc}, None
            pos = align(pos + max(toc, 1))
        elif head[:2] in ZLIB_HEADS:
            d = zlib.decompressobj()
            p = pos
            out_len, out_head, ok = 0, b"", False
            try:
                while w.have(p + 1):
                    seg = w.get(p, 1 << 20)
                    r = d.decompress(seg)
                    if not out_head:
                        out_head = r[:32]
                    out_len += len(r)
                    if d.eof:
                        p += len(seg) - len(d.unused_data)
                        ok = True
                        break
                    p += len(seg)
            except zlib.error:
                ok = False
            if ok:
                yield {"kind": "zlib", "off": pos, "size": p - pos, "unpacked": out_len, "head": out_head.hex()}, None
                pos = align(p)
            else:
                pos += BLOCK
        else:
            pos += BLOCK
    yield {"kind": "end", "off": w.end()}, None


def cmd_index(args):
    src = open_source(args.source)
    total = src.size()
    stats = {"awc": 0, "awc_errors": 0, "sounds": 0, "rpf9": 0, "zlib": 0, "codecs": {}}

    def progress(pos):
        print(f"\r{pos / 1e9:6.2f} / {total / 1e9:.2f} GB  awc={stats['awc']} sounds={stats['sounds']} errors={stats['awc_errors']}", end="", file=sys.stderr, flush=True)

    with open(args.output, "w") as out:
        out.write(json.dumps({"kind": "source", "spec": args.source, "size": total}) + "\n")
        for rec, _ in walk(src.stream(), progress):
            out.write(json.dumps(rec) + "\n")
            k = rec["kind"]
            if k == "awc" and "error" in rec:
                stats["awc_errors"] += 1
            elif k == "awc":
                stats["awc"] += 1
                stats["sounds"] += len(rec["sounds"])
                for s in rec["sounds"]:
                    stats["codecs"][s["codec"]] = stats["codecs"].get(s["codec"], 0) + 1
            elif k in ("rpf9", "zlib"):
                stats[k] += 1
    progress(total)
    print(file=sys.stderr)
    print(json.dumps(stats, indent=1))


def load_catalog(path):
    recs = [json.loads(l) for l in open(path)]
    return [r for r in recs if r["kind"] == "awc" and "error" not in r]


def cmd_list(args):
    for r in load_catalog(args.catalog):
        secs = sum(s["seconds"] or 0 for s in r["sounds"])
        codecs = sorted({s["codec"] for s in r["sounds"]})
        kinds = sorted({s["kind"] for s in r["sounds"]})
        print(f"{r['off']:#013x}  {r['size']:>10}  {r['flags']}  {len(r['sounds']):>4} {'/'.join(kinds):<9} {','.join(codecs):<8} {secs:9.1f}s")


def write_sound(data, parsed_sound, awc_off, outdir, wav):
    s = parsed_sound
    written = []
    if s["codec"] == 0x02 and s["kind"] == "sfx":
        path = os.path.join(outdir, f"{s['id']:08x}.wav")
        pcm = awc.raw_bytes(data, s["chunks"][0])[:s["samples"] * 4]
        with open(path, "wb") as fh:
            awc.write_wav_float(fh, pcm, 1, s["rate"])
        return [path], None
    if s["codec"] == 0x05 and s["kind"] == "sfx":
        path = os.path.join(outdir, f"{s['id']:08x}.xma")
        with open(path, "wb") as fh:
            awc.write_riff_xma2(fh, awc.raw_bytes(data, s["chunks"][0]), 1, s["rate"], s["samples"])
        written.append(path)
        if wav:
            wpath = path[:-4] + ".wav"
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, wpath], check=True)
            written.append(wpath)
        return written, None
    if s["codec"] != 0x0B:
        return written, f"{s['kind']} codec {awc.CODEC_NAMES.get(s['codec'], hex(s['codec']))} not supported"
    for ch, ranges in enumerate(s["chunks"]):
        suffix = f"_ch{ch}" if len(s["chunks"]) > 1 else ""
        name = f"{s['id']:08x}{suffix}.opus"
        path = os.path.join(outdir, name)
        try:
            with open(path, "wb") as fh:
                awc.write_ogg_opus(fh, awc.opus_packets(data, ranges), s.get("inner_channels", 1), s["rate"], s["samples"], awc.stream_serial(awc_off, s["id"], ch))
        except awc.AwcError as e:
            os.remove(path)
            return written, str(e)
        written.append(path)
        if wav:
            wpath = path[:-5] + ".wav"
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, wpath], check=True)
            written.append(wpath)
    return written, None


def extract_awc(data, parsed, off, outroot, wav):
    outdir = os.path.join(outroot, f"{off:011x}")
    os.makedirs(outdir, exist_ok=True)
    files, problems = [], []
    for s in parsed["sounds"]:
        w, err = write_sound(data, s, off, outdir, wav)
        files += w
        if err:
            problems.append(f"{off:#x}/{s['id']:08x}: {err}")
    return files, problems


def cmd_extract(args):
    src = open_source(args.source)
    os.makedirs(args.outdir, exist_ok=True)
    nfiles, problems = 0, []
    if args.all:
        total = src.size()

        def progress(pos):
            print(f"\r{pos / 1e9:6.2f} / {total / 1e9:.2f} GB  files={nfiles}", end="", file=sys.stderr, flush=True)

        for rec, payload in walk(src.stream(), progress):
            if payload:
                f, p = extract_awc(payload[0], payload[1], rec["off"], args.outdir, args.wav)
                nfiles += len(f)
                problems += p
        print(file=sys.stderr)
    else:
        if not args.catalog:
            raise SystemExit("--catalog is required unless --all is given")
        cat = {r["off"]: r for r in load_catalog(args.catalog)}
        for o in args.awc:
            off = int(o, 0)
            if off not in cat:
                raise SystemExit(f"no AWC at {off:#x} in catalog")
            data = src.read(off, cat[off]["size"])
            f, p = extract_awc(data, awc.parse(data), off, args.outdir, args.wav)
            nfiles += len(f)
            problems += p
            for path in f:
                print(path)
    print(f"{nfiles} files written to {args.outdir}", file=sys.stderr)
    for p in problems:
        print("skipped", p, file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(prog="rpf9audio", description="Read AWC audio out of RPF9 archives")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("index", help="scan an archive and write a catalog of every entry")
    a.add_argument("source", help="local path or user@host:path")
    a.add_argument("-o", "--output", default="catalog.jsonl")
    a.set_defaults(fn=cmd_index)
    a = sub.add_parser("list", help="list AWC containers from a catalog")
    a.add_argument("catalog")
    a.set_defaults(fn=cmd_list)
    a = sub.add_parser("extract", help="write sounds as Ogg Opus")
    a.add_argument("source", help="local path or user@host:path")
    a.add_argument("outdir")
    a.add_argument("--catalog")
    a.add_argument("--awc", nargs="*", default=[], help="AWC offsets from the catalog")
    a.add_argument("--all", action="store_true", help="stream the whole archive and extract everything")
    a.add_argument("--wav", action="store_true", help="also decode each file to WAV with ffmpeg")
    a.set_defaults(fn=cmd_extract)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
