import Foundation

public struct TextureInfo: Sendable {
    public var width: Int
    public var height: Int
    public var format: Int
    public var split: Int
    public var offset: Int
    public var flags: UInt16
    public var hint: Int

    public var blockCompressed: Bool { TextureInfo.blockBytes(format) != nil }

    public static func blockBytes(_ dxgi: Int) -> Int? {
        switch dxgi {
        case 70, 71, 72, 79, 80, 81: return 8
        case 73, 74, 75, 76, 77, 78, 82, 83, 84, 94, 95, 96, 97, 98, 99: return 16
        default: return nil
        }
    }

    public static func pixelBytes(_ dxgi: Int) -> Int? {
        switch dxgi {
        case 2: return 16
        case 10, 11, 12, 13, 14, 16, 17, 18: return 8
        case 24, 25, 26, 27, 28, 29, 30, 31, 32, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 87, 88, 90, 91: return 4
        case 48, 49, 50, 51, 52, 53, 54, 56, 57, 58, 59, 85, 86: return 2
        case 60, 61, 62, 63, 64, 65: return 1
        default: return nil
        }
    }

    public var elementBytes: Int? { TextureInfo.blockBytes(format) ?? TextureInfo.pixelBytes(format) }
    public var blockSize: Int { blockCompressed ? 4 : 1 }

    public var mipCount: Int {
        var n = 1
        var w = width, h = height
        let minDim = blockCompressed ? 4 : 1
        while min(w, h) / 2 >= minDim {
            w /= 2
            h /= 2
            n += 1
        }
        return n
    }
}

public struct TextureImage: Sendable {
    public var info: TextureInfo
    public var mips: [[UInt8]]
    public var firstLevel: Int
}

public final class TTDBFile: @unchecked Sendable {
    public let path: String
    let file: MappedFile
    let chunkFile: [UInt64]
    let chunkStart: [Int]
    let chunkCodec: [UInt8]
    public let hashes: [UInt64]
    var nextOffset: [Int: Int] = [:]
    let descriptors: [(UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16)]

    public init(path: String) throws {
        self.path = path
        file = try MappedFile(path: path)
        guard file.size >= 0x20, file.u32(0) == 0x3553_4452 else { throw RPFError.format("not an RDS5 texture database: \(path)") }
        let n = max(0, Int(file.u32(4)) - 1)
        let e = Int(file.u32(0x10)) * 256
        guard 0x18 + 8 * n <= e, e + 16 <= file.size, file.u32(e) == 0x4650_5445 else { throw RPFError.format("RDS5 layout not understood: \(path)") }
        var fo: [UInt64] = [], st: [Int] = [], cp: [UInt8] = []
        fo.reserveCapacity(n); st.reserveCapacity(n); cp.reserveCapacity(n)
        var wrap = 0, prev = 0
        for i in 0..<n {
            let a = file.u32(0x18 + 8 * i), c = file.u32(0x1C + 8 * i)
            let page = Int(c & 0xFFFF)
            if page < prev { wrap += 0x10000 }
            prev = page
            fo.append(UInt64(a & 0x03FF_FFFF) * 256)
            st.append(((page + wrap) * 4 + Int((a >> 30) & 3)) * 0x1000)
            cp.append(a & (1 << 29) != 0 ? TTDBFile.zlib : UInt8((a >> 26) & 3))
        }
        chunkFile = fo
        chunkStart = st
        chunkCodec = cp
        let count = Int(file.u32(e + 8))
        let d0 = e + 16, h0 = d0 + 16 * count
        guard h0 + 8 * count <= file.size else { throw RPFError.format("ETPF tables truncated") }
        var ds: [(UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16)] = []
        var hs: [UInt64] = []
        ds.reserveCapacity(count); hs.reserveCapacity(count)
        for i in 0..<count {
            let o = d0 + 16 * i
            ds.append((file.u16(o), file.u16(o + 2), file.u16(o + 4), file.u16(o + 6), file.u16(o + 8), file.u16(o + 10), file.u16(o + 12), file.u16(o + 14)))
            hs.append(file.u64(h0 + 8 * i))
        }
        descriptors = ds
        hashes = hs
        let end = (st.last ?? 0) + 0x1000
        let offs = Array(Set((0..<count).map { i -> Int in
            let d = ds[i]
            return (Int(d.4) | Int(d.5 & 0x1F) << 16) * 0x1000
        })).sorted()
        for (k, o) in offs.enumerated() { nextOffset[o] = k + 1 < offs.count ? offs[k + 1] : max(end, o) }
    }

    public var count: Int { hashes.count }

    public func index(of hash: UInt64) -> Int? {
        var lo = 0, hi = hashes.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if hashes[mid] == hash { return mid }
            if hashes[mid] < hash { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    public func rawDescriptor(_ i: Int) -> String {
        let d = descriptors[i]
        return [d.0, d.1, d.2, d.3, d.4, d.5, d.6, d.7].map { String(format: "%04x", $0) }.joined(separator: " ")
    }

    public func info(_ i: Int) -> TextureInfo {
        let d = descriptors[i]
        let v = UInt32(d.0) | UInt32(d.1) << 16
        return TextureInfo(width: Int(v & 0x3FFF) + 1, height: Int((v >> 14) & 0x3FFF) + 1, format: Int(d.2 >> 3), split: Int(d.2 & 7),
                           offset: (Int(d.4) | Int(d.5 & 0x1F) << 16) * 0x1000, flags: d.3, hint: Int(d.1 >> 12))
    }

    static let zlib: UInt8 = 0xFF

    func chunkContaining(_ offset: Int) -> Int? {
        var lo = 0, hi = chunkStart.count - 1, best: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if chunkStart[mid] <= offset { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    func chunkSize(_ i: Int) -> Int {
        i + 1 < chunkStart.count ? chunkStart[i + 1] - chunkStart[i] : 0x1000
    }

    func chunk(_ i: Int) throws -> [UInt8]? {
        let off = Int(chunkFile[i])
        switch chunkCodec[i] {
        case TTDBFile.zlib:
            guard off < file.size else { return nil }
            return try Inflate.full(file.base + off, file.size - off, expected: chunkSize(i)).data
        case 0:
            guard off + chunkSize(i) <= file.size else { return nil }
            return file.bytes(off, chunkSize(i))
        default:
            return nil
        }
    }

    public func storedLevels(_ i: Int) -> Int {
        let inf = info(i)
        guard let eb = inf.elementBytes else { return inf.mipCount }
        return layoutOf(inf, TextureLayout(elementBytes: eb, mode: Int(inf.flags >> 8) & 3, bits: TextureDB.tileBits(eb, Int(inf.flags >> 8) & 3))).ranges.count
    }

    public func decodable(_ i: Int) -> (levels: Int, total: Int) {
        let total = storedLevels(i)
        guard let img = try? image(i) else { return (0, total) }
        return (img.mips.count, total)
    }

    public func check(_ i: Int) -> (layoutTotal: Int, chunkTotal: Int?) {
        let inf = info(i)
        guard let eb = inf.elementBytes else { return (0, nil) }
        let total = layoutOf(inf, TextureLayout(elementBytes: eb, mode: Int(inf.flags >> 8) & 3, bits: TextureDB.tileBits(eb, Int(inf.flags >> 8) & 3))).total
        guard let c = chunkContaining(inf.offset), chunkStart[c] == inf.offset else { return (total, nil) }
        var sum = 0
        for k in c..<min(c + inf.split + 1, chunkStart.count) { sum += chunkSize(k) }
        return (total, sum)
    }

    func room(_ inf: TextureInfo) -> Int? {
        if let n = nextOffset[inf.offset], n > inf.offset { return n - inf.offset }
        guard let c = chunkContaining(inf.offset) else { return nil }
        var sum = 0
        for k in c..<min(c + inf.split + 1, chunkStart.count) { sum += chunkSize(k) }
        return sum
    }

    func layoutOf(_ inf: TextureInfo, _ layout: TextureLayout) -> (ranges: [(start: Int, size: Int, ew: Int, eh: Int)], total: Int) {
        var count = inf.mipCount
        var result = layoutOf(inf, layout, levels: count)
        if let r = room(inf) {
            while count > 1 && result.total > r {
                count -= 1
                result = layoutOf(inf, layout, levels: count)
            }
        }
        return result
    }

    func layoutOf(_ inf: TextureInfo, _ layout: TextureLayout, levels: Int) -> (ranges: [(start: Int, size: Int, ew: Int, eh: Int)], total: Int) {
        var ranges: [(start: Int, size: Int, ew: Int, eh: Int)] = []
        var end = 0
        var w = inf.width, h = inf.height
        var tail: Int?
        var tailIndex = 0
        for _ in 0..<levels {
            let ew = (w + inf.blockSize - 1) / inf.blockSize, eh = (h + inf.blockSize - 1) / inf.blockSize
            let slot = layout.slotBytes(ew, eh)
            if layout.macro && (slot < 0x10000 || tail != nil) {
                if tail == nil {
                    tail = end - 0x10000
                    end = tail!
                }
                ranges.append((tail! + (0x8000 >> tailIndex), slot, ew, eh))
                tailIndex += 1
            } else if layout.mode == 3 && (slot < 0x1000 || tail != nil) {
                if tail == nil {
                    tail = end - 0x1000
                    end = tail!
                }
                ranges.append((tail! + 0x400 + (0x400 >> tailIndex), slot, ew, eh))
                tailIndex += 1
            } else {
                let a = min(slot, layout.macro ? 0x10000 : 4096)
                let start = -((-end + slot + a - 1) / a * a)
                ranges.append((start, slot, ew, eh))
                end = start
            }
            w = max(1, w / 2)
            h = max(1, h / 2)
        }
        return (ranges, (-end + 4095) / 4096 * 4096)
    }

    public func layoutDescription(_ i: Int) -> String {
        let inf = info(i)
        guard let eb = inf.elementBytes else { return "unsupported" }
        let l = layoutOf(inf, TextureLayout(elementBytes: eb, mode: Int(inf.flags >> 8) & 3, bits: TextureDB.tileBits(eb, Int(inf.flags >> 8) & 3)))
        return String(format: "room 0x%x total 0x%x levels ", room(inf) ?? -1, l.total) + l.ranges.map { String(format: "%dx%d@-0x%x+0x%x", $0.ew, $0.eh, -$0.start, $0.size) }.joined(separator: " ")
    }

    public func image(_ i: Int) throws -> TextureImage {
        let inf = info(i)
        guard let eb = inf.elementBytes else { throw RPFError.format("unsupported texture format \(inf.format)") }
        let layout = TextureLayout(elementBytes: eb, mode: Int(inf.flags >> 8) & 3, bits: TextureDB.tileBits(eb, Int(inf.flags >> 8) & 3))
        let (ranges, extent) = layoutOf(inf, layout)
        let total = (max(extent, room(inf) ?? extent) + 4095) / 4096 * 4096
        let base = inf.offset
        var data = [UInt8](repeating: 0, count: total)
        var have = [Bool](repeating: false, count: total / 4096)
        guard var c = chunkContaining(base) else { throw RPFError.format("texture data not found") }
        while c < chunkStart.count, chunkStart[c] < base + total {
            let cs = chunkStart[c], size = chunkSize(c)
            if let bytes = try chunk(c) {
                let lo = max(cs, base), hi = min(cs + min(size, bytes.count), base + total)
                if hi > lo {
                    data.withUnsafeMutableBytes { d in bytes.withUnsafeBytes { b in
                        d.baseAddress!.advanced(by: lo - base).copyMemory(from: b.baseAddress!.advanced(by: lo - cs), byteCount: hi - lo)
                    } }
                    for pg in ((lo - base) / 4096)..<((hi - base + 4095) / 4096) { have[pg] = true }
                }
            }
            c += 1
        }
        if let dump = ProcessInfo.processInfo.environment["MV_TEXRAW"] { try? Data(data).write(to: URL(fileURLWithPath: dump)) }
        func available(_ r: (start: Int, size: Int, ew: Int, eh: Int)) -> Bool {
            let lo = total + r.start, hi = lo + r.size
            return (lo / 4096..<(hi + 4095) / 4096).allSatisfy { $0 < have.count && have[$0] }
        }
        guard let first = ranges.indices.first(where: { available(ranges[$0]) }) else { throw RPFError.format("texture data not decodable") }
        var mips: [[UInt8]] = []
        for k in first..<ranges.count {
            let r = ranges[k]
            guard available(r) else { break }
            mips.append(layout.linear(data, base: total + r.start, r.ew, r.eh))
        }
        var out = inf
        out.width = max(1, inf.width >> first)
        out.height = max(1, inf.height >> first)
        return TextureImage(info: out, mips: mips, firstLevel: first)
    }
}

extension TextureDB {
    static func tileBits(_ eb: Int, _ mode: Int) -> String? {
        if eb == 16 && mode != 0 { return "yyxxyxyx" }
        if eb == 4 && mode == 0 { return "xxyyxyyxyx" }
        return nil
    }
}

public struct TextureLayout: Sendable {
    public let elementBytes: Int
    public let tileW: Int
    public let tileH: Int
    public let pattern: [Bool]
    public let macro: Bool
    public let mode: Int

    public init(elementBytes eb: Int, mode: Int = 2, bits: String? = nil) {
        elementBytes = eb
        self.mode = mode
        macro = mode == 0
        let block: String
        switch eb {
        case 16: block = "xyxy"
        case 8: block = "xyyxx"
        case 4: block = "xxyyyx"
        case 2: block = "xxxyyyx"
        default: block = "xxxxyyyy"
        }
        pattern = (bits ?? (block + "yxyx")).map { $0 == "x" }
        tileW = 1 << pattern.filter { $0 }.count
        tileH = 1 << pattern.filter { !$0 }.count
    }

    public func tiled(_ ew: Int, _ eh: Int) -> Bool { ew > tileW || eh > tileH }

    public func slotBytes(_ ew: Int, _ eh: Int) -> Int {
        if tiled(ew, eh) {
            return ((ew + tileW - 1) / tileW) * ((eh + tileH - 1) / tileH) * 4096
        }
        var top = 0, xb = 0, yb = 0
        for (bit, isX) in pattern.enumerated() {
            if isX { if ew > 1 << xb { top = bit + 1 }; xb += 1 } else { if eh > 1 << yb { top = bit + 1 }; yb += 1 }
        }
        return max(256, (1 << top) * elementBytes)
    }

    @inline(__always) func inTile(_ x: Int, _ y: Int) -> Int {
        var idx = 0, xb = 0, yb = 0
        for (bit, isX) in pattern.enumerated() {
            if isX { idx |= ((x >> xb) & 1) << bit; xb += 1 } else { idx |= ((y >> yb) & 1) << bit; yb += 1 }
        }
        return idx
    }

    public func linear(_ src: [UInt8], base: Int, _ ew: Int, _ eh: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: ew * eh * elementBytes)
        let tilesX = (ew + tileW - 1) / tileW
        let tilesY = (eh + tileH - 1) / tileH
        let tiledLayout = tiled(ew, eh)
        let macroLayout = macro && tilesX % 4 == 0 && tilesY % 4 == 0
        let smallMacro = macro && !macroLayout && tilesX <= 4 && tilesY <= 4
        func compact(_ lx: Int, _ ly: Int) -> Int {
            var idx = 0, bit = 0
            for k in 0..<2 {
                if tilesY > 1 << k { idx |= ((ly >> k) & 1) << bit; bit += 1 }
                if tilesX > 1 << k { idx |= ((lx >> k) & 1) << bit; bit += 1 }
            }
            return idx
        }
        src.withUnsafeBytes { s in
            out.withUnsafeMutableBytes { d in
                for y in 0..<eh {
                    for x in 0..<ew {
                        let e: Int
                        if tiledLayout {
                            let tx = x / tileW, ty = y / tileH
                            let t: Int
                            if macroLayout {
                                let lx = tx & 3, ly = ty & 3
                                t = ((ty >> 2) * (tilesX >> 2) + (tx >> 2)) * 16 + ((ly & 1) | (lx & 1) << 1 | (ly >> 1) << 2 | (lx >> 1) << 3)
                            } else if smallMacro {
                                t = compact(tx, ty)
                            } else {
                                t = ty * tilesX + tx
                            }
                            e = t * (4096 / elementBytes) + inTile(x % tileW, y % tileH)
                        } else {
                            e = inTile(x, y)
                        }
                        let so = base + e * elementBytes
                        guard so + elementBytes <= s.count else { continue }
                        let dst = (y * ew + x) * elementBytes
                        for k in 0..<elementBytes { d[dst + k] = s[so + k] }
                    }
                }
            }
        }
        return out
    }
}

public final class TextureDB: @unchecked Sendable {
    public let files: [TTDBFile]
    var lookup: [UInt64: (Int32, Int32)] = [:]
    public private(set) var aliases: [UInt64: UInt64] = [:]

    public static func loadAliases(archive: String, index: String) -> [UInt64: UInt64] {
        guard let f = try? MappedFile(path: archive), let idx = try? ArchiveIndex.read(from: index) else { return [:] }
        var out: [UInt64: UInt64] = [:]
        for (i, e) in idx.entries.enumerated() where e.kind == .zlib && e.head.count >= 8 && e.head[0] == 0x45 && e.head[1] == 0x44 && e.head[2] == 0x55 && e.head[3] == 0x50 {
            let n = Int(UInt32(e.head[4]) | UInt32(e.head[5]) << 8 | UInt32(e.head[6]) << 16 | UInt32(e.head[7]) << 24)
            let need = 8 + 16 * n
            var data: [UInt8] = []
            var k = i
            while data.count < need, k < idx.entries.count, idx.entries[k].kind == .zlib {
                guard let d = try? idx.load(idx.entries[k], from: f) else { break }
                data += d
                k += 1
            }
            guard data.count >= need else { continue }
            data.withUnsafeBytes { p in
                for j in 0..<n {
                    let key = p.loadUnaligned(fromByteOffset: 8 + 16 * j, as: UInt64.self)
                    let target = p.loadUnaligned(fromByteOffset: 16 + 16 * j, as: UInt64.self)
                    out[key] = target
                }
            }
        }
        return out
    }

    public init(roots: [String], aliasArchive: (String, String)? = nil) {
        var paths: [String] = []
        let fm = FileManager.default
        for root in roots {
            guard let en = fm.enumerator(atPath: root) else { continue }
            while let p = en.nextObject() as? String {
                if p.hasSuffix(".ttpf") { paths.append(root + "/" + p) }
            }
        }
        paths.sort()
        var fs: [TTDBFile] = []
        for p in paths { if let f = try? TTDBFile(path: p) { fs.append(f) } }
        files = fs
        for (fi, f) in fs.enumerated() {
            for (ti, h) in f.hashes.enumerated() where lookup[h] == nil { lookup[h] = (Int32(fi), Int32(ti)) }
        }
        if let (a, i) = aliasArchive { aliases = TextureDB.loadAliases(archive: a, index: i) }
    }

    public var count: Int { lookup.count }

    public func find(_ hash: UInt64) -> (file: TTDBFile, index: Int)? {
        if let (f, t) = lookup[hash] { return (files[Int(f)], Int(t)) }
        var h = hash
        for _ in 0..<4 {
            guard let next = aliases[h] else { return nil }
            if let (f, t) = lookup[next] { return (files[Int(f)], Int(t)) }
            h = next
        }
        return nil
    }
}
