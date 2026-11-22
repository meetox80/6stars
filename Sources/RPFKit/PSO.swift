import Foundation
import simd

public func atHash(_ s: String) -> UInt32 {
    var h: UInt32 = 0
    for c in s.utf8 {
        h = h &+ UInt32(c)
        h = h &+ (h << 10)
        h ^= h >> 6
    }
    h = h &+ (h << 3)
    h ^= h >> 11
    h = h &+ (h << 15)
    return h
}

public struct PSOMember: Sendable {
    public var name: UInt32
    public var offset: Int
    public var type: UInt32
    public var ref: UInt32
}

public struct PSOStruct: Sendable {
    public var name: UInt32
    public var type: UInt8
    public var size: Int
    public var members: [PSOMember]

    public func member(_ hash: UInt32) -> PSOMember? { members.first { $0.name == hash } }
}

public struct PSOBlock: Sendable {
    public var type: UInt32
    public var offset: Int
    public var size: Int
}

public struct Placement: Sendable {
    public var position: SIMD3<Float>
    public var kind: UInt32
}

public struct PSOFile {
    public static let positionHash = atHash("Position")
    static let wrapperType: UInt8 = 0x0C
    static let structMemberType: UInt32 = 0x05

    public let bytes: [UInt8]
    public private(set) var structs: [UInt32: PSOStruct] = [:]
    public private(set) var blocks: [PSOBlock] = []

    public init(bytes: [UInt8]) throws {
        self.bytes = bytes
        var sections: [String: (Int, Int)] = [:]
        var o = 0
        while o + 8 <= bytes.count {
            let tag = bytes[o..<(o + 4)]
            guard tag.allSatisfy({ $0 >= 0x41 && $0 <= 0x5A }) else { break }
            let n = Int(UInt32(bytes[o + 4]) << 24 | UInt32(bytes[o + 5]) << 16 | UInt32(bytes[o + 6]) << 8 | UInt32(bytes[o + 7]))
            guard n >= 8, o + n <= bytes.count else { break }
            sections[String(decoding: tag, as: UTF8.self)] = (o + 8, n - 8)
            o += n
        }
        guard let psin = sections["PSIN"], let lsch = sections["LSCH"] else { throw RPFError.format("missing PSIN or LSCH section") }
        try parseSchema(lsch.0, lsch.0 + lsch.1)
        parseBlocks(psin.0, psin.0 + psin.1)
    }

    func u32(_ o: Int) -> UInt32 {
        bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
    }

    func isPad(_ o: Int) -> Bool {
        guard o + 8 <= bytes.count else { return false }
        for i in 0..<8 where bytes[o + i] != 0xAA { return false }
        return true
    }

    mutating func parseSchema(_ start: Int, _ end: Int) throws {
        var p = start
        var order: [(UInt32, UInt8, Int, Int)] = []
        while p + 32 <= end && isPad(p + 16) {
            let count = Int(UInt16(bytes[p + 30]) | UInt16(bytes[p + 31]) << 8)
            order.append((u32(p), bytes[p + 8], Int(u32(p + 24)), count))
            p += 32
        }
        for (name, type, size, count) in order {
            var members: [PSOMember] = []
            for _ in 0..<count {
                guard p + 16 <= end else { throw RPFError.format("schema truncated") }
                members.append(PSOMember(name: u32(p), offset: Int(u32(p + 4)), type: u32(p + 8), ref: u32(p + 12)))
                p += 16
            }
            structs[name] = PSOStruct(name: name, type: type, size: size, members: members)
        }
    }

    mutating func parseBlocks(_ start: Int, _ end: Int) {
        var p = start
        var recs: [(UInt32, Int)] = []
        while p + 16 <= end && isPad(p + 8) {
            recs.append((u32(p), Int(u32(p + 4))))
            p += 16
        }
        for (t, size) in recs {
            p = (p + 15) & ~15
            if p + size > end { break }
            blocks.append(PSOBlock(type: t, offset: p, size: size))
            p += size
        }
    }

    public func placements() -> [Placement] {
        var out: [Placement] = []
        for b in blocks {
            guard let outer = structs[b.type], outer.size > 0 else { continue }
            var base = 0
            var inner = outer
            if outer.type == Self.wrapperType {
                guard let m = outer.members.first(where: { $0.type == Self.structMemberType }), let s = structs[m.ref] else { continue }
                base = m.offset
                inner = s
            }
            guard let pos = inner.member(Self.positionHash) else { continue }
            let count = b.size / outer.size
            bytes.withUnsafeBytes { raw in
                for i in 0..<count {
                    let o = b.offset + i * outer.size + base + pos.offset
                    guard o + 12 <= raw.count else { return }
                    let v = SIMD3<Float>(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                         raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                         raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
                    if v.x.isFinite && v.y.isFinite && v.z.isFinite && simd_length(v) < 1e5 {
                        out.append(Placement(position: v, kind: inner.name))
                    }
                }
            }
        }
        return out
    }
}

public enum WorldLoader {
    public static func placements(index: ArchiveIndex, file: MappedFile) -> [Placement] {
        let pso = index.entries.filter { $0.kind == .zlib && $0.magic == "PSIN" }
        let slots = UnsafeMutableBufferPointer<[Placement]>.allocate(capacity: pso.count)
        slots.initialize(repeating: [])
        defer { slots.deallocate() }
        DispatchQueue.concurrentPerform(iterations: pso.count) { i in
            guard let data = try? index.load(pso[i], from: file), let f = try? PSOFile(bytes: data) else { return }
            slots[i] = f.placements()
        }
        return Array(slots.joined())
    }
}
