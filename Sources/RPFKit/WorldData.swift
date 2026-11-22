import Foundation
import simd

public struct MapInfo: Sendable {
    public var name: UInt32
    public var group: UInt32
    public var flags: UInt32
    public var first: Int32
    public var count: Int32
    public var level: UInt8
    public var id: UInt64
    public var parentFirst: Int32
    public var parentCount: Int32
}

public struct Basis: Sendable {
    public var r0: SIMD3<Float> = SIMD3(1, 0, 0)
    public var r1: SIMD3<Float> = SIMD3(0, 1, 0)
    public var r2: SIMD3<Float> = SIMD3(0, 0, 1)
    public init() {}
    public init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) { r0 = a; r1 = b; r2 = c }
}

public struct WorldEntity: Sendable {
    public var position: SIMD3<Float>
    public var rotation: SIMD4<Float>
    public var archetype: UInt32
    public var scaleXY: Float
    public var scaleZ: Float
    public var lodDist: Float
    public var childLodDist: Float
    public var flags: UInt32
    public var parentLocal: Int32
    public var numChildren: UInt32
    public var lodLevel: UInt8
    public var map: Int32
    public var parent: Int32
    public var basis = Basis()
    public var hasBasis = false
    public var batch: Int32 = -1
}

public struct ArchetypeInfo: Sendable {
    public var lodDist: Float
    public var center: SIMD3<Float>
    public var radius: Float
}

public final class WorldData {
    public var maps: [MapInfo] = []
    public var parentIds: [UInt64] = []
    public var entities: [WorldEntity] = []
    public var archetypes: [UInt32: ArchetypeInfo] = [:]

    public init() {}

    static let mapName: UInt32 = 0xE6E1_7F14
    static let mapGroup: UInt32 = 0x6C0F_9C8C
    static let mapFlags: UInt32 = 0x6A67_5035
    static let mapId: UInt32 = 0x8BFB_6095
    static let mapParents: UInt32 = 0x86AA_B4BF
    static let mapEntities: UInt32 = 0xCCAB_9307
    static let archName: UInt32 = 0x66D9_CB52
    static let archLod: UInt32 = 0xBF74_DFA7
    static let archCenter: UInt32 = 0xD618_72FF
    static let archRadius: UInt32 = 0x82E8_C5DE

    public final class Counter: @unchecked Sendable {
        let lock = NSLock()
        public var value = 0
        func add(_ n: Int) { lock.lock(); value += n; lock.unlock() }
    }
    nonisolated(unsafe) public static let unlisted = Counter()

    static let batchInstances: UInt32 = 0x1C08_0BB9
    static let batchMatrix: UInt32 = 0x7EE6_CC43

    public final class BatchStats: @unchecked Sendable {
        let lock = NSLock()
        public var batches = 0, instances = 0, unresolved = 0
        func add(_ b: Int, _ i: Int, _ u: Int) { lock.lock(); batches += b; instances += i; unresolved += u; lock.unlock() }
    }
    nonisolated(unsafe) public static let batchStats = BatchStats()

    static func needsPhysical(_ p: PRD0) -> Bool {
        p.structs.values.contains { $0.member(batchInstances) != nil }
    }

    struct EntityLayout {
        let size: Int
        let rot: Int, pos: Int, arch: Int
        let sxy: Int?, sz: Int?, lod: Int?, child: Int?, flags: Int?, parent: Int?, kids: Int?
        let level: Int?
        let batch: (offset: Int, matrix: Int, stride: Int)?

        init?(_ s: PRD0Struct, _ structs: [UInt32: PRD0Struct]) {
            guard s.size >= 0x80, let (rm, _) = s.member(Entities.rotation), rm.type == 0x34,
                  let (pm, _) = s.member(Entities.position), pm.type == 0x32 || pm.type == 0x33,
                  let (am, _) = s.member(Entities.archetype) else { return nil }
            size = s.size
            rot = rm.offset; pos = pm.offset; arch = am.offset
            sxy = s.member(Entities.scaleXY)?.0.offset
            sz = s.member(Entities.scaleZ)?.0.offset
            lod = s.member(Entities.lod)?.0.offset
            child = s.member(Entities.childLod)?.0.offset
            flags = s.member(Entities.flags)?.0.offset
            parent = s.member(0xD892_31BD)?.0.offset
            kids = s.member(0xA687_AC89)?.0.offset
            level = s.member(0x6C8F_1715)?.0.offset
            if let (bm, el) = s.member(WorldData.batchInstances), bm.type == 0x52, let el = el, el.type == 0x05,
               let es = structs[el.ref], es.size >= 48, let (mm, _) = es.member(WorldData.batchMatrix) {
                batch = (bm.offset, mm.offset, es.size)
            } else {
                batch = nil
            }
        }

        func instances(_ p: PRD0, _ physical: [UInt8], _ o: Int, _ e: WorldEntity) -> [WorldEntity]? {
            guard let b = batch else { return nil }
            let v = p.u64(o + b.offset)
            let n = Int(p.u16(o + b.offset + 8))
            if n == 0 { return [] }
            let bi = Int(v & 0xFFFFF), off = Int(v >> 20)
            guard bi >= 1, bi <= p.blocks.count else { return nil }
            let blk = p.blocks[bi - 1]
            let buf: [UInt8], base: Int
            if blk.size > 0 {
                buf = p.b
                base = blk.offset + off
            } else if blk.physOffset >= 0, !physical.isEmpty {
                buf = physical
                base = blk.physOffset + off
            } else {
                return nil
            }
            guard base >= 0, base + n * b.stride <= buf.count else { return nil }
            func f(_ k: Int) -> Float { buf.withUnsafeBytes { Float(bitPattern: $0.loadUnaligned(fromByteOffset: k, as: UInt32.self)) } }
            var out: [WorldEntity] = []
            out.reserveCapacity(n)
            for i in 0..<n {
                let m = base + i * b.stride + b.matrix
                let r0 = SIMD4(f(m), f(m + 4), f(m + 8), f(m + 12))
                let r1 = SIMD4(f(m + 16), f(m + 20), f(m + 24), f(m + 28))
                let r2 = SIMD4(f(m + 32), f(m + 36), f(m + 40), f(m + 44))
                let c0 = SIMD3(r0.x, r0.y, r0.z), c1 = SIMD3(r1.x, r1.y, r1.z), c2 = SIMD3(r2.x, r2.y, r2.z)
                let sx = simd_length(c0), sy = simd_length(c1), sz = simd_length(c2)
                guard sx > 1e-4, sy > 1e-4, sz > 1e-4, r0.w.isFinite, r1.w.isFinite, r2.w.isFinite else { continue }
                let q = simd_quatf(simd_float3x3(columns: (c0 / sx, c1 / sy, c2 / sz))).normalized
                var x = e
                x.position = SIMD3(r0.w, r1.w, r2.w)
                x.rotation = SIMD4(-q.imag.x, -q.imag.y, -q.imag.z, q.real)
                x.scaleXY = max(sx, sy)
                x.scaleZ = sz
                x.basis = Basis(SIMD3(c0.x, c1.x, c2.x), SIMD3(c0.y, c1.y, c2.y), SIMD3(c0.z, c1.z, c2.z))
                x.hasBasis = true
                out.append(x)
            }
            return out
        }

        func read(_ p: PRD0, _ o: Int) -> WorldEntity {
            WorldEntity(position: SIMD3(p.f32(o + pos), p.f32(o + pos + 4), p.f32(o + pos + 8)),
                        rotation: SIMD4(p.f32(o + rot), p.f32(o + rot + 4), p.f32(o + rot + 8), p.f32(o + rot + 12)),
                        archetype: p.u32(o + arch), scaleXY: sxy.map { p.f32(o + $0) } ?? 1, scaleZ: sz.map { p.f32(o + $0) } ?? 1,
                        lodDist: lod.map { p.f32(o + $0) } ?? -1, childLodDist: child.map { p.f32(o + $0) } ?? 0,
                        flags: flags.map { p.u32(o + $0) } ?? 0, parentLocal: parent.map { Int32(Int16(bitPattern: p.u16(o + $0))) } ?? -1,
                        numChildren: kids.map { p.u32(o + $0) } ?? 0, lodLevel: level.map { p.u8(o + $0) } ?? 0, map: 0, parent: -1)
        }
    }

    static func pointer(_ p: PRD0, _ v: UInt64) -> Int? {
        let blk = Int(v & 0xFFFFF), off = Int(v >> 20)
        guard blk >= 1, blk <= p.blocks.count, p.blocks[blk - 1].size > 0 else { return nil }
        return p.blocks[blk - 1].offset + off
    }

    static func readMap(_ p: PRD0, physical: [UInt8] = []) -> (MapInfo, [WorldEntity], [UInt64])? {
        guard let mb = p.block(ofType: MapData.mapStruct), let ms = p.structs[MapData.mapStruct] else { return nil }
        func field(_ h: UInt32) -> Int? {
            guard let (m, _) = ms.member(h), mb.offset + m.offset + 16 <= p.b.count else { return nil }
            return mb.offset + m.offset
        }
        func mu32(_ h: UInt32) -> UInt32 { field(h).map { p.u32($0) } ?? 0 }
        var layouts: [UInt32: EntityLayout] = [:]
        for (k, st) in p.structs { if let l = EntityLayout(st, p.structs) { layouts[k] = l } }
        guard !layouts.isEmpty else { return nil }
        var ents: [WorldEntity] = []
        var seen = Set<Int>()
        var extra: [WorldEntity] = []
        var dropped = Set<Int>()
        var nb = 0, ni = 0, nu = 0
        func place(_ l: EntityLayout, _ o: Int, _ e: WorldEntity) -> WorldEntity {
            guard l.batch != nil else { return e }
            nb += 1
            guard var list = l.instances(p, physical, o, e), !list.isEmpty else {
                nu += 1
                dropped.insert(ents.count)
                return e
            }
            ni += list.count
            for j in list.indices { list[j].batch = Int32(ents.count) }
            extra.append(contentsOf: list.dropFirst())
            return list[0]
        }
        if let f = field(mapEntities), let (ao, n) = p.array(at: f), ao + 8 * n <= p.b.count {
            for k in 0..<n {
                let v = p.u64(ao + 8 * k)
                let bi = Int(v & 0xFFFFF)
                guard bi >= 1, bi <= p.blocks.count, p.blocks[bi - 1].size > 0, let l = layouts[p.blocks[bi - 1].type] else { continue }
                let o = p.blocks[bi - 1].offset + Int(v >> 20)
                guard o + l.size <= p.b.count else { continue }
                ents.append(place(l, o, l.read(p, o)))
                seen.insert(o)
            }
        }
        let listed = ents.count
        for blk in p.blocks {
            guard let l = layouts[blk.type] else { continue }
            for i in 0..<blk.size / l.size {
                let o = blk.offset + i * l.size
                guard o + l.size <= p.b.count else { break }
                if seen.contains(o) { continue }
                var e = l.read(p, o)
                if listed > 0 { e.parentLocal = -1 }
                ents.append(place(l, o, e))
            }
        }
        for k in dropped {
            ents[k].scaleXY = 0
            ents[k].scaleZ = 0
            ents[k].archetype = 0
        }
        ents.append(contentsOf: extra)
        batchStats.add(nb, ni, nu)
        guard !ents.isEmpty else { return nil }
        var parents: [UInt64] = []
        if let f = field(mapParents) {
            let n = Int(p.u32(f))
            if n > 0, n < 4096, let ao = pointer(p, p.u64(f + 8)), ao + 8 * n <= p.b.count {
                for k in 0..<n { parents.append(p.u64(ao + 8 * k)) }
            }
        }
        var hist = [Int](repeating: 0, count: 8)
        for e in ents { hist[Int(min(e.lodLevel, 7))] += 1 }
        let level = UInt8(hist.indices.max { hist[$0] < hist[$1] } ?? 0)
        unlisted.add(ents.count - listed)
        let info = MapInfo(name: mu32(mapName), group: mu32(mapGroup), flags: mu32(mapFlags), first: 0, count: Int32(ents.count), level: level,
                           id: field(mapId).map { p.u64($0) } ?? 0, parentFirst: 0, parentCount: Int32(parents.count))
        return (info, ents, parents)
    }

    static func readArchetypes(_ p: PRD0, into out: inout [UInt32: ArchetypeInfo]) {
        for blk in p.blocks {
            guard let s = p.structs[blk.type], s.size > 0, let (nm, _) = s.member(archName), nm.type == 0x4A,
                  let (lm, _) = s.member(archLod) else { continue }
            let cm = s.member(archCenter)?.0, rm = s.member(archRadius)?.0
            let n = blk.size / s.size
            for i in 0..<n {
                let o = blk.offset + i * s.size
                guard o + s.size <= p.b.count else { break }
                let c = cm.map { SIMD3(p.f32(o + $0.offset), p.f32(o + $0.offset + 4), p.f32(o + $0.offset + 8)) } ?? .zero
                out[p.u32(o + nm.offset)] = ArchetypeInfo(lodDist: p.f32(o + lm.offset), center: c, radius: rm.map { p.f32(o + $0.offset) } ?? 0)
            }
        }
    }

    public static func load(sources: [(ArchiveIndex, MappedFile)], progress: ((String) -> Void)? = nil) -> WorldData {
        let w = WorldData()
        let lock = NSLock()
        var parts: [(UInt64, Int, MapInfo, [WorldEntity], [UInt64])] = []
        for (si, (index, file)) in sources.enumerated() {
            let starts = MapData.prd0Starts(index)
            progress?("Reading map data \(si + 1)/\(sources.count): \(starts.count) metadata files")
            DispatchQueue.concurrentPerform(iterations: starts.count) { i in
                guard let r = try? index.resource(at: starts[i], from: file, physical: false), let p = try? PRD0(r.virtual) else { return }
                var arch: [UInt32: ArchetypeInfo] = [:]
                readArchetypes(p, into: &arch)
                var phys: [UInt8] = []
                if needsPhysical(p), let rp = try? index.resource(at: starts[i], from: file, physical: true) { phys = rp.physical }
                let m = readMap(p, physical: phys)
                lock.lock()
                for (k, v) in arch { w.archetypes[k] = v }
                if let (mi, ents, par) = m { parts.append((starts[i], si, mi, ents, par)) }
                lock.unlock()
            }
        }
        parts.sort { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
        for (_, _, mi, ents, par) in parts {
            var m = mi
            m.first = Int32(w.entities.count)
            m.parentFirst = Int32(w.parentIds.count)
            w.parentIds.append(contentsOf: par)
            let mapIndex = Int32(w.maps.count)
            w.maps.append(m)
            for var e in ents {
                e.map = mapIndex
                if e.batch >= 0 { e.batch += m.first }
                w.entities.append(e)
            }
        }
        w.resolveParents()
        return w
    }

    public var parentStats = (maps: 0, resolved: 0, childLinks: 0, exact: 0)

    static func rank(_ l: UInt8) -> Int {
        switch l {
        case 0, 5: return 0
        case 6: return 5
        default: return Int(min(l, 4))
        }
    }

    func resolveParents() {
        var byId: [UInt64: Int] = [:]
        for (i, m) in maps.enumerated() where m.id != 0 { byId[m.id] = i }
        var assigned = [Int32](repeating: 0, count: entities.count)
        parentStats = (maps.count, 0, 0, 0)
        for m in maps where m.parentCount > 0 {
            let pms = (0..<Int(m.parentCount)).compactMap { byId[parentIds[Int(m.parentFirst) + $0]] }
            guard !pms.isEmpty else { continue }
            var linked = false
            for k in Int(m.first)..<Int(m.first + m.count) {
                let e = entities[k]
                let pl = Int(e.parentLocal)
                guard pl >= 0 else { continue }
                let r = WorldData.rank(e.lodLevel)
                var best = -1
                var bestD = Float.infinity
                for pmi in pms {
                    let pm = maps[pmi]
                    guard pl < Int(pm.count) else { continue }
                    let pi = Int(pm.first) + pl
                    let pe = entities[pi]
                    guard pe.numChildren > 0, WorldData.rank(pe.lodLevel) > r else { continue }
                    let d = simd_distance(pe.position, e.position)
                    if d < bestD {
                        bestD = d
                        best = pi
                    }
                }
                guard best >= 0 else { continue }
                entities[k].parent = Int32(best)
                assigned[best] += 1
                parentStats.childLinks += 1
                linked = true
            }
            if linked { parentStats.resolved += 1 }
        }
        for (i, e) in entities.enumerated() where e.numChildren > 0 && Int(assigned[i]) == Int(e.numChildren) { parentStats.exact += 1 }
    }

    public func write(to path: String) throws {
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(UInt32(0x444C_5257))
        put(UInt32(7))
        put(UInt64(maps.count)); put(UInt64(entities.count)); put(UInt64(archetypes.count)); put(UInt64(parentIds.count))
        for m in maps { put(m.name); put(m.group); put(m.flags); put(m.first); put(m.count); put(UInt32(m.level)); put(m.id); put(m.parentFirst); put(m.parentCount) }
        for v in parentIds { put(v) }
        for e in entities {
            put(e.position.x); put(e.position.y); put(e.position.z)
            put(e.rotation.x); put(e.rotation.y); put(e.rotation.z); put(e.rotation.w)
            put(e.archetype); put(e.scaleXY); put(e.scaleZ); put(e.lodDist); put(e.childLodDist); put(e.flags)
            put(e.parentLocal); put(e.numChildren); put(UInt32(e.lodLevel)); put(e.map); put(e.parent)
            put(UInt32(e.hasBasis ? 1 : 0))
            for r in [e.basis.r0, e.basis.r1, e.basis.r2] { put(r.x); put(r.y); put(r.z) }
            put(e.batch)
        }
        for (k, a) in archetypes { put(k); put(a.lodDist); put(a.center.x); put(a.center.y); put(a.center.z); put(a.radius) }
        try d.write(to: URL(fileURLWithPath: path))
    }

    public static func read(from path: String) throws -> WorldData {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        return try d.withUnsafeBytes { p -> WorldData in
            var o = 0
            func get<T>(_ t: T.Type) -> T { defer { o += MemoryLayout<T>.size }; return p.loadUnaligned(fromByteOffset: o, as: T.self) }
            guard p.count >= 40, get(UInt32.self) == 0x444C_5257, get(UInt32.self) == 7 else { throw RPFError.format("bad world cache") }
            let nm = Int(get(UInt64.self)), ne = Int(get(UInt64.self)), na = Int(get(UInt64.self)), np = Int(get(UInt64.self))
            guard p.count >= 40 + nm * 40 + np * 8 + ne * 116 + na * 24 else { throw RPFError.format("world cache truncated") }
            let w = WorldData()
            w.maps.reserveCapacity(nm)
            for _ in 0..<nm {
                w.maps.append(MapInfo(name: get(UInt32.self), group: get(UInt32.self), flags: get(UInt32.self), first: get(Int32.self), count: get(Int32.self),
                                      level: UInt8(get(UInt32.self)), id: get(UInt64.self), parentFirst: get(Int32.self), parentCount: get(Int32.self)))
            }
            w.parentIds.reserveCapacity(np)
            for _ in 0..<np { w.parentIds.append(get(UInt64.self)) }
            w.entities.reserveCapacity(ne)
            for _ in 0..<ne {
                let pos = SIMD3(get(Float.self), get(Float.self), get(Float.self))
                let rot = SIMD4(get(Float.self), get(Float.self), get(Float.self), get(Float.self))
                var e = WorldEntity(position: pos, rotation: rot, archetype: get(UInt32.self), scaleXY: get(Float.self), scaleZ: get(Float.self),
                                    lodDist: get(Float.self), childLodDist: get(Float.self), flags: get(UInt32.self), parentLocal: get(Int32.self),
                                    numChildren: get(UInt32.self), lodLevel: UInt8(get(UInt32.self)), map: get(Int32.self), parent: get(Int32.self))
                e.hasBasis = get(UInt32.self) != 0
                let a = SIMD3(get(Float.self), get(Float.self), get(Float.self))
                let b = SIMD3(get(Float.self), get(Float.self), get(Float.self))
                let c = SIMD3(get(Float.self), get(Float.self), get(Float.self))
                e.basis = Basis(a, b, c)
                e.batch = get(Int32.self)
                w.entities.append(e)
            }
            w.archetypes.reserveCapacity(na)
            for _ in 0..<na {
                let k = get(UInt32.self), l = get(Float.self)
                let c = SIMD3(get(Float.self), get(Float.self), get(Float.self))
                w.archetypes[k] = ArchetypeInfo(lodDist: l, center: c, radius: get(Float.self))
            }
            return w
        }
    }
}
