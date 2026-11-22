import Foundation

public struct PRD0Member: Sendable {
    public var name: UInt32
    public var offset: Int
    public var type: UInt8
    public var ref: UInt32
}

public struct PRD0Struct: Sendable {
    public var name: UInt32
    public var size: Int
    public var members: [PRD0Member]

    public func member(_ name: UInt32) -> (PRD0Member, PRD0Member?)? {
        for (i, m) in members.enumerated() where m.name == name {
            let elem = i > 0 && members[i - 1].name == 0x100 ? members[i - 1] : nil
            return (m, elem)
        }
        return nil
    }
}

public struct PRD0Block: Sendable {
    public var type: UInt32
    public var size: Int
    public var offset: Int
    public var physOffset: Int = -1
    public var physSize: Int = 0
}

public struct PRD0 {
    public let b: [UInt8]
    public var structs: [UInt32: PRD0Struct] = [:]
    public var blocks: [PRD0Block] = []

    public init(_ b: [UInt8]) throws {
        self.b = b
        guard b.count >= 0x50, b[0x10] == 0x30, b[0x11] == 0x44, b[0x12] == 0x52, b[0x13] == 0x50,
              let sc = Resource.vptr(b, 0x28), let bl = Resource.vptr(b, 0x38) else {
            throw RPFError.format("not a PRD0 resource")
        }
        let ns = Int(u16(0x48)), nb = Int(u16(0x4C))
        guard ns < 4096, nb < 65536, sc + 32 * ns <= b.count, bl + 16 * nb <= b.count else { throw RPFError.format("PRD0 tables out of range") }
        for i in 0..<ns {
            let o = sc + 32 * i
            let name = u32(o)
            let size = Int(u32(o + 24))
            let count = Int(u16(o + 30))
            var members: [PRD0Member] = []
            if let mp = Resource.vptr(b, o + 16), mp + 16 * count <= b.count {
                for k in 0..<count {
                    let mo = mp + 16 * k
                    members.append(PRD0Member(name: u32(mo), offset: Int(u32(mo + 4)), type: b[mo + 8], ref: u32(mo + 12)))
                }
            }
            structs[name] = PRD0Struct(name: name, size: size, members: members)
        }
        for i in 0..<nb {
            let o = bl + 16 * i
            if let p = Resource.vptr(b, o + 8), p + Int(u32(o + 4)) <= b.count {
                blocks.append(PRD0Block(type: u32(o), size: Int(u32(o + 4)), offset: p))
            } else if let pp = Resource.pptr(b, o + 8) {
                blocks.append(PRD0Block(type: u32(o), size: 0, offset: 0, physOffset: pp, physSize: Int(u32(o + 4))))
            } else {
                blocks.append(PRD0Block(type: u32(o), size: 0, offset: 0))
            }
        }
    }

    @inline(__always) public func u8(_ o: Int) -> UInt8 { b[o] }
    @inline(__always) public func u16(_ o: Int) -> UInt16 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) } }
    @inline(__always) public func u32(_ o: Int) -> UInt32 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
    @inline(__always) public func u64(_ o: Int) -> UInt64 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) } }
    @inline(__always) public func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }

    public func block(ofType t: UInt32) -> PRD0Block? { blocks.first { $0.type == t && $0.size > 0 } }

    public func array(at o: Int) -> (offset: Int, count: Int)? {
        guard o + 16 <= b.count else { return nil }
        let v = u64(o)
        let count = Int(u16(o + 8))
        let blk = Int(v & 0xFFFFF), off = Int(v >> 20)
        guard count > 0, blk >= 1, blk <= blocks.count, blocks[blk - 1].size > 0 else { return nil }
        let p = blocks[blk - 1].offset + off
        guard p <= b.count else { return nil }
        return (p, count)
    }
}
