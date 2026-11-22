import Foundation

public struct TextureDictionary: Sendable {
    public struct Entry: Sendable {
        public var name: String
        public var hash: UInt32
        public var info: TextureInfo
        public var data: Int
        public var levelBytes: Int
    }

    public let entries: [Entry]
    let physical: [UInt8]
    let footprints: [Int]
    var byHash: [UInt32: Int] = [:]

    public init(_ r: Resource) throws {
        let v = r.virtual
        guard v.count >= 0x40, let ha = Resource.vptr(v, 0x20), let ta = Resource.vptr(v, 0x30) else { throw RPFError.format("not a texture dictionary") }
        let n = Int(UInt16(v[0x28]) | UInt16(v[0x29]) << 8)
        guard n > 0, ha + 4 * n <= v.count, ta + 8 * n <= v.count else { throw RPFError.format("texture dictionary tables out of range") }
        func u16(_ o: Int) -> Int { Int(v[o]) | Int(v[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { v.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        var out: [Entry] = []
        for i in 0..<n {
            guard let t = Resource.vptr(v, ta + 8 * i), t + 0x48 <= v.count, let data = Resource.pptr(v, t + 0x18) else { continue }
            var name = ""
            if let np = Resource.vptr(v, t + 0x30) {
                var s = np
                while s < v.count && v[s] == 0 && s < np + 8 { s += 1 }
                var e = s
                while e < v.count && v[e] != 0 { e += 1 }
                name = String(decoding: v[s..<e], as: UTF8.self)
            }
            let info = TextureInfo(width: u16(t + 0x38), height: u16(t + 0x3A), format: Int(v[t + 0x3F]), split: 0, offset: data,
                                   flags: UInt16(u16(t + 0x10)), hint: 0)
            out.append(Entry(name: name, hash: u32(ha + 4 * i), info: info, data: data, levelBytes: Int(u32(t + 0x08)) * 16))
        }
        entries = out
        physical = r.physical
        let starts = Array(Set(out.map { $0.data })).sorted()
        var next: [Int: Int] = [:]
        for (k, s) in starts.enumerated() { next[s] = k + 1 < starts.count ? starts[k + 1] : r.physical.count }
        footprints = out.map { next[$0.data]! - $0.data }
        for (i, e) in out.enumerated() where byHash[e.hash] == nil { byHash[e.hash] = i }
    }

    public func index(named name: String) -> Int? { byHash[Hash.joaat(name)] }

    public func image(_ i: Int) throws -> TextureImage {
        let e = entries[i]
        guard let eb = e.info.elementBytes else { throw RPFError.format("unsupported texture format \(e.info.format)") }
        let layout = TextureLayout(elementBytes: eb, mode: Int(e.info.flags >> 8) & 3, bits: eb == 16 ? "yyxxyxyx" : nil)
        let end = min(physical.count, e.data + footprints[i])
        var mips: [[UInt8]] = []
        var w = e.info.width, h = e.info.height
        var off = e.data
        for _ in 0..<e.info.mipCount {
            let bs = e.info.blockSize
            let ew = (w + bs - 1) / bs, eh = (h + bs - 1) / bs
            let slot = layout.slotBytes(ew, eh)
            guard off + slot <= end else { break }
            mips.append(layout.linear(physical, base: off, ew, eh))
            off += (slot + 4095) / 4096 * 4096
            w = max(1, w / 2)
            h = max(1, h / 2)
        }
        guard !mips.isEmpty else { throw RPFError.format("texture data out of range") }
        return TextureImage(info: e.info, mips: mips, firstLevel: 0)
    }
}
