import Foundation
import RPFKit
import simd

struct PointVertex {
    var x: Float
    var y: Float
    var z: Float
    var color: UInt32
}

struct World {
    var lines: [PointVertex] = []
    var heights: HeightField?
    var focus: SIMD2<Float>?
    var scene: Scene
    var textures: TextureDB

    static func pack(_ c: SIMD3<Float>, _ a: Float = 1) -> UInt32 {
        let r = UInt32(max(0, min(1, c.x)) * 255)
        let g = UInt32(max(0, min(1, c.y)) * 255)
        let b = UInt32(max(0, min(1, c.z)) * 255)
        let al = UInt32(max(0, min(1, a)) * 255)
        return r | g << 8 | b << 16 | al << 24
    }

    static func load(archive: String, indexPath: String, status: @escaping (String) -> Void) throws -> World {
        status("Opening \(archive)")
        let file = try MappedFile(path: archive)
        let dir = (indexPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let index: ArchiveIndex
        status("Reading index")
        if let existing = try? ArchiveIndex.read(from: indexPath) {
            index = existing
        } else {
            status("Scanning archive (first run, about a minute)")
            index = ArchiveIndex.scan(file) { d, n in status("Scanning archive: \(d * 100 / n)%") }
            try index.write(to: indexPath)
        }
        let catalogPath = "\(dir)/catalog.bin"
        let catalog: Catalog
        if let c = try? Catalog.read(from: catalogPath) {
            catalog = c
        } else {
            status("Cataloguing drawables (first run)")
            catalog = Catalog.build(index: index, file: file) { d, n in status("Cataloguing drawables: \(d * 100 / n)%") }
            try? catalog.write(to: catalogPath)
        }
        let worldPath = "\(dir)/world-v7.bin"
        let worldData: WorldData
        if let w = try? WorldData.read(from: worldPath) {
            worldData = w
        } else {
            status("Reading map entities and archetypes (first run)")
            worldData = WorldData.load(sources: [(index, file)], progress: status)
            let ps = worldData.parentStats
            status("LOD hierarchy: \(ps.resolved) of \(ps.maps) child maps linked, \(ps.childLinks) links, \(ps.exact) parents with exact child counts")
            print("LOD hierarchy: \(ps.resolved) of \(ps.maps) child maps linked, \(ps.childLinks) links, \(ps.exact) parents with exact child counts, \(WorldData.unlisted.value) entities outside entity lists, vegetation batches \(WorldData.batchStats.batches) → \(WorldData.batchStats.instances) instances, \(WorldData.batchStats.unresolved) unresolved")
            try? worldData.write(to: worldPath)
        }
        status("Decoding terrain heightmap")
        let heights = HeightField.load(index: index, file: file)
        status("Indexing texture databases")
        let home = NSHomeDirectory()
        let textures = TextureDB(roots: ["\(home)/testing/data/ttdb", "\(home)/testing/pack"], aliasArchive: ("\(home)/testing/textures.rpf", "\(home)/testing/6stars-data/textures.idx"))
        status("Placing \(worldData.entities.count) entities")
        var w = World(scene: Scene(catalog: catalog, index: index, file: file, world: worldData), textures: textures)
        w.heights = heights
        w.focus = heights?.densestTallArea()
        w.buildGrid()
        return w
    }

    mutating func buildGrid() {
        guard let hf = heights else { return }
        let step: Float = 1000
        let x0 = floor(hf.origin.x / step) * step, y0 = floor(hf.origin.y / step) * step
        let x1 = ceil((hf.origin.x + Float(hf.width) * hf.cell) / step) * step
        let y1 = ceil((hf.origin.y + Float(hf.height) * hf.cell) / step) * step
        let minor = World.pack(SIMD3(0.20, 0.24, 0.28), 0.35)
        let major = World.pack(SIMD3(0.35, 0.40, 0.46), 0.6)
        var x = x0
        while x <= x1 {
            let c = Int(x) % 5000 == 0 ? major : minor
            lines.append(PointVertex(x: x, y: y0, z: 0, color: c))
            lines.append(PointVertex(x: x, y: y1, z: 0, color: c))
            x += step
        }
        var y = y0
        while y <= y1 {
            let c = Int(y) % 5000 == 0 ? major : minor
            lines.append(PointVertex(x: x0, y: y, z: 0, color: c))
            lines.append(PointVertex(x: x1, y: y, z: 0, color: c))
            y += step
        }
    }

    func startCamera() -> Camera {
        var cam = Camera()
        let f = focus ?? SIMD2(0, 0)
        let ground = heights?.surfaceHeight(at: f - SIMD2(0, 420)) ?? 0
        cam.position = SIMD3(f.x, f.y - 420, max(ground, 0) + 140)
        cam.yaw = .pi / 2
        cam.pitch = -0.22
        return cam
    }

    func overviewCamera() -> Camera {
        var cam = Camera()
        guard let hf = heights else { return startCamera() }
        let size = SIMD2(Float(hf.width), Float(hf.height)) * hf.cell
        let mid = hf.origin + size / 2
        cam.position = SIMD3(mid.x, mid.y - size.y * 0.62, size.y * 0.55)
        cam.yaw = .pi / 2
        cam.pitch = -0.72
        return cam
    }
}
