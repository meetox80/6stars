import Foundation

public enum RBFValue: Sendable {
    case int(Int64)
    case bool(Bool)
    case double(Double)
    case vector(SIMD3<Double>)
    case string(String)
}

public final class RBFNode: @unchecked Sendable {
    public let name: String
    public var attributes: [String: RBFValue] = [:]
    public var children: [RBFNode] = []
    public var value: RBFValue?
    public var text: String?

    init(name: String) { self.name = name }

    public func child(_ n: String) -> RBFNode? { children.first { $0.name == n } }

    public func items(_ n: String) -> [RBFNode] { child(n)?.children.filter { $0.name == "Item" } ?? [] }

    public var type: String? {
        if case .string(let s)? = attributes["type"] { return s }
        return nil
    }

    public func string(_ n: String) -> String? { child(n)?.text }

    public func number(_ n: String) -> Double? {
        guard let c = child(n) else { return nil }
        switch c.value {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        default: return c.text.flatMap { Double($0) }
        }
    }

    public func flag(_ n: String) -> Bool? {
        if case .bool(let b)? = child(n)?.value { return b }
        return nil
    }

    public func find(name: String) -> RBFNode? {
        if string("Name") == name { return self }
        for c in children { if let f = c.find(name: name) { return f } }
        return nil
    }

    public var identifier: String? { string("Id") ?? string("ID") ?? string("Name") }
}

public enum RBF {
    public static func parse(_ b: [UInt8]) throws -> RBFNode {
        guard b.count >= 4, b[0] == 0x52, b[1] == 0x42, b[2] == 0x46, b[3] == 0x30 else { throw RPFError.format("not an RBF0 file") }
        var p = 4
        var names: [String] = []
        var stack: [RBFNode] = []
        var root: RBFNode?
        var current: RBFNode?
        var pending = 0
        func need(_ n: Int) throws { if p + n > b.count { throw RPFError.format("RBF truncated at 0x\(String(p, radix: 16))") } }
        func u16() throws -> Int { try need(2); defer { p += 2 }; return Int(b[p]) | Int(b[p + 1]) << 8 }
        func u32() throws -> Int { try need(4); defer { p += 4 }; return Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24 }
        func u64() throws -> UInt64 {
            try need(8)
            defer { p += 8 }
            return b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p, as: UInt64.self) }
        }
        func string(_ n: Int) throws -> String {
            try need(n)
            defer { p += n }
            var e = p + n
            while e > p && b[e - 1] == 0 { e -= 1 }
            return String(decoding: b[p..<e], as: UTF8.self)
        }
        while p < b.count {
            let d = b[p]
            p += 1
            if d == 0xFF {
                try need(1)
                p += 1
                if let s = stack.popLast() { current = s }
                continue
            }
            if d == 0xFD {
                try need(1)
                p += 1
                let n = try u32()
                current?.text = try string(n)
                continue
            }
            if d == 0xFB {
                try need(1)
                p += 1
                _ = try u16()
                continue
            }
            try need(1)
            let t = b[p]
            p += 1
            if Int(d) == names.count {
                let n = try u16()
                names.append(try string(n))
            } else if Int(d) > names.count {
                throw RPFError.format("RBF descriptor \(d) out of range")
            }
            let name = names[Int(d)]
            if t == 0 {
                try need(6)
                let attrs = Int(b[p + 4]) | Int(b[p + 5]) << 8
                p += 6
                let node = RBFNode(name: name)
                if let c = current {
                    c.children.append(node)
                    stack.append(c)
                } else {
                    root = node
                }
                current = node
                pending = attrs
                continue
            }
            let v: RBFValue
            switch t {
            case 0x10: v = .int(Int64(bitPattern: try u64()))
            case 0x20: v = .bool(true)
            case 0x30: v = .bool(false)
            case 0x40: v = .double(Double(bitPattern: try u64()))
            case 0x50:
                let x = Double(bitPattern: try u64()), y = Double(bitPattern: try u64()), z = Double(bitPattern: try u64())
                v = .vector(SIMD3(x, y, z))
            case 0x60: v = .string(try string(try u16()))
            default: throw RPFError.format("RBF value type 0x\(String(t, radix: 16))")
            }
            if pending > 0, let c = current {
                c.attributes[name] = v
                pending -= 1
            } else {
                let leaf = RBFNode(name: name)
                leaf.value = v
                current?.children.append(leaf)
            }
        }
        guard let r = root else { throw RPFError.format("empty RBF file") }
        return r
    }
}
