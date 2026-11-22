import AppKit
import ImageIO
import Metal
import RPFKit
import simd
import UniformTypeIdentifiers

let home = NSHomeDirectory()
var archivePath = "\(home)/testing/levels.rpf"
var indexPath = "\(home)/testing/6stars-data/levels.idx"
let textureRoots = ["\(home)/testing/data/ttdb", "\(home)/testing/pack"]
let textureAliases = ("\(home)/testing/textures.rpf", "\(home)/testing/6stars-data/textures.idx")
var snapshotPath: String?
var previewTexture: (UInt64, String, Int)?
var dictionaryDump: (String, String, UInt64, String, String?)?
var snapshotCamera: [Float]?
var paramStatsOut: (Int, String)?
var pickPoints: [(Int, Int)] = []
var probePoints: [(Int, Int)] = []

var argv = CommandLine.arguments.dropFirst().makeIterator()
while let a = argv.next() {
    switch a {
    case "--archive": archivePath = argv.next() ?? archivePath
    case "--index": indexPath = argv.next() ?? indexPath
    case "--snapshot": snapshotPath = argv.next()
    case "--camera": snapshotCamera = argv.next()?.split(separator: ",").compactMap { Float($0) }
    case "--texture":
        if let h = argv.next().flatMap({ UInt64($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: 16) }), let out = argv.next() {
            previewTexture = (h, out, 0)
        }
    case "--paramstats":
        if let n = argv.next().flatMap({ Int($0) }), let out = argv.next() { paramStatsOut = (n, out) }
    case "--pick":
        for pt in (argv.next() ?? "").split(separator: ";") {
            let c = pt.split(separator: ",").compactMap { Int($0) }
            if c.count == 2 { pickPoints.append((c[0], c[1])) }
        }
    case "--probe":
        for pt in (argv.next() ?? "").split(separator: ";") {
            let c = pt.split(separator: ",").compactMap { Int($0) }
            if c.count == 2 { probePoints.append((c[0], c[1])) }
        }
    case "--txd":
        if let rpf = argv.next(), let idx = argv.next(), let off = argv.next().flatMap({ UInt64($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: 16) }),
           let out = argv.next() {
            dictionaryDump = (rpf, idx, off, out, nil)
        }
    case "--txd-only": if let n = argv.next(), let d = dictionaryDump { dictionaryDump = (d.0, d.1, d.2, d.3, n) }
    case "--level": if let l = argv.next().flatMap({ Int($0) }), let p = previewTexture { previewTexture = (p.0, p.1, l) }
    default: break
    }
}

guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write("no Metal device\n".data(using: .utf8)!)
    exit(1)
}

func writePNG(_ img: CGImage, _ out: String) throws {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw RendererError.setup("cannot write \(out)")
    }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

if let (n, out) = paramStatsOut {
    do {
        try ParamStats.run(device: device, archive: archivePath, index: indexPath, samples: n, out: out)
        exit(0)
    } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

if let (rpf, idxPath, offset, out, only) = dictionaryDump {
    do {
        let renderer = try Renderer(device: device)
        let f = try MappedFile(path: rpf)
        let idx = try ArchiveIndex.read(from: idxPath)
        let txd = try TextureDictionary(try idx.resource(at: offset, from: f, physical: true))
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for (i, e) in txd.entries.enumerated() where only == nil || e.name.contains(only!) {
            let line = String(format: "%4d %@ %dx%d dxgi %d flags %04x level0 0x%x data 0x%x", i, e.name, e.info.width, e.info.height, e.info.format, e.info.flags, e.levelBytes, e.data)
            guard let img = try? txd.image(i), let tex = GPUTexture.make(device, img) else { print(line + " undecodable"); continue }
            try writePNG(try renderer.preview(tex, level: 0), "\(out)/\(e.name).png")
            print(line + " mips \(img.mips.count)")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

if let (hash, out, level) = previewTexture {
    do {
        let renderer = try Renderer(device: device)
        let t0 = Date()
        let db = TextureDB(roots: textureRoots, aliasArchive: textureAliases)
        print(String(format: "%d texture files, %d textures indexed in %.1fs", db.files.count, db.count, Date().timeIntervalSince(t0)))
        guard let (f, i) = db.find(hash) else { throw RendererError.setup("texture \(String(hash, radix: 16)) not found") }
        let img = try f.image(i)
        let inf = img.info
        print("\(f.path) #\(i): \(inf.width)x\(inf.height) dxgi \(inf.format) split \(inf.split) mips \(img.mips.count) flags \(String(inf.flags, radix: 16)) hint \(inf.hint) raw \(f.rawDescriptor(i))")
        print(f.layoutDescription(i))
        guard let tex = GPUTexture.make(device, img) else { throw RendererError.setup("cannot upload format \(inf.format)") }
        try writePNG(try renderer.preview(tex, level: level), out)
        print("wrote \(out)")
        exit(0)
    } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

if let out = snapshotPath {
    do {
        let renderer = try Renderer(device: device)
        let world = try World.load(archive: archivePath, indexPath: indexPath) { print($0) }
        renderer.upload(world)
        renderer.hud.waitForAssets()
        renderer.camera = world.startCamera()
        if let c = snapshotCamera, c.count == 5 {
            renderer.camera.position = SIMD3(c[0], c[1], c[2])
            renderer.camera.yaw = c[3] * .pi / 180
            renderer.camera.pitch = c[4] * .pi / 180
        }
        let t0 = Date()
        renderer.prepareSnapshot(aspect: 1600 / 900)
        let st = renderer.streamer!.stats
        print(String(format: "visible %d instances, %d groups, %d meshes loaded, %d failed, %.0f MB in %.1fs", renderer.visibleInstances,
                     renderer.current?.groups.count ?? 0, st.loaded, st.failed, Double(st.bytes) / 1e6, Date().timeIntervalSince(t0)))
        if ProcessInfo.processInfo.environment["MV_REPORT"] != nil, let r = renderer.current {
            let sc = world.scene
            var dead = 0
            let streamer = renderer.streamer!
            for g in r.groups where streamer.mesh(g.drawable, lod: g.lod) == nil {
                let c = sc.catalog.entries[Int(g.drawable)]
                dead += g.count
                print(String(format: "undrawable %@ lod %d x%d radius %.1f dist %.0f", c.name, g.lod, g.count, c.radius, g.dist))
            }
            var missing: [UInt32: (Int, Float, Float)] = [:]
            let p = renderer.camera.position
            var blocked = 0
            for n in sc.nodes where n.drawable >= 0 && n.childCount > 0 && simd_distance(n.center, renderer.camera.position) < n.childLodDist {
                if sc.children[Int(n.firstChild)..<Int(n.firstChild + n.childCount)].contains(where: { sc.nodes[Int($0)].drawable == -1 && sc.nodes[Int($0)].childCount == 0 }) { blocked += 1 }
            }
            print("parents kept at low detail by a child without a model: \(blocked)")
            for (i, n) in sc.nodes.enumerated() where n.drawable == -1 && n.childCount == 0 {
                let e = sc.world.entities[i]
                let d = simd_distance(n.center, p)
                guard d < 2500, e.lodLevel == 0 || e.lodLevel == 5, let a = sc.world.archetypes[e.archetype], a.radius > 8 else { continue }
                let m = missing[e.archetype] ?? (0, a.radius, d)
                missing[e.archetype] = (m.0 + 1, a.radius, min(m.2, d))
            }
            for (h, m) in missing.sorted(by: { $0.value.2 < $1.value.2 }).prefix(25) {
                print(String(format: "no model: archetype %08x x%d radius %.1f nearest %.0f m", h, m.0, m.1, m.2))
            }
            print("report: \(dead) instances undrawable, \(missing.count) nearby archetypes without a model")
        }
        let t1 = Date()
        try writePNG(try renderer.snapshot(width: 1600, height: 900), out)
        print(String(format: "frame encode+render %.1f ms, %d draw calls", Date().timeIntervalSince(t1) * 1000, renderer.drawCalls))
        if ProcessInfo.processInfo.environment["MV_HDRSTATS"] != nil, let h = renderer.atmosphere.hdr {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: h.width, height: h.height, mipmapped: false)
            d.storageMode = .shared
            if let t = renderer.device.makeTexture(descriptor: d), let cmd = renderer.queue.makeCommandBuffer(), let b = cmd.makeBlitCommandEncoder() {
                b.copy(from: h, to: t)
                b.endEncoding()
                cmd.commit()
                cmd.waitUntilCompleted()
                var px = [Float16](repeating: 0, count: h.width * h.height * 4)
                t.getBytes(&px, bytesPerRow: h.width * 8, from: MTLRegionMake2D(0, 0, h.width, h.height), mipmapLevel: 0)
                var bad = 0, big = 0, mx: Float = 0, at = (0, 0)
                for i in 0..<(h.width * h.height) {
                    let v = Float(max(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]))
                    if !v.isFinite { bad += 1; if bad < 4 { print("nonfinite at", i % h.width, i / h.width, px[i * 4], px[i * 4 + 1], px[i * 4 + 2]) }; continue }
                    if v > 10000 { big += 1 }
                    if v > mx { mx = v; at = (i % h.width, i / h.width) }
                }
                print("hdr: \(bad) non-finite, \(big) above 10000, max \(mx) at \(at)")
            }
        }
        if let n = Int(ProcessInfo.processInfo.environment["MV_FLY"] ?? "") {
            let env = ProcessInfo.processInfo.environment
            let speed = Float(env["MV_FLYSPEED"] ?? "") ?? 40
            renderer.visEnabled = true
            renderer.visForce = true
            let dir = renderer.camera.forward
            let base = String(out.dropLast(4))
            let tf = Date()
            for f in 0..<n {
                renderer.camera.position += dir * speed / 60
                let img = try renderer.snapshot(width: 800, height: 450)
                try writePNG(img, String(format: "%@_%03d.png", base, f))
            }
            print(String(format: "fly %d frames in %.1f s", n, Date().timeIntervalSince(tf)))
        }
        if let n = Int(ProcessInfo.processInfo.environment["MV_BENCH"] ?? "") {
            for pass in 0..<2 {
                renderer.shadows.enabled = pass == 0
                renderer.prepareSnapshot(aspect: 1600 / 900)
                renderer.visEnabled = true
                renderer.visForce = false
                renderer.visCamera = renderer.camera
                let tb = Date()
                renderer.benchEncode = 0
                renderer.benchGPU = 0
                for _ in 0..<n { _ = try renderer.snapshot(width: 1600, height: 900) }
                print(String(format: "  cpu encode %.1f ms, gpu %.1f ms per frame", renderer.benchEncode * 1000 / Double(n), renderer.benchGPU * 1000 / Double(n)))
                print(String(format: "bench shadows %@: %.1f ms per frame over %d frames, %d draw calls", pass == 0 ? "on" : "off", Date().timeIntervalSince(tb) * 1000 / Double(n), n, renderer.drawCalls))
                print("  main tris \(renderer.mainTris), shadow cascades (draws, tris): \(renderer.shadowStats)")
            }
        }
        if let ts = renderer.textures?.stats { print("textures \(ts.loaded) loaded, \(ts.failed) undecodable, \(ts.slots - 2) referenced") }
        for (px, py) in probePoints {
            let cam = renderer.camera
            let aspect: Float = 1600 / 900
            let ndc = SIMD2(Float(px) / 1600 * 2 - 1, 1 - Float(py) / 900 * 2)
            let t = tan(cam.fovY / 2)
            let dir = simd_normalize(cam.forward + cam.right * ndc.x * t * aspect + simd_cross(cam.right, cam.forward) * ndc.y * t)
            var hit = cam.position
            var z0: Float = 0
            for step in 1...4000 {
                let q = cam.position + dir * Float(step) * 0.5
                let h = world.heights?.surfaceHeight(at: SIMD2(q.x, q.y)) ?? 0
                if q.z <= h { hit = q; z0 = h; break }
            }
            print(String(format: "probe %d,%d -> world %.1f %.1f ground %.1f", px, py, hit.x, hit.y, z0))
            let sc = world.scene
            for (i, n) in sc.nodes.enumerated() {
                let e = sc.world.entities[i]
                let d2 = simd_distance(SIMD2(n.center.x, n.center.y), SIMD2(hit.x, hit.y))
                guard d2 < n.radius + 5 else { continue }
                let name = n.drawable >= 0 ? sc.catalog.entries[Int(n.drawable)].name : String(format: "MISSING %08x", e.archetype)
                let vis = renderer.current?.groups.contains { $0.drawable == n.drawable } == true
                var chain = ""
                var a = Int(e.parent)
                var hops = 0
                while a >= 0 && hops < 8 {
                    let an = sc.nodes[a]
                    let aname = an.drawable >= 0 ? sc.catalog.entries[Int(an.drawable)].name : String(format: "MISSING %08x", sc.world.entities[a].archetype)
                    let adrawn = renderer.current?.groups.contains { $0.drawable == an.drawable } == true
                    chain += String(format: " <- %@%@ d%.0f/c%.0f", aname, adrawn ? "*" : "", simd_distance(an.center, cam.position), an.childLodDist)
                    a = Int(sc.world.entities[a].parent)
                    hops += 1
                }
                print(String(format: "   %@ lvl %d lod %.0f child %.0f kids %d dist %.0f r %.0f br %.0f %@ meshes %@%@", name, e.lodLevel, n.lodDist, n.childLodDist, n.childCount,
                             simd_distance(n.center, cam.position), n.radius, n.bradius, vis ? "DRAWN" : "-", n.drawable >= 0 && renderer.streamer!.hasMesh(n.drawable) ? "yes" : "no", chain))
            }
        }
        if !pickPoints.isEmpty, let mats = renderer.materials, let ts = renderer.textures {
            renderer.pickMode = true
            let img = try renderer.snapshot(width: 1600, height: 900)
            renderer.pickGroups = true
            let gimg = try renderer.snapshot(width: 1600, height: 900)
            renderer.pickGroups = false
            renderer.pickMode = false
            let data = img.dataProvider!.data! as Data
            let gdata = gimg.dataProvider!.data! as Data
            func lin(_ c: UInt8) -> Int {
                let x = Double(c) / 255
                let l = x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
                return Int((l * 255 / 4).rounded())
            }
            for (x, y) in pickPoints {
                let o = y * img.bytesPerRow + x * 4
                let id = lin(data[o + 2]) | lin(data[o + 1]) << 6 | lin(data[o]) << 12
                let key = id < mats.keys.count ? mats.keys[id] : "?"
                print("pick \(x),\(y): material \(id) \(key)")
                let go = y * gimg.bytesPerRow + x * 4
                let gid = lin(gdata[go + 2]) | lin(gdata[go + 1]) << 6 | lin(gdata[go]) << 12
                if let groups = renderer.current?.groups, gid < groups.count, id < mats.keys.count {
                    let g = groups[gid]
                    print("   drawable \(world.scene.catalog.entries[Int(g.drawable)].name) lod \(g.lod) instances \(g.count)")
                    if let m = renderer.streamer?.mesh(g.drawable, lod: g.lod) {
                        let n = m.vertices.length / MemoryLayout<GPUVertex>.stride
                        let vp = m.vertices.contents().bindMemory(to: GPUVertex.self, capacity: n)
                        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
                        for k in 0..<n { let q = SIMD3(vp[k].x, vp[k].y, vp[k].z); lo = simd_min(lo, q); hi = simd_max(hi, q) }
                        print(String(format: "   gpu mesh lod %d verts %d bounds (%.3f %.3f %.3f)..(%.3f %.3f %.3f)", m.lod, n, lo.x, lo.y, lo.z, hi.x, hi.y, hi.z))
                    }
                    if let ib = renderer.current?.instances {
                        let p = ib.contents().bindMemory(to: InstanceGPU.self, capacity: ib.length / MemoryLayout<InstanceGPU>.stride)
                        for k in 0..<min(g.count, 3) {
                            let t = p[g.first + k]
                            print(String(format: "   instance rows (%.2f %.2f %.2f %.1f) (%.2f %.2f %.2f %.1f) (%.2f %.2f %.2f %.1f)", t.row0.x, t.row0.y, t.row0.z, t.row0.w, t.row1.x, t.row1.y, t.row1.z, t.row1.w, t.row2.x, t.row2.y, t.row2.z, t.row2.w))
                        }
                    }
                }
                let nums = key.split(whereSeparator: { !"0123456789".contains($0) }).compactMap { Int($0) }
                for sl in nums.dropFirst(3) where sl >= 2 && sl < ts.hashOf.count {
                    let h = ts.hashOf[sl]
                    if let (f, i) = ts.db.find(h) {
                        let inf = f.info(i)
                        let d = f.decodable(i)
                        print(String(format: "   slot %d tex %016llx %dx%d dxgi %d levels %d/%d %@", sl, h, inf.width, inf.height, inf.format, d.levels, d.total, (f.path as NSString).lastPathComponent))
                    }
                }
            }
        }
        let c = renderer.camera
        print(String(format: "camera %.1f,%.1f,%.1f,%.1f,%.1f  %d entities, %d placed, wrote %@", c.position.x, c.position.y, c.position.z,
                     c.yaw * 180 / .pi, c.pitch * 180 / .pi, world.scene.entityCount, world.scene.matched, out))
        exit(0)
    } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: FlyView!
    let device: MTLDevice
    let archivePath: String
    let indexPath: String

    init(device: MTLDevice, archivePath: String, indexPath: String) {
        self.device = device
        self.archivePath = archivePath
        self.indexPath = indexPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let renderer: Renderer
        do {
            renderer = try Renderer(device: device)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Metal setup failed"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "6stars — github.com/meetox80/6stars — built \(BuildInfo.date)"
        view = FlyView(frame: frame, renderer: renderer)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let v = view!
        let archivePath = self.archivePath, indexPath = self.indexPath
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let world = try World.load(archive: archivePath, indexPath: indexPath) { s in
                    DispatchQueue.main.async { v.status = s }
                }
                DispatchQueue.main.async { v.setWorld(world) }
            } catch {
                DispatchQueue.main.async { v.status = "Failed to load: \(error)" }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate(device: device, archivePath: archivePath, indexPath: indexPath)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
