import Foundation
import simd

public struct EntityDef: Sendable {
    public var position: SIMD3<Float>
    public var rotation: SIMD4<Float>
    public var name64: UInt64
    public var archetype: UInt32
    public var scaleXY: Float
    public var scaleZ: Float
    public var lodDist: Float
    public var childLodDist: Float
    public var flags: UInt32
    public var type: UInt32
}

public enum Entities {
    static let rotation: UInt32 = 0x77DD_4010
    static let position: UInt32 = 0x0116_6164
    static let name64: UInt32 = 0xC8A7_B90A
    static let archetype: UInt32 = 0xA023_A02C
    static let scaleXY: UInt32 = 0x9CA3_2637
    static let scaleZ: UInt32 = 0x10FB_7C42
    static let lod: UInt32 = 0xBF74_DFA7
    static let childLod: UInt32 = 0xCA97_4BCD
    static let flags: UInt32 = 0x67D2_6872

    public static func extract(_ p: PRD0) -> [EntityDef] {
        var out: [EntityDef] = []
        for blk in p.blocks {
            guard let s = p.structs[blk.type], s.size > 0,
                  let (rm, _) = s.member(rotation), rm.type == 0x34,
                  let (pm, _) = s.member(position), pm.type == 0x32 || pm.type == 0x33,
                  let (am, _) = s.member(archetype) else { continue }
            let nm = s.member(name64)?.0
            let sx = s.member(scaleXY)?.0, sz = s.member(scaleZ)?.0
            let ld = s.member(lod)?.0, cl = s.member(childLod)?.0, fl = s.member(flags)?.0
            let n = blk.size / s.size
            for i in 0..<n {
                let o = blk.offset + i * s.size
                guard o + s.size <= p.b.count else { break }
                let pos = SIMD3(p.f32(o + pm.offset), p.f32(o + pm.offset + 4), p.f32(o + pm.offset + 8))
                let rot = SIMD4(p.f32(o + rm.offset), p.f32(o + rm.offset + 4), p.f32(o + rm.offset + 8), p.f32(o + rm.offset + 12))
                out.append(EntityDef(position: pos, rotation: rot, name64: nm.map { p.u64(o + $0.offset) } ?? 0, archetype: p.u32(o + am.offset),
                                     scaleXY: sx.map { p.f32(o + $0.offset) } ?? 1, scaleZ: sz.map { p.f32(o + $0.offset) } ?? 1,
                                     lodDist: ld.map { p.f32(o + $0.offset) } ?? 0, childLodDist: cl.map { p.f32(o + $0.offset) } ?? 0,
                                     flags: fl.map { p.u32(o + $0.offset) } ?? 0, type: blk.type))
            }
        }
        return out
    }

    public static func loadAll(index: ArchiveIndex, file: MappedFile, mapsOnly: Bool = false) -> [(UInt64, [EntityDef])] {
        let starts = MapData.prd0Starts(index)
        let lock = NSLock()
        var all: [(UInt64, [EntityDef])] = []
        DispatchQueue.concurrentPerform(iterations: starts.count) { i in
            guard let r = try? index.resource(at: starts[i], from: file, physical: false), let p = try? PRD0(r.virtual) else { return }
            if mapsOnly && p.block(ofType: MapData.mapStruct) == nil { return }
            let e = extract(p)
            if e.isEmpty { return }
            lock.lock()
            all.append((starts[i], e))
            lock.unlock()
        }
        return all.sorted { $0.0 < $1.0 }
    }

    public static func write(_ ents: [EntityDef], to path: String) throws {
        var d = Data()
        d.reserveCapacity(16 + ents.count * 52)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(UInt32(0x544E_4545))
        put(UInt32(1))
        put(UInt64(ents.count))
        for e in ents {
            put(e.position.x); put(e.position.y); put(e.position.z)
            put(e.rotation.x); put(e.rotation.y); put(e.rotation.z); put(e.rotation.w)
            put(e.scaleXY); put(e.scaleZ); put(e.lodDist); put(e.childLodDist); put(e.archetype); put(e.flags)
        }
        try d.write(to: URL(fileURLWithPath: path))
    }

    public static func read(from path: String) throws -> [EntityDef] {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        return try d.withUnsafeBytes { p -> [EntityDef] in
            guard p.count >= 16, p.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == 0x544E_4545 else { throw RPFError.format("bad entity cache") }
            let n = Int(p.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
            guard p.count >= 16 + n * 52 else { throw RPFError.format("entity cache truncated") }
            var out: [EntityDef] = []
            out.reserveCapacity(n)
            for i in 0..<n {
                let o = 16 + i * 52
                func f(_ k: Int) -> Float { p.loadUnaligned(fromByteOffset: o + 4 * k, as: Float.self) }
                func u(_ k: Int) -> UInt32 { p.loadUnaligned(fromByteOffset: o + 4 * k, as: UInt32.self) }
                out.append(EntityDef(position: SIMD3(f(0), f(1), f(2)), rotation: SIMD4(f(3), f(4), f(5), f(6)), name64: 0, archetype: u(11),
                                     scaleXY: f(7), scaleZ: f(8), lodDist: f(9), childLodDist: f(10), flags: u(12), type: 0))
            }
            return out
        }
    }
}
