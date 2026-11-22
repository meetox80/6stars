import struct
import zlib

TAG_DATA = 0x55
TAG_MUSIC = 0x48
TAG_SFX = 0xFA
TAG_SFX_V = 0x76
TAG_SEEK = 0xA3

CODEC_NAMES = {
    0x00: "pcm",
    0x01: "pcm",
    0x02: "pcm-float",
    0x04: "ima",
    0x05: "xma2",
    0x07: "mpeg",
    0x08: "vorbis",
    0x0B: "opus",
    0x0D: "opus-d11a",
    0x0F: "atrac9",
    0xFF: "midi",
}

FRAME = 0x800


class AwcError(Exception):
    pass


def parse_header(b):
    if b[:4] != b"ADAT":
        raise AwcError("not an AWC (missing ADAT magic)")
    flags, count, header_size = struct.unpack_from("<IiI", b, 4)
    if (flags & 0xFF00FFFF) != 0xFF000001:
        raise AwcError(f"unknown flags {flags:#010x}")
    off = 0x10
    if flags & 0x00400000:
        off += 4
    if flags & 0x00010000:
        off += 2 * count
    if flags & 0x00200000:
        off += 4 * (1 + count)
    streams = []
    for _ in range(count):
        v = struct.unpack_from("<I", b, off)[0]
        streams.append({"id": v & 0x1FFFFFFF, "tag_count": v >> 29, "tags": {}})
        off += 4
    for s in streams:
        for _ in range(s["tag_count"]):
            t = struct.unpack_from("<Q", b, off)[0]
            off += 8
            s["tags"][t >> 56] = ((t >> 28) & 0x0FFFFFFF, t & 0x0FFFFFFF)
    if off != header_size:
        raise AwcError(f"header size mismatch: parsed {off:#x}, header says {header_size:#x}")
    return flags, streams


def parse(b):
    flags, streams = parse_header(b)
    awc = {"flags": flags, "streams": streams, "sounds": []}
    first = streams[0] if streams else None
    if first is not None and first["id"] == 0 and TAG_MUSIC in first["tags"]:
        awc["sounds"].append(_music(b, first, streams))
    else:
        for s in streams:
            snd = _sfx(b, s)
            if snd:
                awc["sounds"].append(snd)
    return awc


def total_size(b):
    _, streams = parse_header(b)
    end = struct.unpack_from("<I", b, 12)[0]
    for s in streams:
        for size, off in s["tags"].values():
            end = max(end, off + size)
    return end


def _sfx(b, s):
    tags = s["tags"]
    if TAG_DATA not in tags:
        return None
    size, off = tags[TAG_DATA]
    inner = 1
    if TAG_SFX_V in tags:
        _, h = tags[TAG_SFX_V]
        samples = struct.unpack_from("<I", b, h)[0]
        rate = struct.unpack_from("<H", b, h + 8)[0]
        codec = b[h + 0x1C]
        if codec == 0x0B:
            inner = b[h + 0x1D] or 1
    elif TAG_SFX in tags:
        _, h = tags[TAG_SFX]
        samples = struct.unpack_from("<I", b, h)[0]
        rate = struct.unpack_from("<H", b, h + 8)[0]
        codec = b[h + 0x13]
    else:
        return None
    return {
        "id": s["id"],
        "kind": "sfx",
        "codec": codec,
        "channels": 1,
        "inner_channels": inner,
        "rate": rate,
        "samples": samples // inner,
        "chunks": [[(off, size)]],
    }


def _music(b, first, streams):
    _, moff = first["tags"][TAG_MUSIC]
    block_count, block_chunk, channels = struct.unpack_from("<III", b, moff)
    ids, codec, rate, samples, inner = [], None, None, 0, 1
    for ch in range(channels):
        cid, ns, _hr, sr, cc, ic = struct.unpack_from("<IIHHBB", b, moff + 0x0C + 0x10 * ch)
        ids.append(cid)
        if codec is not None and cc != codec:
            raise AwcError("channels use different codecs")
        if cc == 0x0B:
            inner = max(inner, ic or 1)
        codec, rate, samples = cc, sr, max(samples, ns)
    samples //= inner
    dsize, doff = first["tags"][TAG_DATA]
    per_channel = [[] for _ in range(channels)]
    if codec == 0x0B:
        for blk in range(block_count):
            base = doff + blk * block_chunk
            if base >= doff + dsize:
                break
            entries = [struct.unpack_from("<i", b, base + 0x18 * ch + 4)[0] for ch in range(channels)]
            hdr = 0x18 * channels + 4 * sum(entries)
            data_start = base + ((hdr + FRAME - 1) // FRAME) * FRAME
            pos = data_start
            for ch in range(channels):
                per_channel[ch].append((pos, entries[ch] * FRAME))
                pos += entries[ch] * FRAME
    return {
        "id": 0,
        "kind": "music",
        "codec": codec,
        "channels": channels,
        "inner_channels": inner,
        "channel_ids": ids,
        "rate": rate,
        "samples": samples,
        "block_count": block_count,
        "block_chunk": block_chunk,
        "chunks": per_channel,
    }


def opus_packets(b, ranges):
    for off, size in ranges:
        for f in range(0, size, FRAME):
            p = off + f
            end = min(p + FRAME, off + size)
            while p + 2 <= end:
                n = struct.unpack_from("<H", b, p)[0]
                if n == 0 or p + 2 + n > end:
                    break
                yield b[p + 2:p + 2 + n]
                p += 2 + n


def opus_samples(pkt):
    toc = pkt[0]
    cfg = toc >> 3
    if cfg < 12:
        fs = (480, 960, 1920, 2880)[cfg & 3]
    elif cfg < 16:
        fs = (480, 960)[cfg & 1]
    else:
        fs = (120, 240, 480, 960)[cfg & 3]
    code = toc & 3
    if code == 0:
        n = 1
    elif code in (1, 2):
        n = 2
    else:
        n = pkt[1] & 0x3F if len(pkt) > 1 else 0
    return fs * n


def _crc_table():
    t = []
    for i in range(256):
        r = i << 24
        for _ in range(8):
            r = ((r << 1) ^ 0x04C11DB7) if r & 0x80000000 else (r << 1)
        t.append(r & 0xFFFFFFFF)
    return t


_CRC = _crc_table()


def _ogg_crc(data):
    c = 0
    for x in data:
        c = ((c << 8) & 0xFFFFFFFF) ^ _CRC[((c >> 24) & 0xFF) ^ x]
    return c


class OggWriter:
    def __init__(self, fh, serial):
        self.fh = fh
        self.serial = serial
        self.seq = 0

    def page(self, packets, granule, bos=False, eos=False):
        lacing = bytearray()
        for p in packets:
            n = len(p)
            lacing += b"\xff" * (n // 255) + bytes([n % 255])
        if len(lacing) > 255:
            raise AwcError("too many segments for one ogg page")
        flags = (0x02 if bos else 0) | (0x04 if eos else 0)
        hdr = struct.pack("<4sBBqIIIB", b"OggS", 0, flags, granule, self.serial, self.seq, 0, len(lacing)) + bytes(lacing)
        body = b"".join(packets)
        crc = _ogg_crc(hdr + body)
        hdr = hdr[:22] + struct.pack("<I", crc) + hdr[26:]
        self.fh.write(hdr + body)
        self.seq += 1


def write_ogg_opus(fh, packets, channels, rate, samples, serial, pre_skip=0):
    w = OggWriter(fh, serial)
    head = struct.pack("<8sBBHIhB", b"OpusHead", 1, channels, pre_skip, rate, 0, 0)
    w.page([head], 0, bos=True)
    vendor = b"rpf9-audio"
    w.page([struct.pack("<8sI", b"OpusTags", len(vendor)) + vendor + struct.pack("<I", 0)], 0)
    packets = list(packets)
    lengths = [opus_samples(p) for p in packets]
    decoded = sum(lengths)
    end = min(samples, decoded)
    tail_start, acc = len(packets), 0
    for i, n in enumerate(lengths):
        if acc + n > end:
            tail_start = i
            break
        acc += n
    granule = pre_skip
    pending, segs, size = [], 0, 0
    for pkt, n in zip(packets[:tail_start], lengths[:tail_start]):
        need = len(pkt) // 255 + 1
        if pending and (segs + need > 255 or size > 8000):
            w.page(pending, granule)
            pending, segs, size = [], 0, 0
        pending.append(pkt)
        segs += need
        size += len(pkt)
        granule += n
    tail = packets[tail_start:]
    tail_segs = sum(len(p) // 255 + 1 for p in tail)
    if pending and segs + tail_segs > 255:
        w.page(pending, granule)
        pending = []
    w.page(pending + tail, pre_skip + end, eos=True)
    return decoded


def raw_bytes(b, ranges):
    return b"".join(b[o:o + n] for o, n in ranges)


def write_wav_float(fh, pcm, channels, rate):
    fmt = struct.pack("<HHIIHH", 3, channels, rate, rate * 4 * channels, 4 * channels, 32)
    fh.write(b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(pcm)) + b"WAVE")
    fh.write(b"fmt " + struct.pack("<I", len(fmt)) + fmt)
    fh.write(b"data" + struct.pack("<I", len(pcm)) + pcm)


def write_riff_xma2(fh, packets, channels, rate, samples):
    block = 0x10000
    blocks = max(1, (len(packets) + block - 1) // block)
    mask = 0x4 if channels == 1 else 0x3
    fmt = struct.pack("<HHIIHHH", 0x0166, channels, rate, len(packets) * rate // max(samples, 1), 0x800, 16, 34)
    fmt += struct.pack("<HIIIIIIIBBH", (channels + 1) // 2, mask, samples, block, 0, samples, 0, 0, 0, 4, blocks)
    fh.write(b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(packets)) + b"WAVE")
    fh.write(b"fmt " + struct.pack("<I", len(fmt)) + fmt)
    fh.write(b"data" + struct.pack("<I", len(packets)) + packets)


def stream_serial(awc_offset, sound_id, channel):
    return zlib.crc32(struct.pack("<QII", awc_offset, sound_id, channel)) & 0xFFFFFFFF
