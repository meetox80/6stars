import Foundation
import simd

public struct CatalogEntry: Sendable {
    public var hash: UInt32
    public var base: UInt32
    public var resource: UInt64
    public var boundsMin: SIMD3<Float>
    public var boundsMax: SIMD3<Float>
    public var radius: Float
    public var lodClass: UInt8
    public var name: String
    public var source: UInt8 = 0

    public var center: SIMD3<Float> { (boundsMin + boundsMax) / 2 }
}

public enum LodClass {
    public static let hd: UInt8 = 0
    public static let lod: UInt8 = 1
    public static let slod: UInt8 = 2
    public static let hidden: UInt8 = 3

    public static func of(_ name: String) -> UInt8 {
        let n = name.lowercased()
        if n.contains("occl") && !n.contains("cable") { return hidden }
        if n.contains("slod") { return slod }
        if n.contains("_lod") || n.hasSuffix("lod") { return lod }
        return hd
    }
}

public final class Catalog {
    public private(set) var entries: [CatalogEntry] = []
    public private(set) var byHash: [UInt32: Int] = [:]

    public init(entries: [CatalogEntry]) {
        self.entries = entries
        for (i, e) in entries.enumerated() where byHash[e.hash] == nil { byHash[e.hash] = i }
    }

    public func adding(_ other: Catalog, source: UInt8) -> Catalog {
        var merged = entries
        for var e in other.entries where byHash[e.hash] == nil {
            e.source = source
            merged.append(e)
        }
        return Catalog(entries: merged)
    }

    static func name(_ v: ByteView, _ o: Int) -> String? {
        guard let np = v.vptr(o), v.has(np, 1) else { return nil }
        var end = np
        while end < v.p.count, end - np < 160, v.u8(end) != 0 { end += 1 }
        guard end > np, end < v.p.count, v.u8(end) == 0 else { return nil }
        let bytes = Array(v.p[np..<end])
        guard bytes.allSatisfy({ $0 > 32 && $0 < 127 }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    static let fragmentDrawable = 0x18

    static func entry(_ v: ByteView, base: Int, resource: UInt64, hash: UInt32?, suffix: String? = nil) -> CatalogEntry? {
        guard v.has(base, 0xB0), v.vptr(base + 0x50) != nil || v.vptr(base + 0x58) != nil, let full = name(v, base + 0xA8) else { return nil }
        if let suffix = suffix, !full.hasSuffix(suffix) { return nil }
        let stem = String(full.split(separator: ".", maxSplits: 1).first ?? Substring(full))
        let mn = SIMD3(v.f32(base + 0x30), v.f32(base + 0x34), v.f32(base + 0x38))
        let mx = SIMD3(v.f32(base + 0x40), v.f32(base + 0x44), v.f32(base + 0x48))
        guard mn.x.isFinite, mx.x.isFinite, mn.y.isFinite, mx.y.isFinite, mn.z.isFinite, mx.z.isFinite else { return nil }
        return CatalogEntry(hash: hash ?? Hash.joaat(stem), base: UInt32(base), resource: resource, boundsMin: mn, boundsMax: mx,
                            radius: max(simd_length(mx - mn) / 2, 0.01), lodClass: LodClass.of(stem), name: stem)
    }

    static func scan(_ b: [UInt8], resource: UInt64) -> [CatalogEntry] {
        b.withUnsafeBytes { p in
            let v = ByteView(p: p)
            if let e = entry(v, base: 0, resource: resource, hash: nil) { return [e] }
            if let d = v.vptr(fragmentDrawable), d > 0, let e = entry(v, base: d, resource: resource, hash: nil, suffix: ".#ft") { return [e] }
            guard v.has(0, 0x40), let hp = v.vptr(0x20), let vp = v.vptr(0x30) else { return [] }
            let n = Int(v.u16(0x28))
            guard n > 0, n == Int(v.u16(0x38)), v.has(hp, 4 * n), v.has(vp, 8 * n) else { return [] }
            var out: [CatalogEntry] = []
            for i in 0..<n {
                guard let d = v.vptr(vp + 8 * i), let e = entry(v, base: d, resource: resource, hash: v.u32(hp + 4 * i)) else { continue }
                out.append(e)
            }
            return out
        }
    }

    public static func build(index: ArchiveIndex, file: MappedFile, progress: ((Int, Int) -> Void)? = nil) -> Catalog {
        let candidates = index.resourceStarts
        let lock = NSLock()
        var found: [CatalogEntry] = []
        var done = 0
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let off = candidates[i]
            var local: [CatalogEntry] = []
            if let seg = try? index.virtualSegment(at: off, from: file) { local = scan(seg.data, resource: off) }
            lock.lock()
            found += local
            done += 1
            if done % 20000 == 0 { progress?(done, candidates.count) }
            lock.unlock()
        }
        found.sort { $0.resource != $1.resource ? $0.resource < $1.resource : $0.base < $1.base }
        return Catalog(entries: found)
    }

    public func write(to path: String) throws {
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(UInt32(0x4741_5443))
        put(UInt32(1))
        put(UInt64(entries.count))
        for e in entries {
            put(e.hash); put(e.base); put(e.resource)
            put(e.boundsMin.x); put(e.boundsMin.y); put(e.boundsMin.z)
            put(e.boundsMax.x); put(e.boundsMax.y); put(e.boundsMax.z)
            put(e.radius); put(e.lodClass)
            let nb = Array(e.name.utf8.prefix(255))
            put(UInt8(nb.count))
            d.append(contentsOf: nb)
        }
        try d.write(to: URL(fileURLWithPath: path))
    }

    public static func read(from path: String) throws -> Catalog {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        return try d.withUnsafeBytes { p -> Catalog in
            var o = 0
            func get<T: FixedWidthInteger>(_ t: T.Type) -> T { defer { o += MemoryLayout<T>.size }; return p.loadUnaligned(fromByteOffset: o, as: T.self) }
            func f() -> Float { Float(bitPattern: get(UInt32.self)) }
            guard p.count >= 16, get(UInt32.self) == 0x4741_5443, get(UInt32.self) == 1 else { throw RPFError.format("bad catalog file") }
            let n = Int(get(UInt64.self))
            var out: [CatalogEntry] = []
            out.reserveCapacity(n)
            for _ in 0..<n {
                let h = get(UInt32.self), b = get(UInt32.self), r = get(UInt64.self)
                let mn = SIMD3(f(), f(), f()), mx = SIMD3(f(), f(), f())
                let rad = f()
                let lc = get(UInt8.self)
                let nl = Int(get(UInt8.self))
                let name = String(decoding: UnsafeRawBufferPointer(rebasing: p[o..<o + nl]), as: UTF8.self)
                o += nl
                out.append(CatalogEntry(hash: h, base: b, resource: r, boundsMin: mn, boundsMax: mx, radius: rad, lodClass: name.isEmpty ? lc : LodClass.of(name), name: name))
            }
            return Catalog(entries: out)
        }
    }
}
