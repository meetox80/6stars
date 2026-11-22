import Foundation
import RPFKit
import simd

struct Node {
    var row0: SIMD4<Float>
    var row1: SIMD4<Float>
    var row2: SIMD4<Float>
    var center: SIMD3<Float>
    var radius: Float
    var bcenter: SIMD3<Float>
    var bradius: Float
    var lodDist: Float
    var childLodDist: Float
    var drawable: Int32
    var firstChild: Int32
    var childCount: Int32
    var level: UInt8
}

struct Grid {
    let cell: Float
    var cells: [SIMD2<Int32>: [Int32]] = [:]

    init(cell: Float) { self.cell = cell }

    func key(_ p: SIMD3<Float>) -> SIMD2<Int32> { SIMD2(Int32(floor(p.x / cell)), Int32(floor(p.y / cell))) }

    mutating func insert(_ i: Int32, at p: SIMD3<Float>) { cells[key(p), default: []].append(i) }

    func query(_ p: SIMD3<Float>, radius: Float, _ body: (Int32) -> Void) {
        let lo = key(p - SIMD3(radius, radius, 0)), hi = key(p + SIMD3(radius, radius, 0))
        for y in lo.y...hi.y {
            for x in lo.x...hi.x {
                if let c = cells[SIMD2(x, y)] { for i in c { body(i) } }
            }
        }
    }
}

final class Scene {
    let catalog: Catalog
    let index: ArchiveIndex
    let file: MappedFile
    let world: WorldData
    var nodes: [Node] = []
    var children: [Int32] = []
    var roots: [Int32] = []
    var grids: [Grid] = []
    let gridLimits: [Float] = [600, 4000, 30000]
    var entityCount = 0
    var matched = 0
    var invertRotation = true
    let lodDistanceScale = Float(ProcessInfo.processInfo.environment["MV_LODDIST"] ?? "") ?? 3

    init(catalog: Catalog, index: ArchiveIndex, file: MappedFile, world: WorldData) {
        self.catalog = catalog
        self.index = index
        self.file = file
        self.world = world
        entityCount = world.entities.count
        rebuild()
    }

    func rebuild() {
        let ents = world.entities
        nodes.removeAll(keepingCapacity: true)
        nodes.reserveCapacity(ents.count)
        matched = 0
        var childLists = [[Int32]](repeating: [], count: ents.count)
        for (i, e) in ents.enumerated() where e.parent >= 0 && Int(e.parent) < ents.count && Int(e.parent) != i {
            childLists[Int(e.parent)].append(Int32(i))
        }
        for e in ents {
            var q = e.rotation
            if simd_length(q) < 0.5 || !q.x.isFinite { q = SIMD4(0, 0, 0, 1) }
            q = simd_normalize(q)
            if invertRotation { q = SIMD4(-q.x, -q.y, -q.z, q.w) }
            let r = simd_matrix3x3(simd_quatf(ix: q.x, iy: q.y, iz: q.z, r: q.w))
            let sxy = e.scaleXY > 0 && e.scaleXY.isFinite ? e.scaleXY : 1
            let sz = e.scaleZ > 0 && e.scaleZ.isFinite ? e.scaleZ : 1
            let row0: SIMD4<Float>, row1: SIMD4<Float>, row2: SIMD4<Float>
            let scaleMax: Float
            if e.hasBasis {
                let b = e.basis
                row0 = SIMD4(b.r0, e.position.x)
                row1 = SIMD4(b.r1, e.position.y)
                row2 = SIMD4(b.r2, e.position.z)
                scaleMax = max(simd_length(SIMD3(b.r0.x, b.r1.x, b.r2.x)), simd_length(SIMD3(b.r0.y, b.r1.y, b.r2.y)), simd_length(SIMD3(b.r0.z, b.r1.z, b.r2.z)))
            } else {
                row0 = SIMD4(r.columns.0.x * sxy, r.columns.1.x * sxy, r.columns.2.x * sz, e.position.x)
                row1 = SIMD4(r.columns.0.y * sxy, r.columns.1.y * sxy, r.columns.2.y * sz, e.position.y)
                row2 = SIMD4(r.columns.0.z * sxy, r.columns.1.z * sxy, r.columns.2.z * sz, e.position.z)
                scaleMax = max(sxy, sz)
            }
            func xf(_ c: SIMD3<Float>) -> SIMD3<Float> {
                SIMD3(simd_dot(SIMD3(row0.x, row0.y, row0.z), c) + row0.w, simd_dot(SIMD3(row1.x, row1.y, row1.z), c) + row1.w,
                      simd_dot(SIMD3(row2.x, row2.y, row2.z), c) + row2.w)
            }
            let arch = world.archetypes[e.archetype]
            var drawable: Int32 = e.archetype == 0 ? -2 : (catalog.byHash[e.archetype].map { catalog.entries[$0].lodClass == LodClass.hidden ? -2 : -1 } ?? -1)
            var localCenter = arch?.center ?? .zero
            var radius = arch?.radius ?? 0
            var cls = Int(min(e.lodLevel, 2))
            if let di = catalog.byHash[e.archetype] {
                let c = catalog.entries[di]
                if c.lodClass != LodClass.hidden {
                    drawable = Int32(di)
                    matched += 1
                    if c.radius.isFinite && c.radius > 0 && c.radius < 20000 {
                        localCenter = c.center
                        radius = c.radius
                    }
                    if e.lodLevel == 0 { cls = Int(min(c.lodClass, 2)) }
                }
            }
            if !radius.isFinite || radius <= 0 || radius > 20000 { radius = 10 }
            radius *= scaleMax
            let fallback: [Float] = [max(350, radius * 12), max(3000, radius * 8), 16000]
            var lod = e.lodDist
            if !(lod > 0), let a = arch, a.lodDist > 0 { lod = a.lodDist }
            if !(lod > 0) { lod = fallback[cls] }
            let wc = xf(localCenter)
            nodes.append(Node(row0: row0, row1: row1, row2: row2, center: wc, radius: radius, bcenter: wc, bradius: drawable >= 0 ? radius : 0, lodDist: lod * lodDistanceScale,
                              childLodDist: e.childLodDist > 0 ? e.childLodDist * lodDistanceScale : e.childLodDist, drawable: drawable, firstChild: 0, childCount: 0, level: UInt8(cls)))
        }
        children.removeAll(keepingCapacity: true)
        roots.removeAll(keepingCapacity: true)
        for i in 0..<nodes.count {
            let list = childLists[i]
            nodes[i].firstChild = Int32(children.count)
            nodes[i].childCount = Int32(list.count)
            children.append(contentsOf: list)
            if !list.isEmpty && !(nodes[i].childLodDist > 0) {
                nodes[i].childLodDist = list.map { nodes[Int($0)].lodDist }.max() ?? 0
            }
            if ents[i].parent < 0 || Int(ents[i].parent) >= ents.count || Int(ents[i].parent) == i { roots.append(Int32(i)) }
        }
        func rank(_ l: UInt8) -> Int { l == 5 ? 0 : (l == 6 ? 5 : Int(min(l, 4))) }
        var order = Array(0..<nodes.count)
        order.sort { rank(ents[$0].lodLevel) < rank(ents[$1].lodLevel) }
        for _ in 0..<2 {
            for i in order where nodes[i].childCount > 0 {
                var c = nodes[i].bcenter, r = nodes[i].bradius
                for k in children[Int(nodes[i].firstChild)..<Int(nodes[i].firstChild + nodes[i].childCount)] {
                    let n = nodes[Int(k)]
                    guard n.bradius > 0 else { continue }
                    if r <= 0 {
                        c = n.bcenter
                        r = n.bradius
                        continue
                    }
                    let d = simd_distance(c, n.bcenter)
                    if d + n.bradius <= r { continue }
                    if d + r <= n.bradius {
                        c = n.bcenter
                        r = n.bradius
                        continue
                    }
                    let nr = (d + r + n.bradius) * 0.5
                    c += (n.bcenter - c) * ((nr - r) / d)
                    r = nr
                }
                nodes[i].bcenter = c
                nodes[i].bradius = r
            }
        }
        grids = [Grid(cell: 128), Grid(cell: 1024), Grid(cell: 4096)]
        for r in roots {
            let n = nodes[Int(r)]
            guard n.bradius > 0 else { continue }
            let reach = max(n.lodDist, n.childLodDist) + n.bradius
            let g = reach <= gridLimits[0] ? 0 : (reach <= gridLimits[1] ? 1 : 2)
            grids[g].insert(r, at: n.bcenter)
        }
    }
}
