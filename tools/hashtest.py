import sys, os, re, struct, glob, mmap
M = (1 << 64) - 1
def joaat(s):
    h = 0
    for c in s:
        h = (h + c) & 0xffffffff; h = (h + (h << 10)) & 0xffffffff; h ^= h >> 6
    h = (h + (h << 3)) & 0xffffffff; h ^= h >> 11; h = (h + (h << 15)) & 0xffffffff
    return h
def joaat64(s):
    h = 0
    for c in s:
        h = (h + c) & M; h = (h + (h << 10)) & M; h ^= h >> 6
    h = (h + (h << 3)) & M; h ^= h >> 11; h = (h + (h << 15)) & M
    return h
def fnv1a(s):
    h = 0xcbf29ce484222325
    for c in s: h = ((h ^ c) * 0x100000001b3) & M
    return h
def fnv1(s):
    h = 0xcbf29ce484222325
    for c in s: h = ((h * 0x100000001b3) & M) ^ c
    return h
P1, P2, P3, P4, P5 = 11400714785074694791, 14029467366897019727, 1609587929392839161, 9650029242287828579, 2870177450012600261
def rotl(x, r): return ((x << r) | (x >> (64 - r))) & M
def xxh64(b, seed=0):
    n = len(b); p = 0
    if n >= 32:
        v1 = (seed + P1 + P2) & M; v2 = (seed + P2) & M; v3 = seed; v4 = (seed - P1) & M
        def rnd(a, x): return (rotl((a + x * P2) & M, 31) * P1) & M
        while p + 32 <= n:
            v1 = rnd(v1, struct.unpack_from('<Q', b, p)[0]); v2 = rnd(v2, struct.unpack_from('<Q', b, p + 8)[0])
            v3 = rnd(v3, struct.unpack_from('<Q', b, p + 16)[0]); v4 = rnd(v4, struct.unpack_from('<Q', b, p + 24)[0]); p += 32
        h = (rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18)) & M
        for v in (v1, v2, v3, v4):
            h ^= rnd(0, v); h = (h * P1 + P4) & M
    else:
        h = (seed + P5) & M
    h = (h + n) & M
    while p + 8 <= n:
        k = (rotl((struct.unpack_from('<Q', b, p)[0] * P2) & M, 31) * P1) & M
        h ^= k; h = (rotl(h, 27) * P1 + P4) & M; p += 8
    if p + 4 <= n:
        h ^= (struct.unpack_from('<I', b, p)[0] * P1) & M; h = (rotl(h, 23) * P2 + P3) & M; p += 4
    while p < n:
        h ^= (b[p] * P5) & M; h = (rotl(h, 11) * P1) & M; p += 1
    h ^= h >> 33; h = (h * P2) & M; h ^= h >> 29; h = (h * P3) & M; h ^= h >> 32
    return h
def murmur64a(b, seed=0):
    m = 0xc6a4a7935bd1e995; r = 47; n = len(b)
    h = (seed ^ (n * m)) & M; p = 0
    while p + 8 <= n:
        k = struct.unpack_from('<Q', b, p)[0]; k = (k * m) & M; k ^= k >> r; k = (k * m) & M
        h ^= k; h = (h * m) & M; p += 8
    rem = n - p
    if rem:
        t = int.from_bytes(b[p:], 'little'); h ^= t; h = (h * m) & M
    h ^= h >> r; h = (h * m) & M; h ^= h >> r
    return h
def fmix(k):
    k ^= k >> 33; k = (k * 0xff51afd7ed558ccd) & M; k ^= k >> 33; k = (k * 0xc4ceb9fe1a85ec53) & M; k ^= k >> 33; return k
def murmur3_128(b, seed=0):
    c1, c2 = 0x87c37b91114253d5, 0x4cf5ad432745937f
    h1 = h2 = seed; n = len(b); p = 0
    while p + 16 <= n:
        k1, k2 = struct.unpack_from('<QQ', b, p); p += 16
        k1 = (k1 * c1) & M; k1 = rotl(k1, 31); k1 = (k1 * c2) & M; h1 ^= k1
        h1 = rotl(h1, 27); h1 = (h1 + h2) & M; h1 = (h1 * 5 + 0x52dce729) & M
        k2 = (k2 * c2) & M; k2 = rotl(k2, 33); k2 = (k2 * c1) & M; h2 ^= k2
        h2 = rotl(h2, 31); h2 = (h2 + h1) & M; h2 = (h2 * 5 + 0x38495ab5) & M
    t = b[p:]
    k1 = int.from_bytes(t[:8], 'little'); k2 = int.from_bytes(t[8:], 'little')
    if len(t) > 8:
        k2 = (k2 * c2) & M; k2 = rotl(k2, 33); k2 = (k2 * c1) & M; h2 ^= k2
    if len(t) > 0:
        k1 = (k1 * c1) & M; k1 = rotl(k1, 31); k1 = (k1 * c2) & M; h1 ^= k1
    h1 ^= n; h2 ^= n; h1 = (h1 + h2) & M; h2 = (h2 + h1) & M
    h1 = fmix(h1); h2 = fmix(h2); h1 = (h1 + h2) & M; h2 = (h2 + h1) & M
    return h1, h2
def crc64(b, poly, refl, init=0, xorout=0):
    if refl:
        crc = init
        for c in b:
            crc ^= c
            for _ in range(8): crc = (crc >> 1) ^ (poly if crc & 1 else 0)
    else:
        crc = init
        for c in b:
            crc ^= c << 56
            for _ in range(8): crc = ((crc << 1) & M) ^ (poly if crc >> 63 else 0)
    return crc ^ xorout
def djb2(s):
    h = 5381
    for c in s: h = (h * 33 + c) & M
    return h
def sdbm(s):
    h = 0
    for c in s: h = (c + (h << 6) + (h << 16) - h) & M
    return h

funcs = {
    'fnv1a': fnv1a, 'fnv1': fnv1, 'xxh64': xxh64, 'murmur64a': murmur64a,
    'mm3lo': lambda b: murmur3_128(b)[0], 'mm3hi': lambda b: murmur3_128(b)[1],
    'crc64ecma': lambda b: crc64(b, 0x42F0E1EBA9EA3693, False),
    'crc64ecmaR': lambda b: crc64(b, 0xC96C5795D7870F42, True, M, M),
    'crc64iso': lambda b: crc64(b, 0xD800000000000000, True),
    'joaat64': joaat64, 'djb2': djb2, 'sdbm': sdbm,
}

def load_hashes(roots):
    hs = set()
    for root in roots:
        for p in glob.glob(root + '/**/*.ttpf', recursive=True):
            f = open(p, 'rb'); m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
            if m[:4] != b'RDS5': continue
            e = struct.unpack_from('<I', m, 0x10)[0] * 256
            if m[e:e+4] != b'ETPF': continue
            n = struct.unpack_from('<I', m, e + 8)[0]
            h0 = e + 16 + 16 * n
            hs.update(struct.unpack_from('<%dQ' % n, m, h0))
    return hs

if __name__ == '__main__':
    hs = load_hashes(sys.argv[1].split(','))
    print('hashes', len(hs))
    pairs = [l.rstrip('\n').split('\t') for l in open(sys.argv[2]) if '\t' in l]
    cands = set()
    for txd, name in pairs:
        for nm in {name, name.lower(), name.upper()}:
            for t in {txd, txd.lower()}:
                cands.update([nm, nm + '.dds', t + '/' + nm, t + ':' + nm, t + '.' + nm, t + '_' + nm, t + '/' + nm + '.dds', t + '\\' + nm, t + '::' + nm, t + nm,
                              'platform:/textures/' + t + '/' + nm, 'ui/' + t + '/' + nm, t + '.ytd/' + nm, t + '/' + nm + '.tif', nm + '.tif', nm + '.png', t + '/' + nm + '.png'])
    print('candidates', len(cands))
    hits = {}
    for c in cands:
        b = c.encode()
        for fn, f in funcs.items():
            v = f(b)
            if v in hs: hits.setdefault(fn, []).append(c)
            vs = ((v >> 32) | (v << 32)) & M
            if vs in hs: hits.setdefault(fn + '_swap', []).append(c)
            if struct.unpack('>Q', struct.pack('<Q', v))[0] in hs: hits.setdefault(fn + '_be', []).append(c)
    for txd, name in pairs:
        for nm in {name, name.lower()}:
            for t in {txd, txd.lower()}:
                a, b2 = joaat(t.encode()), joaat(nm.encode())
                for lab, v in (('jt<<32|jn', a << 32 | b2), ('jn<<32|jt', b2 << 32 | a)):
                    if v in hs: hits.setdefault(lab, []).append(t + '/' + nm)
    for k, v in hits.items(): print(k, len(v), v[:10])
    print('done')
