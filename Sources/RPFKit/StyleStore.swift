import Foundation

public indirect enum PSOValue: Sendable {
    case number(Double)
    case hash(UInt32)
    case object(PSOObject)
    case array([PSOValue])
    case null
}

public struct PSOObject: Sendable {
    public var type: UInt32
    public var fields: [UInt32: PSOValue]

    public func value(_ name: String) -> PSOValue? { fields[atHash(name)] }

    public func number(_ name: String) -> Double? {
        if case .number(let d)? = value(name), d.isFinite, abs(d) < 1e30 { return d }
        return nil
    }

    public func hash(_ name: String) -> UInt32? {
        if case .hash(let h)? = value(name) { return h }
        return nil
    }

    public func object(_ name: String) -> PSOObject? {
        if case .object(let o)? = value(name) { return o }
        return nil
    }

    public var children: [PSOObject] {
        fields.values.compactMap { if case .object(let o) = $0 { return o }; return nil }
    }

    public func first(where test: (PSOObject) -> Bool) -> PSOObject? {
        if test(self) { return self }
        for v in fields.values {
            switch v {
            case .object(let o): if let f = o.first(where: test) { return f }
            case .array(let a):
                for case .object(let o) in a { if let f = o.first(where: test) { return f } }
            default: break
            }
        }
        return nil
    }
}

public final class StyleStore: @unchecked Sendable {
    static let rootType: UInt32 = 0x5D09_873F
    static let themesMember: UInt32 = 0x9ED4_821C
    static let stylesMember: UInt32 = 0x702E_FBD1
    static let setsMember: UInt32 = 0x6FA8_E478
    static let elementMember: UInt32 = 0x100

    let pso: PSOFile
    public private(set) var themes: [UInt32: [UInt32: [PSOObject]]] = [:]

    public init(pso: PSOFile) throws {
        self.pso = pso
        guard let rootBlock = pso.blocks.first(where: { $0.type == StyleStore.rootType }) else { throw RPFError.format("no style root in PSO") }
        let root = object(StyleStore.rootType, rootBlock.offset, depth: 0)
        guard case .array(let ts)? = root.fields[StyleStore.themesMember] else { throw RPFError.format("style themes missing") }
        for case .object(let theme) in ts {
            guard let id = theme.hash("ID"), case .array(let styles)? = theme.fields[StyleStore.stylesMember] else { continue }
            var map: [UInt32: [PSOObject]] = [:]
            for case .object(let style) in styles {
                guard let sid = style.hash("ID"), case .array(let sets)? = style.fields[StyleStore.setsMember] else { continue }
                var props: [PSOObject] = []
                for case .object(let set) in sets {
                    if case .array(let p)? = set.value("Properties") {
                        for case .object(let o) in p { props.append(o) }
                    }
                    break
                }
                map[sid] = props
            }
            themes[id] = map
        }
    }

    public static func find(index: ArchiveIndex, file: MappedFile) -> StyleStore? {
        let entries = index.entries
        for (i, e) in entries.enumerated() where e.kind == .zlib && e.magic == "PSIN" {
            guard var bytes = try? index.load(e, from: file) else { continue }
            var k = i + 1
            var last = bytes.count
            while last == 0x10000, k < entries.count, entries[k].kind == .zlib, let more = try? index.load(entries[k], from: file) {
                bytes += more
                last = more.count
                k += 1
            }
            guard let p = try? PSOFile(bytes: bytes), p.structs[StyleStore.rootType] != nil else { continue }
            if let s = try? StyleStore(pso: p) { return s }
        }
        return nil
    }

    public func style(_ name: String, theme: String = "DEFAULT_THEME") -> [PSOObject] {
        themes[Hash.joaat(theme)]?[Hash.joaat(name)] ?? []
    }

    public func layout(_ name: String) -> PSOObject? {
        for p in style(name) {
            if let l = p.first(where: { $0.fields[atHash("widthContentMode")] != nil }) { return l }
        }
        return nil
    }

    func u32(_ o: Int) -> UInt32 { pso.bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
    func u64(_ o: Int) -> UInt64 { pso.bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) } }

    func pointer(_ v: UInt64) -> (UInt32, Int)? {
        let bi = Int(v & 0xFFFFF) - 1
        guard v != 0, bi >= 0, bi < pso.blocks.count else { return nil }
        let b = pso.blocks[bi]
        return (b.type, b.offset + Int(v >> 20))
    }

    func object(_ type: UInt32, _ o: Int, depth: Int) -> PSOObject {
        var out = PSOObject(type: type, fields: [:])
        guard let st = pso.structs[type], depth < 48 else { return out }
        for (k, m) in st.members.enumerated() where m.name != StyleStore.elementMember {
            let element = k > 0 && st.members[k - 1].name == StyleStore.elementMember ? st.members[k - 1] : nil
            out.fields[m.name] = value(m.type, m.ref, o + m.offset, element: element, depth: depth)
        }
        return out
    }

    func elementSize(_ type: UInt32, _ ref: UInt32) -> Int {
        switch type & 0xFF {
        case 0x05: return pso.structs[ref]?.size ?? 0
        case 0x10, 0x11, 0x01, 0x60: return 1
        case 0x12, 0x13, 0x61: return 2
        case 0x14, 0x15, 0x21, 0x4A, 0x62, 0x64, 0x65: return 4
        case 0x30, 0x34: return 16
        default: return 8
        }
    }

    func value(_ type: UInt32, _ ref: UInt32, _ o: Int, element: PSOMember?, depth: Int) -> PSOValue {
        let b = pso.bytes
        guard o >= 0, o + 4 <= b.count else { return .null }
        switch type & 0xFF {
        case 0x21: return .number(Double(Float(bitPattern: u32(o))))
        case 0x10, 0x11, 0x01, 0x60: return .number(Double(b[o]))
        case 0x12, 0x13, 0x61: return .number(Double(UInt16(b[o]) | UInt16(b[o + 1]) << 8))
        case 0x14: return .number(Double(Int32(bitPattern: u32(o))))
        case 0x15, 0x62, 0x64, 0x65: return .number(Double(u32(o)))
        case 0x4A: return .hash(u32(o))
        case 0x05: return .object(object(ref, o, depth: depth + 1))
        case 0x07:
            guard let (t, p) = pointer(u64(o)) else { return .null }
            return .object(object(t, p, depth: depth + 1))
        case 0x52, 0x5C:
            let ptr: UInt64, count: Int
            if type & 0xFF == 0x52 {
                ptr = u64(o)
                count = Int(UInt16(b[o + 8]) | UInt16(b[o + 9]) << 8)
            } else {
                count = Int(u32(o))
                ptr = u64(o + 8)
            }
            guard let el = element, let (_, start) = pointer(ptr) else { return .array([]) }
            let size = elementSize(el.type, el.ref)
            guard size > 0 else { return .array([]) }
            return .array((0..<count).map { value(el.type, el.ref, start + $0 * size, element: nil, depth: depth + 1) })
        default:
            return .null
        }
    }
}
