import Foundation
import simd

public struct MapEntity: Sendable {
    public var position: SIMD3<Float>
    public var lodDist: Float
    public var archetype: UInt32
    public var hash: UInt32
    public var packed: UInt32
    public var scale: UInt16
    public var u16b: UInt16
    public var offset: UInt16
    public var u16d: UInt16
    public var level: UInt8
    public var flags: UInt8
}

public enum MapData {
    public static let mapStruct: UInt32 = 0xD359_3FA6
    static let soaMember: UInt32 = 0xB019_9551

    public static func entities(_ p: PRD0) -> [MapEntity] {
        guard let md = p.block(ofType: mapStruct), let ms = p.structs[mapStruct],
              let (soaM, _) = ms.member(soaMember), let soa = p.structs[soaM.ref] else { return [] }
        let base = md.offset + soaM.offset
        func arr(_ name: UInt32) -> (Int, Int)? {
            guard let (m, _) = soa.member(name), m.type == 0x52 || m.type == 0x5C, let a = p.array(at: base + m.offset) else { return nil }
            return (a.offset, a.count)
        }
        guard let (pos, n) = arr(0x0116_6164), n > 0, pos + 12 * n <= p.b.count else { return [] }
        func get<T>(_ name: UInt32, _ stride: Int, _ read: @escaping (Int) -> T, _ fallback: T) -> (Int) -> T {
            guard let (o, c) = arr(name), c == n, o + stride * n <= p.b.count else { return { _ in fallback } }
            return { i in read(o + stride * i) }
        }
        let lod = get(0xEFCD_993D, 4, p.f32, 0)
        let arch = get(0xFFEC_781A, 4, p.u32, 0)
        let hash = get(0x3E81_8018, 4, p.u32, 0)
        let packed = get(0x9472_0DEC, 4, p.u32, 0)
        let scale = get(0x699D_D4D9, 2, p.u16, 0x3C00)
        let u16b = get(0xFDAF_B23B, 2, p.u16, 0)
        let offset = get(0xA13C_79EF, 2, p.u16, 0)
        let u16d = get(0x5B92_FA4B, 2, p.u16, 0)
        let level = get(0x1CBB_BE30, 1, p.u8, 0)
        let flags = get(0x67D2_6872, 1, p.u8, 0)
        var out: [MapEntity] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let o = pos + 12 * i
            out.append(MapEntity(position: SIMD3(p.f32(o), p.f32(o + 4), p.f32(o + 8)), lodDist: lod(i), archetype: arch(i), hash: hash(i),
                                 packed: packed(i), scale: scale(i), u16b: u16b(i), offset: offset(i), u16d: u16d(i), level: level(i), flags: flags(i)))
        }
        return out
    }

    public static func prd0Starts(_ index: ArchiveIndex) -> [UInt64] {
        index.entries.compactMap { e in
            guard e.kind == .zlib, e.head.count >= 20, e.head[0..<8].allSatisfy({ $0 == 0 }),
                  e.head[16] == 0x30, e.head[17] == 0x44, e.head[18] == 0x52, e.head[19] == 0x50 else { return nil }
            return e.offset
        }
    }

    public static func loadAll(index: ArchiveIndex, file: MappedFile) -> [(UInt64, [MapEntity])] {
        let starts = prd0Starts(index)
        let lock = NSLock()
        var maps: [(UInt64, [MapEntity])] = []
        DispatchQueue.concurrentPerform(iterations: starts.count) { i in
            guard let r = try? index.resource(at: starts[i], from: file, physical: false), let p = try? PRD0(r.virtual) else { return }
            let e = entities(p)
            if e.isEmpty { return }
            lock.lock()
            maps.append((starts[i], e))
            lock.unlock()
        }
        return maps.sorted { $0.0 < $1.0 }
    }
}
