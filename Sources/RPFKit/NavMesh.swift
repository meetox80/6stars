import Foundation
import simd

public enum NavSurface: UInt8, Sendable {
    case ground = 0
    case pavement = 1
    case road = 2
    case water = 3
}

public struct NavTileRef: Sendable {
    public var area: UInt32
    public var contentFlags: UInt32
    public var offset: UInt64

    public var isOcean: Bool { contentFlags == NavMesh.oceanFlags }
}

public struct NavTileMesh: Sendable {
    public var origin: SIMD2<Float>
    public var positions: [SIMD2<Float>]
    public var surfaces: [NavSurface]
    public var heights: [Float]
    public var corners: [SIMD3<UInt16>]
    public var words: [[UInt32]] = []
}

public enum NavLevel: UInt8, Sendable {
    case hidden = 0
    case street = 1
    case overpass = 2
    case raised = 3
}

public enum NavMesh {
    public static let version: UInt32 = 0x10015
    public static let oceanFlags: UInt32 = 9
    public static let tileSize: Float = 128
    static let gridOrigin: Float = -32768
    static let gridWidth: UInt32 = 512
    static let pavementBit: UInt32 = 1 << 27
    static let roadBit: UInt32 = 1 << 17
    static let waterBit: UInt32 = 1 << 19

    public static func origin(area: UInt32) -> SIMD2<Float> {
        SIMD2(Float(area % gridWidth) * tileSize + gridOrigin, Float(area / gridWidth) * tileSize + gridOrigin)
    }

    public static func area(at p: SIMD2<Float>) -> UInt32? {
        let x = Int(floor((p.x - gridOrigin) / tileSize)), y = Int(floor((p.y - gridOrigin) / tileSize))
        guard x >= 0, y >= 0, x < Int(gridWidth), y < Int(gridWidth) else { return nil }
        return UInt32(y) * gridWidth + UInt32(x)
    }

    public static func buildIndex(_ index: ArchiveIndex, file: MappedFile) -> [NavTileRef] {
        let entries = index.entries
        var candidates: [Int] = []
        for i in entries.indices where index.isResourceStart(i) {
            let h = entries[i].head
            guard h.count >= 0x18 else { continue }
            let ver = h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0x14, as: UInt32.self) }
            if ver == version { candidates.append(i) }
        }
        let slots = UnsafeMutableBufferPointer<NavTileRef?>.allocate(capacity: candidates.count)
        slots.initialize(repeating: nil)
        defer { slots.deallocate() }
        DispatchQueue.concurrentPerform(iterations: candidates.count) { k in
            let e = entries[candidates[k]]
            guard let d = try? Inflate.full(file.base + Int(e.offset), Int(e.size), limit: 0x100).data, d.count >= 0xCC else { return }
            let flags = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0x10, as: UInt32.self) }
            let area = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0xC8, as: UInt32.self) }
            slots[k] = NavTileRef(area: area, contentFlags: flags, offset: e.offset)
        }
        return slots.compactMap { $0 }
    }

    public static func writeIndex(_ refs: [NavTileRef], to path: String) throws {
        var out = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { out.append(contentsOf: $0) } }
        put(UInt32(0x5456_414E))
        put(UInt32(1))
        put(UInt64(refs.count))
        for r in refs {
            put(r.area)
            put(r.contentFlags)
            put(r.offset)
        }
        try out.write(to: URL(fileURLWithPath: path))
    }

    public static func readIndex(from path: String) throws -> [NavTileRef] {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        return try d.withUnsafeBytes { p -> [NavTileRef] in
            guard p.count >= 16, p.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == 0x5456_414E,
                  p.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == 1 else { throw RPFError.format("bad navmesh tile index") }
            let n = Int(p.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
            guard p.count >= 16 + n * 16 else { throw RPFError.format("navmesh tile index truncated") }
            return (0..<n).map { i in
                let o = 16 + i * 16
                return NavTileRef(area: p.loadUnaligned(fromByteOffset: o, as: UInt32.self),
                                  contentFlags: p.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self),
                                  offset: p.loadUnaligned(fromByteOffset: o + 8, as: UInt64.self))
            }
        }
    }

    public static func decode(_ r: Resource, area: UInt32, ocean: Bool, keepWords: Bool = false) throws -> NavTileMesh {
        let v = r.virtual
        func u16(_ o: Int) -> Int { Int(v[o]) | Int(v[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { v.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
        func list(_ at: Int, _ stride: Int) throws -> [Int] {
            guard let l = Resource.vptr(v, at), l + 0x24 <= v.count, let parts = Resource.vptr(v, l + 0x10) else { throw RPFError.format("navmesh list missing") }
            let count = Int(u32(l + 8)), np = Int(u32(l + 0x20))
            var items: [Int] = []
            items.reserveCapacity(count)
            for k in 0..<np {
                guard parts + 16 * k + 12 <= v.count, let base = Resource.vptr(v, parts + 16 * k) else { throw RPFError.format("navmesh list part missing") }
                let n = Int(u32(parts + 16 * k + 8))
                guard base + n * stride <= v.count else { throw RPFError.format("navmesh list part out of range") }
                for j in 0..<n { items.append(base + j * stride) }
            }
            guard items.count == count else { throw RPFError.format("navmesh list count mismatch") }
            return items
        }
        guard v.count >= 0xD0, u32(0x14) == version, let tree = Resource.vptr(v, 0xA0), tree + 12 <= v.count else { throw RPFError.format("not a navmesh tile") }
        let size = SIMD3(f32(0x60), f32(0x64), f32(0x68))
        let mn = SIMD3(f32(tree), f32(tree + 4), f32(tree + 8))
        let verts = try list(0x70, 6)
        let indices = try list(0x80, 2)
        let polys = try list(0x98, 44)
        let origin = NavMesh.origin(area: area)
        func vertex(_ i: Int) -> SIMD3<Float> {
            let o = verts[i]
            return SIMD3(mn.x + Float(u16(o)) * size.x / 65536, mn.y + Float(u16(o + 2)) * size.y / 65536, mn.z + Float(u16(o + 4)) * size.z / 65536)
        }
        var mesh = NavTileMesh(origin: origin, positions: [], surfaces: [], heights: [], corners: [])
        mesh.positions.reserveCapacity(polys.count * 6)
        for p in polys {
            let word = Int(u32(p + 4))
            let start = word >> 4, count = word & 15
            guard count >= 3, start + count <= indices.count else { continue }
            var pts: [SIMD3<Float>] = []
            var ids: [UInt16] = []
            pts.reserveCapacity(count)
            ids.reserveCapacity(count)
            var ok = true
            for k in 0..<count {
                let vi = u16(indices[start + k])
                guard vi < verts.count else { ok = false; break }
                pts.append(vertex(vi))
                ids.append(UInt16(vi))
            }
            guard ok else { continue }
            let surface: NavSurface
            if ocean || u32(p + 24) & waterBit != 0 {
                surface = .water
            } else if u32(p + 40) & roadBit != 0 {
                surface = .road
            } else if u32(p + 24) & pavementBit != 0 {
                surface = .pavement
            } else {
                surface = .ground
            }
            let z = pts.reduce(0) { $0 + $1.z } / Float(pts.count)
            for k in 1..<(pts.count - 1) {
                mesh.positions.append(SIMD2(pts[0].x, pts[0].y) - origin)
                mesh.positions.append(SIMD2(pts[k].x, pts[k].y) - origin)
                mesh.positions.append(SIMD2(pts[k + 1].x, pts[k + 1].y) - origin)
                mesh.surfaces.append(surface)
                mesh.heights.append(z)
                mesh.corners.append(SIMD3(ids[0], ids[k], ids[k + 1]))
                if keepWords { mesh.words.append((0..<11).map { u32(p + 4 * $0) }) }
            }
        }
        return mesh
    }

    static let levelCell: Float = 8
    static let levelReach = 6
    static let levelBin: Float = 1
    static let raised: Float = 4
    static let streetPercentile: Float = 0.2
    static let overpassRoadShare: Float = 0.2
    static let roadCell: Float = 2
    static let roadReach: Float = 6

    public static func levels(_ m: NavTileMesh) -> [NavLevel] {
        let n = m.surfaces.count
        var out = [NavLevel](repeating: .street, count: n)
        guard n > 0, let zMin = m.heights.min(), let zMax = m.heights.max() else { return out }
        let g = Int(tileSize / levelCell)
        let bins = Int((zMax - zMin) / levelBin) + 1
        var street = [Float](repeating: 0, count: g * g * bins)
        var any = [Float](repeating: 0, count: g * g * bins)
        var area = [Float](repeating: 0, count: n)
        var cellOf = [Int](repeating: 0, count: n)
        for t in 0..<n {
            let a = m.positions[3 * t], b = m.positions[3 * t + 1], c = m.positions[3 * t + 2]
            let e1 = b - a, e2 = c - a
            area[t] = abs(e1.x * e2.y - e1.y * e2.x) * 0.5
            let cen = (a + b + c) / 3
            let cx = max(0, min(g - 1, Int(cen.x / levelCell))), cy = max(0, min(g - 1, Int(cen.y / levelCell)))
            cellOf[t] = cy * g + cx
            let bin = min(bins - 1, Int((m.heights[t] - zMin) / levelBin))
            any[cellOf[t] * bins + bin] += area[t]
            if m.surfaces[t] == .road || m.surfaces[t] == .pavement { street[cellOf[t] * bins + bin] += area[t] }
        }
        func boxSum(_ h: [Float]) -> [Float] {
            var tmp = [Float](repeating: 0, count: h.count)
            for y in 0..<g {
                for x in 0..<g {
                    for dx in max(0, x - levelReach)...min(g - 1, x + levelReach) {
                        let src = (y * g + dx) * bins, dst = (y * g + x) * bins
                        for k in 0..<bins { tmp[dst + k] += h[src + k] }
                    }
                }
            }
            var res = [Float](repeating: 0, count: h.count)
            for y in 0..<g {
                for x in 0..<g {
                    for dy in max(0, y - levelReach)...min(g - 1, y + levelReach) {
                        let src = (dy * g + x) * bins, dst = (y * g + x) * bins
                        for k in 0..<bins { res[dst + k] += tmp[src + k] }
                    }
                }
            }
            return res
        }
        let streetNear = boxSum(street), anyNear = boxSum(any)
        var reference = [Float](repeating: .nan, count: g * g)
        for cell in 0..<(g * g) {
            let base = cell * bins
            var h = Array(streetNear[base..<(base + bins)])
            if h.reduce(0, +) < 20 { h = Array(anyNear[base..<(base + bins)]) }
            let total = h.reduce(0, +)
            guard total > 0 else { continue }
            var run: Float = 0
            for k in 0..<bins {
                run += h[k]
                if run >= total * streetPercentile {
                    reference[cell] = zMin + (Float(k) + 1) * levelBin
                    break
                }
            }
        }
        func streetLevel(_ t: Int) -> Float {
            let a = m.positions[3 * t], b = m.positions[3 * t + 1], c = m.positions[3 * t + 2]
            let q = (a + b + c) / 3 / levelCell - 0.5
            let x0 = max(0, min(g - 1, Int(floor(q.x)))), y0 = max(0, min(g - 1, Int(floor(q.y))))
            let x1 = min(g - 1, x0 + 1), y1 = min(g - 1, y0 + 1)
            let fx = max(0, min(1, q.x - Float(x0))), fy = max(0, min(1, q.y - Float(y0)))
            var sum: Float = 0, weight: Float = 0
            for (x, y, w) in [(x0, y0, (1 - fx) * (1 - fy)), (x1, y0, fx * (1 - fy)), (x0, y1, (1 - fx) * fy), (x1, y1, fx * fy)] {
                let r = reference[y * g + x]
                if r.isFinite && w > 0 { sum += r * w; weight += w }
            }
            return weight > 0 ? sum / weight : reference[cellOf[t]]
        }
        var parent = [Int](repeating: -1, count: n)
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var j = i
            while parent[j] != r { let next = parent[j]; parent[j] = r; j = next }
            return r
        }
        var owner: [UInt16: Int] = [:]
        for t in 0..<n {
            let ref = streetLevel(t)
            guard ref.isFinite, m.heights[t] > ref + raised else { continue }
            parent[t] = t
            let c = m.corners[t]
            for v in [c.x, c.y, c.z] {
                if let o = owner[v] {
                    let ra = find(o), rb = find(t)
                    if ra != rb { parent[rb] = ra }
                } else {
                    owner[v] = t
                }
            }
        }
        var compArea: [Int: Float] = [:], compRoad: [Int: Float] = [:]
        for t in 0..<n where parent[t] >= 0 {
            let r = find(t)
            compArea[r, default: 0] += area[t]
            if m.surfaces[t] == .road { compRoad[r, default: 0] += area[t] }
        }
        let rg = Int(tileSize / roadCell)
        var nearRoad = [Bool](repeating: false, count: rg * rg)
        func cell(_ v: Float) -> Int { max(0, min(rg - 1, Int(v / roadCell))) }
        for t in 0..<n where parent[t] >= 0 {
            let r = find(t)
            let keep = (compRoad[r] ?? 0) >= (compArea[r] ?? 0) * overpassRoadShare
            out[t] = keep ? .raised : .hidden
            guard keep, m.surfaces[t] == .road else { continue }
            let a = m.positions[3 * t], b = m.positions[3 * t + 1], c = m.positions[3 * t + 2]
            let lo = simd_min(simd_min(a, b), c) - roadReach, hi = simd_max(simd_max(a, b), c) + roadReach
            for y in cell(lo.y)...cell(hi.y) {
                for x in cell(lo.x)...cell(hi.x) { nearRoad[y * rg + x] = true }
            }
        }
        for t in 0..<n where out[t] == .raised {
            let cen = (m.positions[3 * t] + m.positions[3 * t + 1] + m.positions[3 * t + 2]) / 3
            if m.surfaces[t] == .road || nearRoad[cell(cen.y) * rg + cell(cen.x)] { out[t] = .overpass }
        }
        return out
    }
}
