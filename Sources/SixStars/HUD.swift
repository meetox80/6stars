import CoreGraphics
import QuartzCore
import Foundation
import Metal
import RPFKit
import simd

struct HUDRect {
    var x: Double, y: Double, w: Double, h: Double
    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var mid: SIMD2<Double> { SIMD2(x + w / 2, y + h / 2) }
}

struct HUDLayout {
    static let designSize = SIMD2<Double>(3840, 2160)
    let styles: StyleStore
    let hidden: Set<String>
    let targets: Set<String>
    var parents: [ObjectIdentifier: RBFNode] = [:]
    var onPath: Set<ObjectIdentifier> = []

    struct Params {
        var l = 0.0, t = 0.0, r = 0.0, b = 0.0
        var width: Double?
        var height: Double?
        var wAuto = true, hAuto = true
        var h = "HALIGN_STRETCH", v = "VALIGN_STRETCH"
    }

    init(root: RBFNode, styles: StyleStore, hidden: Set<String>, targets: Set<String>) {
        self.styles = styles
        self.hidden = hidden
        self.targets = targets
        var parents: [ObjectIdentifier: RBFNode] = [:]
        var found: [RBFNode] = []
        func walk(_ n: RBFNode) {
            for k in HUDLayout.kids(n) {
                parents[ObjectIdentifier(k)] = n
                walk(k)
            }
            if let name = n.string("Name"), targets.contains(name) { found.append(n) }
        }
        walk(root)
        self.parents = parents
        var path: Set<ObjectIdentifier> = [ObjectIdentifier(root)]
        for f in found {
            var n: RBFNode? = f
            while let c = n {
                path.insert(ObjectIdentifier(c))
                n = parents[ObjectIdentifier(c)]
            }
        }
        onPath = path
    }

    static func kids(_ n: RBFNode) -> [RBFNode] {
        var out: [RBFNode] = []
        if let p = n.child("PrefabObject") { out.append(p) }
        out += n.items("Children")
        return out
    }

    static func type(_ n: RBFNode) -> String { n.type ?? n.name }

    func styleName(_ n: RBFNode) -> String? {
        if let s = n.string("Style") { return s }
        for link in n.child("BindingSet")?.items("LinkRequests") ?? [] where link.child("MemberPath")?.string("Path") == "Style" {
            if let d = link.child("Converter")?.string("Default") { return d }
        }
        return nil
    }

    func params(_ n: RBFNode) -> Params {
        var p = Params()
        if let name = styleName(n), let s = styles.layout(name) {
            if let v = s.number("leftMargin") { p.l = v }
            if let v = s.number("topMargin") { p.t = v }
            if let v = s.number("rightMargin") { p.r = v }
            if let v = s.number("bottomMargin") { p.b = v }
            p.width = s.number("width")
            p.height = s.number("height")
            if let m = s.number("widthContentMode") { p.wAuto = m != 0 }
            if let m = s.number("heightContentMode") { p.hAuto = m != 0 }
        }
        if let lp = n.child("LayoutParams") {
            if let v = lp.number("leftMargin") { p.l = v }
            if let v = lp.number("topMargin") { p.t = v }
            if let v = lp.number("rightMargin") { p.r = v }
            if let v = lp.number("bottomMargin") { p.b = v }
            if let v = lp.number("width") { p.width = v }
            if let v = lp.number("height") { p.height = v }
            if let m = lp.string("widthContentMode") { p.wAuto = m != "CONTENT_MODE_RAW" }
            if let m = lp.string("heightContentMode") { p.hAuto = m != "CONTENT_MODE_RAW" }
            if let a = lp.string("horizontalAlignment") { p.h = a }
            if let a = lp.string("verticalAlignment") { p.v = a }
        }
        if p.width == nil { p.wAuto = true }
        if p.height == nil { p.hAuto = true }
        return p
    }

    func collapsed(_ n: RBFNode) -> Bool {
        if n.flag("Visible") == false { return true }
        if let name = n.string("Name"), hidden.contains(name) { return true }
        return false
    }

    func visibleKids(_ n: RBFNode) -> [RBFNode] { HUDLayout.kids(n).filter { !collapsed($0) } }

    func horizontal(_ n: RBFNode) -> Bool {
        n.child("SpecializedLayoutParams")?.string("orientation") == "PANEL_ORIENT_HORIZONTAL"
    }

    func padding(_ n: RBFNode) -> Double { n.child("SpecializedLayoutParams")?.number("padding") ?? 0 }

    func measure(_ n: RBFNode) -> SIMD2<Double> {
        if collapsed(n) { return .zero }
        let p = params(n)
        if !p.wAuto, !p.hAuto, let w = p.width, let h = p.height { return SIMD2(w, h) }
        var content = SIMD2<Double>(0, 0)
        let kids = visibleKids(n)
        if HUDLayout.type(n) == "rage__fwuiStackPanel" {
            let hz = horizontal(n)
            for (i, k) in kids.enumerated() {
                let kp = params(k)
                let s = measure(k) + SIMD2(kp.l + kp.r, kp.t + kp.b)
                if hz {
                    content.x += s.x + (i > 0 ? padding(n) : 0)
                    content.y = max(content.y, s.y)
                } else {
                    content.y += s.y + (i > 0 ? padding(n) : 0)
                    content.x = max(content.x, s.x)
                }
            }
        } else {
            for k in kids {
                let kp = params(k)
                content = simd_max(content, measure(k) + SIMD2(kp.l + kp.r, kp.t + kp.b))
            }
        }
        return SIMD2(p.wAuto ? content.x : (p.width ?? content.x), p.hAuto ? content.y : (p.height ?? content.y))
    }

    func place(_ n: RBFNode, in slot: HUDRect) -> HUDRect {
        let p = params(n)
        let size = measure(n)
        let a = HUDRect(x: slot.x + p.l, y: slot.y + p.t, w: slot.w - p.l - p.r, h: slot.h - p.t - p.b)
        let w = p.h == "HALIGN_STRETCH" && p.wAuto ? a.w : size.x
        let h = p.v == "VALIGN_STRETCH" && p.hAuto ? a.h : size.y
        let x: Double
        switch p.h {
        case "HALIGN_LEFT": x = a.x
        case "HALIGN_RIGHT": x = a.maxX - w
        case "HALIGN_STRETCH" where p.wAuto: x = a.x
        default: x = a.x + (a.w - w) / 2
        }
        let y: Double
        switch p.v {
        case "VALIGN_TOP": y = a.y
        case "VALIGN_BOTTOM": y = a.maxY - h
        case "VALIGN_STRETCH" where p.hAuto: y = a.y
        default: y = a.y + (a.h - h) / 2
        }
        return HUDRect(x: x, y: y, w: w, h: h)
    }

    func arrange(_ root: RBFNode, size: SIMD2<Double>) -> [String: (HUDRect, RBFNode)] {
        var out: [String: (HUDRect, RBFNode)] = [:]
        func visit(_ n: RBFNode, _ slot: HUDRect, inside: Bool) {
            guard !collapsed(n) else { return }
            let r = place(n, in: slot)
            if let name = n.string("Name"), inside || targets.contains(name) { out[name] = (r, n) }
            let within = inside || (n.string("Name").map { targets.contains($0) } ?? false)
            let kids = visibleKids(n).filter { within || onPath.contains(ObjectIdentifier($0)) }
            if HUDLayout.type(n) == "rage__fwuiStackPanel" {
                let hz = horizontal(n)
                var cursor = hz ? r.x : r.y
                for k in visibleKids(n) {
                    let kp = params(k)
                    let s = measure(k) + SIMD2(kp.l + kp.r, kp.t + kp.b)
                    let ks = hz ? HUDRect(x: cursor, y: r.y, w: s.x, h: r.h) : HUDRect(x: r.x, y: cursor, w: r.w, h: s.y)
                    cursor += (hz ? s.x : s.y) + padding(n)
                    if kids.contains(where: { $0 === k }) { visit(k, ks, inside: within) }
                }
            } else {
                for k in kids { visit(k, r, inside: within) }
            }
        }
        visit(root, HUDRect(x: 0, y: 0, w: size.x, h: size.y), inside: false)
        return out
    }
}

struct HUDSprite {
    let texture: MTLTexture
    let size: SIMD2<Float>
}

final class HUDAssets {
    let layoutRoot: RBFNode
    let styles: StyleStore
    let arrow: TextureImage
    let disc: TextureImage
    let north: (pixels: [UInt8], width: Int, height: Int, size: SIMD2<Float>)
    let navIndex: ArchiveIndex
    let navFile: MappedFile
    let navTiles: [UInt32: [NavTileRef]]

    init(layoutRoot: RBFNode, styles: StyleStore, arrow: TextureImage, disc: TextureImage, north: (pixels: [UInt8], width: Int, height: Int, size: SIMD2<Float>),
         navIndex: ArchiveIndex, navFile: MappedFile, navTiles: [UInt32: [NavTileRef]]) {
        self.layoutRoot = layoutRoot
        self.styles = styles
        self.arrow = arrow
        self.disc = disc
        self.north = north
        self.navIndex = navIndex
        self.navFile = navFile
        self.navTiles = navTiles
    }

    static func joined(_ index: ArchiveIndex, _ file: MappedFile, from i: Int) -> [UInt8]? {
        let entries = index.entries
        guard var bytes = try? index.load(entries[i], from: file) else { return nil }
        var k = i + 1
        var last = bytes.count
        while last == 0x10000, k < entries.count, entries[k].kind == .zlib, let more = try? index.load(entries[k], from: file) {
            bytes += more
            last = more.count
            k += 1
        }
        return bytes
    }

    static func contains(_ b: [UInt8], _ s: String) -> Bool {
        let needle = Array(s.utf8)
        guard needle.count <= b.count else { return false }
        return b.withUnsafeBufferPointer { p in
            var i = 0
            while i + needle.count <= p.count {
                if p[i] == needle[0] && Array(p[i..<(i + needle.count)]) == needle { return true }
                i += 1
            }
            return false
        }
    }

    static func load(status: (String) -> Void) throws -> HUDAssets {
        let home = NSHomeDirectory()
        let dataFile = try MappedFile(path: "\(home)/testing/data.rpf")
        let dataIndex = try ArchiveIndex.read(from: "\(home)/testing/6stars-data/data.idx")
        status("HUD: reading styles")
        guard let styles = StyleStore.find(index: dataIndex, file: dataFile) else { throw RPFError.format("HUD style store not found in data.rpf") }
        status("HUD: reading layout")
        var layoutRoot: RBFNode?
        var blipMovie: GFXMovie?
        for (i, e) in dataIndex.entries.enumerated() where e.kind == .zlib && (e.magic == "RBF0" || e.magic == "GFX*") {
            if e.magic == "RBF0" && layoutRoot == nil {
                guard let b = joined(dataIndex, dataFile, from: i), contains(b, "MV_HUD"), contains(b, "PAN_MinimapContainer"),
                      let r = try? RBF.parse(b), r.string("Name") == "MV_HUD" else { continue }
                layoutRoot = r
            } else if e.magic == "GFX*" && blipMovie == nil {
                guard let b = joined(dataIndex, dataFile, from: i), GFXMovie.name(of: b) == "blip", let m = try? GFXMovie(bytes: b) else { continue }
                blipMovie = m
            }
            if layoutRoot != nil && blipMovie != nil { break }
        }
        guard let root = layoutRoot else { throw RPFError.format("MV_HUD layout not found in data.rpf") }
        guard let blip = blipMovie, let northID = blip.exports["BLIP_NORTH"] else { throw RPFError.format("blip movie with BLIP_NORTH not found") }
        status("HUD: reading blip textures")
        let texFile = try MappedFile(path: "\(home)/testing/textures.rpf")
        let texIndex = try ArchiveIndex.read(from: "\(home)/testing/6stars-data/textures.idx")
        var arrow: TextureImage?
        var disc: TextureImage?
        let want = Hash.joaat("blip_radar_center")
        for off in texIndex.resourceStarts {
            guard let seg = try? texIndex.virtualSegment(at: off, from: texFile), let ha = Resource.vptr(seg.data, 0x20), seg.data.count > 0x2A else { continue }
            let n = Int(UInt16(seg.data[0x28]) | UInt16(seg.data[0x29]) << 8)
            guard n > 0, ha + 4 * n <= seg.data.count else { continue }
            let has = seg.data.withUnsafeBytes { p in (0..<n).contains { p.loadUnaligned(fromByteOffset: ha + 4 * $0, as: UInt32.self) == want } }
            guard has, let txd = try? TextureDictionary(try texIndex.resource(at: off, from: texFile, physical: true)),
                  let i = txd.index(named: "blip_radar_center") else { continue }
            arrow = try txd.image(i)
            disc = try txd.index(named: "blip_player_bg").map { try txd.image($0) }
            break
        }
        guard let arrowImage = arrow else { throw RPFError.format("blip_radar_center not found in textures.rpf") }
        guard let discImage = disc else { throw RPFError.format("blip_player_bg not found beside blip_radar_center") }
        let north = rasterize(blip, northID)
        status("HUD: indexing navmeshes")
        let navFile = try MappedFile(path: "\(home)/testing/navmeshes.rpf")
        let navIdxPath = "\(home)/testing/6stars-data/navmeshes.idx"
        let navIndex: ArchiveIndex
        if let existing = try? ArchiveIndex.read(from: navIdxPath) {
            navIndex = existing
        } else {
            navIndex = ArchiveIndex.scan(navFile)
            try? navIndex.write(to: navIdxPath)
        }
        let tilesPath = "\(home)/testing/6stars-data/navtiles.bin"
        let refs: [NavTileRef]
        if let r = try? NavMesh.readIndex(from: tilesPath) {
            refs = r
        } else {
            refs = NavMesh.buildIndex(navIndex, file: navFile)
            try? NavMesh.writeIndex(refs, to: tilesPath)
        }
        var byArea: [UInt32: [NavTileRef]] = [:]
        for r in refs { byArea[r.area, default: []].append(r) }
        for (a, list) in byArea where list.contains(where: { !$0.isOcean }) { byArea[a] = list.filter { !$0.isOcean } }
        for (a, list) in byArea where list.count > 1 && list.allSatisfy({ $0.isOcean }) { byArea[a] = [list[0]] }
        return HUDAssets(layoutRoot: root, styles: styles, arrow: arrowImage, disc: discImage, north: north, navIndex: navIndex, navFile: navFile, navTiles: byArea)
    }

    static func rasterize(_ movie: GFXMovie, _ id: Int) -> (pixels: [UInt8], width: Int, height: Int, size: SIMD2<Float>) {
        let parts = movie.flatten(id)
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for (fill, m) in parts {
            for c in fill.contours {
                for e in c {
                    for p in [e.from, e.to] + (e.control.map { [$0] } ?? []) {
                        let q = m.apply(p)
                        lo = simd_min(lo, q)
                        hi = simd_max(hi, q)
                    }
                }
            }
        }
        let size = hi - lo
        let scale: Float = 4
        let w = max(1, Int(ceil(size.x * scale)) + 2), h = max(1, Int(ceil(size.y * scale)) + 2)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard size.x > 0, size.y > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (px, w, h, size) }
        ctx.translateBy(x: 1, y: CGFloat(h) - 1)
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
        ctx.translateBy(x: CGFloat(-lo.x), y: CGFloat(-lo.y))
        for (fill, m) in parts {
            let path = CGMutablePath()
            for c in fill.contours {
                guard let first = c.first else { continue }
                let s = m.apply(first.from)
                path.move(to: CGPoint(x: CGFloat(s.x), y: CGFloat(s.y)))
                for e in c {
                    let t = m.apply(e.to)
                    if let cp = e.control {
                        let q = m.apply(cp)
                        path.addQuadCurve(to: CGPoint(x: CGFloat(t.x), y: CGFloat(t.y)), control: CGPoint(x: CGFloat(q.x), y: CGFloat(q.y)))
                    } else {
                        path.addLine(to: CGPoint(x: CGFloat(t.x), y: CGFloat(t.y)))
                    }
                }
                path.closeSubpath()
            }
            ctx.setFillColor(CGColor(colorSpace: cs, components: [CGFloat(fill.color.x), CGFloat(fill.color.y), CGFloat(fill.color.z), CGFloat(fill.color.w)])!)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        }
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 {
            let a = Float(px[i + 3]) / 255
            for k in 0..<3 { px[i + k] = UInt8(min(255, (Float(px[i + k]) / a).rounded())) }
        }
        return (px, w, h, size)
    }
}

final class NavStreamer {
    struct Tile {
        let buffer: MTLBuffer
        let count: Int
        let origin: SIMD2<Float>
        var used: Int
    }

    let assets: HUDAssets
    let device: MTLDevice
    let heights: HeightField?
    let lock = NSLock()
    var tiles: [UInt32: [Tile]] = [:]
    var pending: Set<UInt32> = []
    let queue = DispatchQueue(label: "hud.navmesh", qos: .utility, attributes: .concurrent)
    let slots = DispatchSemaphore(value: 4)
    static let capacity = 160

    init(assets: HUDAssets, device: MTLDevice, heights: HeightField?) {
        self.assets = assets
        self.device = device
        self.heights = heights
    }

    func request(_ areas: [UInt32], frame: Int) {
        lock.lock()
        let missing = areas.filter { tiles[$0] == nil && !pending.contains($0) && assets.navTiles[$0] != nil }
        for a in areas where tiles[a] != nil {
            tiles[a] = tiles[a]!.map { var t = $0; t.used = frame; return t }
        }
        missing.forEach { pending.insert($0) }
        if tiles.count > NavStreamer.capacity {
            let keep = Set(areas)
            let old = tiles.filter { !keep.contains($0.key) }.sorted { ($0.value.first?.used ?? 0) < ($1.value.first?.used ?? 0) }
            for (a, _) in old.prefix(tiles.count - NavStreamer.capacity) { tiles[a] = nil }
        }
        lock.unlock()
        for a in missing {
            queue.async { [self] in
                slots.wait()
                defer { slots.signal() }
                let built = build(a)
                lock.lock()
                tiles[a] = built
                pending.remove(a)
                lock.unlock()
            }
        }
    }

    func waitIdle() {
        while true {
            lock.lock()
            let busy = !pending.isEmpty
            lock.unlock()
            if !busy { return }
            usleep(20_000)
        }
    }

    func ready(_ areas: [UInt32]) -> [Tile] {
        lock.lock()
        defer { lock.unlock() }
        return areas.flatMap { tiles[$0] ?? [] }
    }

    func build(_ area: UInt32) -> [Tile] {
        var out: [Tile] = []
        for ref in assets.navTiles[area] ?? [] {
            guard let r = try? assets.navIndex.resource(at: ref.offset, from: assets.navFile, physical: false),
                  let mesh = try? NavMesh.decode(r, area: area, ocean: ref.isOcean) else { continue }
            let levels = NavMesh.levels(mesh)
            var verts: [Float] = []
            verts.reserveCapacity(mesh.surfaces.count * 9)
            for level in [NavLevel.street, .raised, .overpass] {
                for t in mesh.surfaces.indices where levels[t] == level {
                    let s = level == .overpass ? NavSurface.road : mesh.surfaces[t]
                    for k in 0..<3 {
                        let p = mesh.positions[3 * t + k]
                        verts.append(p.x)
                        verts.append(p.y)
                        verts.append(Float(bitPattern: UInt32(s.rawValue)))
                    }
                }
            }
            guard !verts.isEmpty, let b = device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared) else { continue }
            out.append(Tile(buffer: b, count: verts.count / 3, origin: mesh.origin, used: 0))
        }
        return out
    }
}

struct HudRectGPU {
    var rect: SIMD4<Float>
    var viewport: SIMD2<Float>
    var rotation: Float
    var pad: Float = 0
}

struct HudPanelGPU {
    var rect: SIMD4<Float>
    var viewport: SIMD2<Float>
    var radius: Float
    var borderWidth: Float
    var border: SIMD4<Float>
}

struct HudMapViewGPU {
    var camera: SIMD4<Float>
    var viewForward: SIMD4<Float>
    var viewUp: SIMD4<Float>
    var proj: SIMD4<Float>
    var haze: SIMD4<Float>
}

struct HudMapParamsGPU {
    var offset: SIMD2<Float>
    var forward: SIMD2<Float>
    var right: SIMD2<Float>
    var view: HudMapViewGPU
    var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
}

struct HudMapGroundGPU {
    var player: SIMD4<Float>
    var basis: SIMD4<Float>
    var field: SIMD4<Float>
    var size: SIMD4<Float>
    var water: SIMD4<Float>
    var land: SIMD4<Float>
}

struct MapProjection {
    let camera: SIMD3<Float>
    let forward: SIMD3<Float>
    let up: SIMD3<Float>
    let tanX: Float
    let tanY: Float
    let playerDepth: Float

    init(metresPerPixel mpp: Float, width: Float, height: Float) {
        tanY = tan(HUD.mapFov / 2)
        tanX = tanY * width / max(height, 1)
        forward = SIMD3(0, sin(HUD.mapTilt), -cos(HUD.mapTilt))
        up = SIMD3(0, cos(HUD.mapTilt), sin(HUD.mapTilt))
        let dir = simd_normalize(forward + up * ((1 - 2 * HUD.playerRow) * tanY))
        playerDepth = mpp * height / (2 * tanY)
        camera = -dir * (playerDepth / simd_dot(dir, forward))
    }

    func ground(_ ndc: SIMD2<Float>) -> SIMD2<Float>? {
        let d = forward + SIMD3(ndc.x * tanX, 0, 0) + up * (ndc.y * tanY)
        guard d.z < -1e-4 else { return nil }
        let p = camera + d * (-camera.z / d.z)
        return SIMD2(p.x, p.y)
    }

    func depth(_ local: SIMD2<Float>) -> Float { simd_dot(SIMD3(local.x, local.y, 0) - camera, forward) }

    func screen(_ local: SIMD2<Float>) -> SIMD2<Float> {
        let q = SIMD3(local.x, local.y, 0) - camera
        let z = max(simd_dot(q, forward), 1e-3)
        return SIMD2(q.x / (z * tanX), simd_dot(q, up) / (z * tanY))
    }

    func gpu(hazeRange: Float) -> HudMapViewGPU {
        HudMapViewGPU(camera: SIMD4(camera, 0), viewForward: SIMD4(forward, 0), viewUp: SIMD4(up, 0),
                      proj: SIMD4(tanX, tanY, playerDepth, max(hazeRange, 1)), haze: HUD.mapHaze)
    }
}

final class HUD {
    let device: MTLDevice
    let downPipe: MTLRenderPipelineState
    let blurPipe: MTLRenderPipelineState
    let mapPipe: MTLRenderPipelineState
    let mapGroundPipe: MTLRenderPipelineState
    let minimapPipe: MTLRenderPipelineState
    let spritePipe: MTLRenderPipelineState
    let discPipe: MTLRenderPipelineState

    struct Loaded {
        let assets: HUDAssets
        let streamer: NavStreamer
        let arrow: HUDSprite?
        let disc: HUDSprite?
        let north: HUDSprite?
        let heights: MTLTexture?
        let field: SIMD4<Float>
    }

    private let loadLock = NSLock()
    private var loaded: Loaded?
    private var loading = false
    private let group = DispatchGroup()

    var current: Loaded? {
        loadLock.lock()
        defer { loadLock.unlock() }
        return loaded
    }

    var blurA: MTLTexture?
    var blurB: MTLTexture?
    var mapTexture: MTLTexture?
    var mapSamples: MTLTexture?
    static let mapSampleCount = 4
    var frame = 0
    var lastPosition: SIMD3<Float>?
    var lastTime = CACurrentMediaTime()
    var zoom: Float = 1

    struct Geometry {
        var viewport: SIMD2<Float>
        var mask: HUDRect
        var radar: HUDRect
        var gutter: HUDRect
        var radius: Double
        var scale: Double
    }
    var geometry: Geometry?

    static let metresPerUnit: Float = 0.35
    static let blipSize: Float = 64
    static func linear(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(c.x <= 0.04045 ? c.x / 12.92 : pow((c.x + 0.055) / 1.055, 2.4),
              c.y <= 0.04045 ? c.y / 12.92 : pow((c.y + 0.055) / 1.055, 2.4),
              c.z <= 0.04045 ? c.z / 12.92 : pow((c.z + 0.055) / 1.055, 2.4))
    }
    static let mapTilt: Float = 45 * .pi / 180
    static let mapFov: Float = 40 * .pi / 180
    static let playerRow: Float = 0.79
    static let noHeight: Float = -1000
    static let waterSurfaceTolerance: Float = 3
    static let seabedDepth: Float = 1.5
    static let mapLand = SIMD4(linear(SIMD3(0.37, 0.39, 0.41)), 0.9)
    static let mapWater = SIMD4(linear(SIMD3(0.39, 0.54, 0.56)), 0.92)
    static let mapHaze = SIMD4(linear(SIMD3(0.55, 0.56, 0.56)), 0.35)
    static let surfaceColors: [SIMD4<Float>] = [
        SIMD4(linear(SIMD3(0.42, 0.44, 0.435)), 0.9),
        SIMD4(linear(SIMD3(0.53, 0.525, 0.49)), 0.92),
        SIMD4(linear(SIMD3(0.66, 0.645, 0.585)), 0.95),
        mapWater,
    ]
    static let panelBorder = SIMD4(linear(SIMD3(0.88, 0.85, 0.8)), 0.55)
    static let panelBorderWidth: Float = 2
    static let discScale: Float = 0.72
    static let discFill = SIMD4(linear(SIMD3(0.12, 0.12, 0.13)), 0.95)
    static let discRim = SIMD4(linear(SIMD3(0.86, 0.86, 0.86)), 1)

    static func heightTexture(_ device: MTLDevice, _ hf: HeightField) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: hf.width, height: hf.height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var px = [Float16](repeating: Float16(HUD.noHeight), count: hf.width * hf.height * 2)
        for i in 0..<(hf.width * hf.height) {
            if hf.surface[i].isFinite { px[2 * i] = Float16(hf.surface[i]) }
            if hf.ground[i].isFinite { px[2 * i + 1] = Float16(hf.ground[i]) }
        }
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, hf.width, hf.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: hf.width * 4) }
        return t
    }

    init(device: MTLDevice, library: MTLLibrary, colorFormat: MTLPixelFormat) throws {
        self.device = device
        func fn(_ n: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: n) else { throw RendererError.setup("missing shader \(n)") }
            return f
        }
        func pipe(_ vs: String, _ fs: String, _ format: MTLPixelFormat, blend: Bool, samples: Int = 1) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try fn(vs)
            d.fragmentFunction = try fn(fs)
            d.rasterSampleCount = samples
            d.colorAttachments[0].pixelFormat = format
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        downPipe = try pipe("quadVertex", "hudDown", .rgba16Float, blend: false)
        blurPipe = try pipe("quadVertex", "hudBlur", .rgba16Float, blend: false)
        mapPipe = try pipe("hudMapVertex", "hudMapFragment", .rgba8Unorm, blend: false, samples: HUD.mapSampleCount)
        mapGroundPipe = try pipe("quadVertex", "hudMapGroundFragment", .rgba8Unorm, blend: false, samples: HUD.mapSampleCount)
        minimapPipe = try pipe("hudRectVertex", "hudMinimapFragment", colorFormat, blend: true)
        spritePipe = try pipe("hudRectVertex", "hudSpriteFragment", colorFormat, blend: true)
        discPipe = try pipe("hudRectVertex", "hudDiscFragment", colorFormat, blend: true)
    }

    func start(heights: HeightField?) {
        loadLock.lock()
        let begin = !loading && loaded == nil
        loading = true
        loadLock.unlock()
        guard begin else { return }
        DispatchQueue.global(qos: .utility).async(group: group) { [self] in
            do {
                let a = try HUDAssets.load { print($0) }
                let s = NavStreamer(assets: a, device: device, heights: heights)
                let arrow = GPUTexture.make(device, a.arrow).map { HUDSprite(texture: $0, size: SIMD2(repeating: HUD.blipSize)) }
                let disc = GPUTexture.make(device, a.disc).map { HUDSprite(texture: $0, size: SIMD2(repeating: HUD.blipSize * HUD.discScale)) }
                let north = makeTexture(a.north.pixels, a.north.width, a.north.height).map { HUDSprite(texture: $0, size: a.north.size) }
                let field = heights.map { SIMD4($0.origin.x, $0.origin.y, 1 / $0.cell, 0) } ?? SIMD4<Float>(0, 0, 1, 0)
                let ht = heights.flatMap { HUD.heightTexture(device, $0) }
                loadLock.lock()
                loaded = Loaded(assets: a, streamer: s, arrow: arrow, disc: disc, north: north, heights: ht, field: field)
                loadLock.unlock()
            } catch {
                print("HUD unavailable: \(error)")
            }
        }
    }

    func waitForAssets() { group.wait() }

    func makeTexture(_ px: [UInt8], _ w: Int, _ h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        return t
    }

    func layout(_ viewport: SIMD2<Float>) -> Geometry? {
        if let g = geometry, g.viewport == viewport { return g }
        guard let a = current?.assets else { return nil }
        let s = min(Double(viewport.x) / HUDLayout.designSize.x, Double(viewport.y) / HUDLayout.designSize.y)
        let size = SIMD2(Double(viewport.x), Double(viewport.y)) / s
        let l = HUDLayout(root: a.layoutRoot, styles: a.styles, hidden: ["GRD_Location_And_Vehicle_Name", "PAN_DirectionalIndicatorContainer"],
                          targets: ["PAN_MinimapContainer"])
        let rects = l.arrange(a.layoutRoot, size: size)
        guard let mask = rects["RECT_Blur_Mask"], let radar = rects["Minimap"], let gutter = rects["BLIP_GUTTER"] else { return nil }
        let radius = mask.1.child("RadiusProperties")?.number("RadiusX") ?? 0
        let g = Geometry(viewport: viewport, mask: mask.0, radar: radar.0, gutter: gutter.0, radius: radius, scale: s)
        geometry = g
        return g
    }

    func pixels(_ r: HUDRect, _ s: Double) -> SIMD4<Float> {
        SIMD4(Float(r.x * s), Float(r.y * s), Float(r.w * s), Float(r.h * s))
    }

    func ensureTextures(_ viewport: SIMD2<Float>, _ g: Geometry) {
        let bw = max(1, Int(viewport.x) / 4), bh = max(1, Int(viewport.y) / 4)
        if blurA?.width != bw || blurA?.height != bh {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: bw, height: bh, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            blurA = device.makeTexture(descriptor: d)
            blurB = device.makeTexture(descriptor: d)
        }
        let m = pixels(g.mask, g.scale)
        let mw = max(1, Int(m.z.rounded())), mh = max(1, Int(m.w.rounded()))
        if mapTexture?.width != mw || mapTexture?.height != mh {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: mw, height: mh, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            mapTexture = device.makeTexture(descriptor: d)
            let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: mw, height: mh, mipmapped: false)
            md.textureType = .type2DMultisample
            md.sampleCount = HUD.mapSampleCount
            md.usage = .renderTarget
            md.storageMode = .memoryless
            mapSamples = device.makeTexture(descriptor: md)
        }
    }

    func fullscreen(_ cmd: MTLCommandBuffer, _ target: MTLTexture, _ pipe: MTLRenderPipelineState, _ body: (MTLRenderCommandEncoder) -> Void) {
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = target
        p.colorAttachments[0].loadAction = .dontCare
        p.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
        enc.setRenderPipelineState(pipe)
        body(enc)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    func updateZoom(_ camera: Camera, heights: HeightField?, settle: Bool = false) {
        let now = CACurrentMediaTime()
        let dt = Float(max(1e-3, min(0.25, now - lastTime)))
        lastTime = now
        let speed = settle ? 0 : (lastPosition.map { simd_length(camera.position - $0) / dt } ?? 0)
        lastPosition = camera.position
        let ground = heights?.groundHeight(at: SIMD2(camera.position.x, camera.position.y)) ?? 0
        let altitude = max(0, camera.position.z - ground)
        let fromAltitude: Float = max(0, altitude - 40) / 160
        let fromSpeed: Float = min(speed, 240) / 80
        let target: Float = min(4, 1 + fromAltitude + fromSpeed)
        zoom = settle ? target : zoom + (target - zoom) * (1 - exp(-dt * 2))
    }

    func areas(from lo: SIMD2<Float>, to hi: SIMD2<Float>) -> [UInt32] {
        var out: [UInt32] = []
        var y = (lo.y / NavMesh.tileSize).rounded(.down) * NavMesh.tileSize
        while y <= hi.y {
            var x = (lo.x / NavMesh.tileSize).rounded(.down) * NavMesh.tileSize
            while x <= hi.x {
                if let a = NavMesh.area(at: SIMD2(x + 1, y + 1)) { out.append(a) }
                x += NavMesh.tileSize
            }
            y += NavMesh.tileSize
        }
        return out
    }

    func prepare(_ cmd: MTLCommandBuffer, source: MTLTexture, camera: Camera, viewport: SIMD2<Float>, waterLevel: Float, settle: Bool = false) {
        guard let loaded = current, let g = layout(viewport) else { return }
        let streamer = loaded.streamer
        frame += 1
        ensureTextures(viewport, g)
        guard let blurA = blurA, let blurB = blurB, let map = mapTexture, let samples = mapSamples else { return }
        fullscreen(cmd, blurA, downPipe) { enc in
            enc.setFragmentTexture(source, index: 0)
        }
        for _ in 0..<2 {
            var h = SIMD2<Float>(1.5 / Float(blurA.width), 0)
            fullscreen(cmd, blurB, blurPipe) { enc in
                enc.setFragmentTexture(blurA, index: 0)
                enc.setFragmentBytes(&h, length: 8, index: 0)
            }
            var v = SIMD2<Float>(0, 1.5 / Float(blurA.height))
            fullscreen(cmd, blurA, blurPipe) { enc in
                enc.setFragmentTexture(blurB, index: 0)
                enc.setFragmentBytes(&v, length: 8, index: 0)
            }
        }
        updateZoom(camera, heights: streamer.heights, settle: settle)
        let metresPerPixel = HUD.metresPerUnit * zoom / Float(g.scale)
        let cam = SIMD2(camera.position.x, camera.position.y)
        let fwd = SIMD2(cos(camera.yaw), sin(camera.yaw))
        let right = SIMD2(sin(camera.yaw), -cos(camera.yaw))
        let view = MapProjection(metresPerPixel: metresPerPixel, width: Float(map.width), height: Float(map.height))
        var lo = cam, hi = cam
        var far = view.playerDepth
        for corner in [SIMD2<Float>(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(1, 1)] {
            guard let gp = view.ground(corner) else { continue }
            let w = cam + right * gp.x + fwd * gp.y
            lo = simd_min(lo, w)
            hi = simd_max(hi, w)
            far = max(far, view.depth(gp))
        }
        let areas = areas(from: lo, to: hi)
        streamer.request(areas, frame: frame)
        if settle { streamer.waitIdle() }
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = samples
        p.colorAttachments[0].resolveTexture = map
        p.colorAttachments[0].loadAction = .clear
        p.colorAttachments[0].storeAction = .multisampleResolve
        let bg = HUD.mapLand
        p.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: Double(bg.w))
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
        enc.setCullMode(.none)
        var gpuView = view.gpu(hazeRange: far - view.playerDepth)
        if let heights = loaded.heights {
            var ground = HudMapGroundGPU(player: SIMD4(cam.x, cam.y, waterLevel + HUD.waterSurfaceTolerance, waterLevel - HUD.seabedDepth),
                                         basis: SIMD4(right.x, right.y, fwd.x, fwd.y),
                                         field: loaded.field, size: SIMD4(Float(map.width), Float(map.height), view.tanX, view.tanY),
                                         water: HUD.mapWater, land: HUD.mapLand)
            enc.setRenderPipelineState(mapGroundPipe)
            enc.setFragmentBytes(&gpuView, length: MemoryLayout<HudMapViewGPU>.stride, index: 0)
            enc.setFragmentBytes(&ground, length: MemoryLayout<HudMapGroundGPU>.stride, index: 1)
            enc.setFragmentTexture(heights, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.setRenderPipelineState(mapPipe)
        let c = HUD.surfaceColors
        for t in streamer.ready(areas) {
            var params = HudMapParamsGPU(offset: t.origin - cam, forward: fwd, right: right, view: gpuView, colors: (c[0], c[1], c[2], c[3]))
            enc.setVertexBuffer(t.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&params, length: MemoryLayout<HudMapParamsGPU>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: t.count)
        }
        enc.endEncoding()
        let north = SIMD2(right.y, fwd.y) * (0.02 * view.playerDepth)
        let d = (view.screen(north) - view.screen(.zero)) * SIMD2(Float(map.width), -Float(map.height))
        if simd_length(d) > 1e-6 { northDir = simd_normalize(d) }
    }

    var northDir = SIMD2<Float>(0, -1)

    func draw(_ enc: MTLRenderCommandEncoder, atmos a: inout AtmosGPU, exposure: MTLBuffer, bloom: MTLTexture?) {
        guard let loaded = current, let g = geometry, let blur = blurA, let map = mapTexture else { return }
        let s = g.scale
        let vp = g.viewport
        var panel = HudPanelGPU(rect: pixels(g.mask, s), viewport: vp, radius: Float(g.radius * s),
                                borderWidth: HUD.panelBorderWidth * Float(s), border: HUD.panelBorder)
        var rect = HudRectGPU(rect: panel.rect, viewport: vp, rotation: 0)
        enc.setRenderPipelineState(minimapPipe)
        enc.setVertexBytes(&rect, length: MemoryLayout<HudRectGPU>.stride, index: 0)
        enc.setFragmentBytes(&panel, length: MemoryLayout<HudPanelGPU>.stride, index: 0)
        enc.setFragmentBytes(&a, length: MemoryLayout<AtmosGPU>.stride, index: 1)
        enc.setFragmentBuffer(exposure, offset: 0, index: 2)
        enc.setFragmentTexture(blur, index: 0)
        enc.setFragmentTexture(map, index: 1)
        enc.setFragmentTexture(bloom ?? blur, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.setRenderPipelineState(spritePipe)
        let player = SIMD2(g.mask.x + g.mask.w * 0.5, g.mask.y + g.mask.h * Double(HUD.playerRow))
        if let d = loaded.disc {
            enc.setRenderPipelineState(discPipe)
            var colours = (HUD.discFill, HUD.discRim)
            let sz = d.size * Float(s)
            var r = HudRectGPU(rect: SIMD4(Float(player.x * s) - sz.x / 2, Float(player.y * s) - sz.y / 2, sz.x, sz.y), viewport: vp, rotation: 0)
            enc.setVertexBytes(&r, length: MemoryLayout<HudRectGPU>.stride, index: 0)
            enc.setFragmentBytes(&colours, length: MemoryLayout<(SIMD4<Float>, SIMD4<Float>)>.stride, index: 0)
            enc.setFragmentTexture(d.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.setRenderPipelineState(spritePipe)
        }
        if let a = loaded.arrow {
            sprite(enc, a, at: player, rotation: 0, g)
        }
        if let n = loaded.north {
            let dir = SIMD2(Double(northDir.x), Double(northDir.y))
            let gw = g.gutter.w / 2, gh = g.gutter.h / 2
            let t = min(abs(dir.x) > 1e-6 ? gw / abs(dir.x) : .greatestFiniteMagnitude, abs(dir.y) > 1e-6 ? gh / abs(dir.y) : .greatestFiniteMagnitude)
            sprite(enc, n, at: g.gutter.mid + dir * t, rotation: 0, g)
        }
    }

    func sprite(_ enc: MTLRenderCommandEncoder, _ sp: HUDSprite, at c: SIMD2<Double>, rotation: Float, _ g: Geometry) {
        let s = Float(g.scale)
        let size = sp.size * s
        var r = HudRectGPU(rect: SIMD4(Float(c.x) * s - size.x / 2, Float(c.y) * s - size.y / 2, size.x, size.y), viewport: g.viewport, rotation: rotation)
        var tint = SIMD4<Float>(1, 1, 1, 1)
        enc.setVertexBytes(&r, length: MemoryLayout<HudRectGPU>.stride, index: 0)
        enc.setFragmentBytes(&tint, length: 16, index: 0)
        enc.setFragmentTexture(sp.texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
