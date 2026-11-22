import Foundation
import simd

public struct GFXMatrix: Sendable {
    public var a: Float = 1, b: Float = 0, c: Float = 0, d: Float = 1, tx: Float = 0, ty: Float = 0

    public init() {}

    public init(a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public func apply(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty) }

    public static func * (l: GFXMatrix, r: GFXMatrix) -> GFXMatrix {
        GFXMatrix(a: l.a * r.a + l.c * r.b, b: l.b * r.a + l.d * r.b, c: l.a * r.c + l.c * r.d, d: l.b * r.c + l.d * r.d,
                  tx: l.a * r.tx + l.c * r.ty + l.tx, ty: l.b * r.tx + l.d * r.ty + l.ty)
    }
}

public struct GFXEdge: Sendable {
    public var from: SIMD2<Float>
    public var control: SIMD2<Float>?
    public var to: SIMD2<Float>
}

public struct GFXFill: Sendable {
    public var color: SIMD4<Float>
    public var contours: [[GFXEdge]]
}

public struct GFXShape: Sendable {
    public var bounds: (SIMD2<Float>, SIMD2<Float>)
    public var fills: [GFXFill]
}

public struct GFXPlacement: Sendable {
    public var depth: Int
    public var character: Int
    public var matrix: GFXMatrix
}

public final class GFXMovie: @unchecked Sendable {
    public let name: String
    public let frame: (SIMD2<Float>, SIMD2<Float>)
    public private(set) var shapes: [Int: GFXShape] = [:]
    public private(set) var sprites: [Int: [GFXPlacement]] = [:]
    public private(set) var exports: [String: Int] = [:]

    struct Bits {
        let b: [UInt8]
        var p: Int
        init(_ b: [UInt8], _ byte: Int) { self.b = b; p = byte * 8 }
        mutating func u(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                let byte = p >> 3
                let bit = byte < b.count ? (Int(b[byte]) >> (7 - (p & 7))) & 1 : 0
                v = (v << 1) | bit
                p += 1
            }
            return v
        }
        mutating func s(_ n: Int) -> Int {
            guard n > 0 else { return 0 }
            let v = u(n)
            return v & (1 << (n - 1)) != 0 ? v - (1 << n) : v
        }
        mutating func fixed(_ n: Int) -> Float { Float(s(n)) / 65536 }
        mutating func align() { p = (p + 7) & ~7 }
        var byte: Int { (p + 7) >> 3 }
    }

    public init(bytes b: [UInt8]) throws {
        guard b.count > 16, b[0] == 0x47, b[1] == 0x46, b[2] == 0x58 else { throw RPFError.format("not a GFX movie") }
        var bits = Bits(b, 8)
        let nb = bits.u(5)
        let r = (0..<4).map { _ in Float(bits.s(nb)) / 20 }
        frame = (SIMD2(r[0], r[2]), SIMD2(r[1], r[3]))
        var p = bits.byte + 4
        var movieName = ""
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var tags: [(Int, Int, Int)] = []
        while p + 2 <= b.count {
            let cl = u16(p)
            p += 2
            var len = cl & 0x3F
            if len == 0x3F {
                guard p + 4 <= b.count else { break }
                len = u32(p)
                p += 4
            }
            let code = cl >> 6
            guard p + len <= b.count else { break }
            tags.append((code, p, len))
            p += len
            if code == 0 { break }
        }
        for (code, start, len) in tags {
            switch code {
            case 1000:
                if len > 10 {
                    let n = Int(b[start + 9])
                    if start + 10 + n <= b.count { movieName = String(decoding: b[(start + 10)..<(start + 10 + n)], as: UTF8.self) }
                }
            case 2, 22, 32, 83:
                if let s = GFXMovie.shape(b, start, len, version: code == 2 ? 1 : code == 22 ? 2 : code == 32 ? 3 : 4) {
                    shapes[u16(start)] = s
                }
            case 39:
                sprites[u16(start)] = GFXMovie.placements(b, start + 4, start + len)
            case 56:
                let n = u16(start)
                var q = start + 2
                for _ in 0..<n {
                    guard q + 2 < start + len else { break }
                    let id = u16(q)
                    var e = q + 2
                    while e < start + len && b[e] != 0 { e += 1 }
                    exports[String(decoding: b[(q + 2)..<e], as: UTF8.self)] = id
                    q = e + 1
                }
            default: break
            }
        }
        name = movieName
    }

    public static func name(of b: [UInt8]) -> String? {
        guard b.count > 16, b[0] == 0x47, b[1] == 0x46, b[2] == 0x58 else { return nil }
        var bits = Bits(b, 8)
        let nb = bits.u(5)
        bits.p += 4 * nb
        var p = bits.byte + 4
        for _ in 0..<8 {
            guard p + 2 <= b.count else { return nil }
            let cl = Int(b[p]) | Int(b[p + 1]) << 8
            p += 2
            var len = cl & 0x3F
            if len == 0x3F {
                guard p + 4 <= b.count else { return nil }
                len = Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24
                p += 4
            }
            if cl >> 6 == 1000, len > 10, p + 10 + Int(b[p + 9]) <= b.count {
                return String(decoding: b[(p + 10)..<(p + 10 + Int(b[p + 9]))], as: UTF8.self)
            }
            p += len
        }
        return nil
    }

    static func matrix(_ bits: inout Bits) -> GFXMatrix {
        var m = GFXMatrix()
        if bits.u(1) == 1 {
            let n = bits.u(5)
            m.a = bits.fixed(n)
            m.d = bits.fixed(n)
        }
        if bits.u(1) == 1 {
            let n = bits.u(5)
            m.b = bits.fixed(n)
            m.c = bits.fixed(n)
        }
        let n = bits.u(5)
        m.tx = Float(bits.s(n)) / 20
        m.ty = Float(bits.s(n)) / 20
        bits.align()
        return m
    }

    static func placements(_ b: [UInt8], _ start: Int, _ end: Int) -> [GFXPlacement] {
        var out: [Int: GFXPlacement] = [:]
        var p = start
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        while p + 2 <= end {
            let cl = u16(p)
            p += 2
            var len = cl & 0x3F
            if len == 0x3F { len = u16(p) | u16(p + 2) << 16; p += 4 }
            let code = cl >> 6
            if code == 1 || code == 0 { break }
            if code == 26 || code == 70 {
                let flags = Int(b[p])
                var q = p + (code == 70 ? 2 : 1)
                let depth = u16(q)
                q += 2
                if code == 70 && b[p + 1] & 0x08 != 0 {
                    while q < p + len && b[q] != 0 { q += 1 }
                    q += 1
                }
                var place = out[depth] ?? GFXPlacement(depth: depth, character: -1, matrix: GFXMatrix())
                if flags & 0x02 != 0 { place.character = u16(q); q += 2 }
                if flags & 0x04 != 0 {
                    var bits = Bits(b, q)
                    place.matrix = matrix(&bits)
                }
                out[depth] = place
            }
            p += len
        }
        return out.values.sorted { $0.depth < $1.depth }.filter { $0.character >= 0 }
    }

    static func shape(_ b: [UInt8], _ start: Int, _ len: Int, version: Int) -> GFXShape? {
        var bits = Bits(b, start + 2)
        func rect() -> (SIMD2<Float>, SIMD2<Float>) {
            let n = bits.u(5)
            let r = (0..<4).map { _ in Float(bits.s(n)) / 20 }
            bits.align()
            return (SIMD2(r[0], r[2]), SIMD2(r[1], r[3]))
        }
        let bounds = rect()
        if version == 4 {
            _ = rect()
            bits.p += 8
        }
        func color() -> SIMD4<Float> {
            let r = Float(bits.u(8)), g = Float(bits.u(8)), bl = Float(bits.u(8))
            let a = version >= 3 ? Float(bits.u(8)) : 255
            return SIMD4(r, g, bl, a) / 255
        }
        func gradient() -> SIMD4<Float> {
            _ = matrix(&bits)
            _ = bits.u(4)
            let n = bits.u(4)
            var sum = SIMD4<Float>(repeating: 0)
            for _ in 0..<n {
                _ = bits.u(8)
                sum += color()
            }
            return n > 0 ? sum / Float(n) : SIMD4(1, 1, 1, 1)
        }
        func fillStyles() -> [SIMD4<Float>] {
            var n = bits.u(8)
            if n == 0xFF && version >= 2 { n = bits.u(8) | bits.u(8) << 8 }
            var out: [SIMD4<Float>] = []
            for _ in 0..<n {
                let t = bits.u(8)
                switch t {
                case 0x00: out.append(color())
                case 0x10, 0x12: out.append(gradient())
                case 0x13:
                    let c = gradient()
                    _ = bits.u(16)
                    out.append(c)
                case 0x40...0x43:
                    _ = bits.u(16)
                    _ = matrix(&bits)
                    out.append(SIMD4(1, 1, 1, 1))
                default: return out
                }
            }
            return out
        }
        func lineStyles() {
            var n = bits.u(8)
            if n == 0xFF { n = bits.u(8) | bits.u(8) << 8 }
            for _ in 0..<n {
                _ = bits.u(16)
                if version == 4 {
                    _ = bits.u(2)
                    let join = bits.u(2)
                    let hasFill = bits.u(1)
                    _ = bits.u(11)
                    if join == 2 { _ = bits.u(16) }
                    if hasFill == 1 { _ = fillStyles() } else { _ = color() }
                } else {
                    _ = color()
                }
            }
        }
        var styles = fillStyles()
        lineStyles()
        var fillBits = bits.u(4), lineBits = bits.u(4)
        var edges: [Int: [GFXEdge]] = [:]
        var base = 0
        var allStyles = styles
        var pen = SIMD2<Float>(0, 0)
        var f0 = 0, f1 = 0
        let end = (start + len) * 8
        func add(_ e: GFXEdge) {
            if f1 > 0 { edges[base + f1, default: []].append(e) }
            if f0 > 0 { edges[base + f0, default: []].append(GFXEdge(from: e.to, control: e.control, to: e.from)) }
        }
        while bits.p < end {
            if bits.u(1) == 0 {
                let flags = bits.u(5)
                if flags == 0 { break }
                if flags & 0x01 != 0 {
                    let n = bits.u(5)
                    pen = SIMD2(Float(bits.s(n)), Float(bits.s(n))) / 20
                }
                if flags & 0x02 != 0 { f0 = bits.u(fillBits) }
                if flags & 0x04 != 0 { f1 = bits.u(fillBits) }
                if flags & 0x08 != 0 { _ = bits.u(lineBits) }
                if flags & 0x10 != 0 {
                    bits.align()
                    base = allStyles.count
                    styles = fillStyles()
                    allStyles += styles
                    lineStyles()
                    fillBits = bits.u(4)
                    lineBits = bits.u(4)
                }
            } else if bits.u(1) == 1 {
                let n = bits.u(4) + 2
                var d = SIMD2<Float>(0, 0)
                if bits.u(1) == 1 {
                    d = SIMD2(Float(bits.s(n)), Float(bits.s(n)))
                } else if bits.u(1) == 1 {
                    d.y = Float(bits.s(n))
                } else {
                    d.x = Float(bits.s(n))
                }
                let to = pen + d / 20
                add(GFXEdge(from: pen, control: nil, to: to))
                pen = to
            } else {
                let n = bits.u(4) + 2
                let c = pen + SIMD2(Float(bits.s(n)), Float(bits.s(n))) / 20
                let to = c + SIMD2(Float(bits.s(n)), Float(bits.s(n))) / 20
                add(GFXEdge(from: pen, control: c, to: to))
                pen = to
            }
        }
        var fills: [GFXFill] = []
        for k in edges.keys.sorted() {
            guard k - 1 < allStyles.count, var pool = edges[k] else { continue }
            var contours: [[GFXEdge]] = []
            while !pool.isEmpty {
                var loop = [pool.removeFirst()]
                while simd_distance(loop.last!.to, loop[0].from) > 0.001,
                      let i = pool.firstIndex(where: { simd_distance($0.from, loop.last!.to) < 0.001 }) {
                    loop.append(pool.remove(at: i))
                }
                contours.append(loop)
            }
            fills.append(GFXFill(color: allStyles[k - 1], contours: contours))
        }
        return GFXShape(bounds: bounds, fills: fills)
    }

    public func flatten(_ id: Int, _ m: GFXMatrix = GFXMatrix(), depth: Int = 0) -> [(GFXFill, GFXMatrix)] {
        if let s = shapes[id] { return s.fills.map { ($0, m) } }
        guard depth < 16, let list = sprites[id] else { return [] }
        return list.flatMap { flatten($0.character, m * $0.matrix, depth: depth + 1) }
    }
}
