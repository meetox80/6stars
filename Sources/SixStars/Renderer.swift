import Metal
import RPFKit
import MetalKit
import simd

struct Uniforms {
    var viewProj: simd_float4x4
    var camPos: SIMD4<Float>
    var viewport: SIMD2<Float>
    var time: Float
    var debug: Float
}

struct InstanceGPU {
    var row0: SIMD4<Float>
    var row1: SIMD4<Float>
    var row2: SIMD4<Float>
    var fade = SIMD4<Float>(repeating: 0)
}

struct DrawGroup {
    var drawable: Int32
    var lod: Int
    var first: Int
    var count: Int
    var solid: Int = 0
    var dist: Float
    var level: UInt8
}

final class VisibilityResult {
    let groups: [DrawGroup]
    let instances: MTLBuffer?
    let visible: Int
    let prefetch: [Int64]
    let order: [Int64]
    var shadow: VisibilityResult?
    init(groups: [DrawGroup], instances: MTLBuffer?, visible: Int, prefetch: [Int64], order: [Int64]) {
        self.groups = groups
        self.instances = instances
        self.visible = visible
        self.prefetch = prefetch
        self.order = order
    }
}

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let linePipeline: MTLRenderPipelineState
    let overlayLinePipeline: MTLRenderPipelineState
    let atmosphere: Atmosphere
    let shadows: Shadows
    let deferred: Deferred
    let meshPipeline: MTLRenderPipelineState
    let blendPipeline: MTLRenderPipelineState
    let quadPipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    let decalDepthState: MTLDepthStencilState
    let colorFormat: MTLPixelFormat = .bgra8Unorm_srgb
    let hud: HUD
    let depthFormat: MTLPixelFormat = .depth32Float

    var lineBuffer: MTLBuffer?
    var lineCount = 0
    var camera = Camera()
    var showGrid = false
    var showMeshes = true
    var showClass = [true, true, true]
    var debugColors = ProcessInfo.processInfo.environment["MV_DEBUG"] != nil
    var pickMode = false
    var pickGroups = false
    let viewMode: Float = ["albedo": 1, "color0": 2, "normal": 3, "vnormal": 4, "kind": 5, "lod": 6][ProcessInfo.processInfo.environment["MV_VIEW"] ?? ""] ?? 0

    var scene: Scene?
    var streamer: MeshStreamer?
    var textures: TextureStreamer?
    var materials: MaterialRegistry?
    var current: VisibilityResult?
    var pending: VisibilityResult?
    var visBusy = false
    var visCamera: Camera?
    var visForce = true
    var visEnabled = true
    let visQueue = DispatchQueue(label: "visibility", qos: .userInitiated)
    let visLock = NSLock()
    var visibleInstances = 0
    var drawnInstances = 0
    var drawCalls = 0
    var frameCount = 0

    init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw RendererError.setup("no command queue") }
        queue = q
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        let library = try device.makeLibrary(source: shaderSource + atmosphereShaderSource + deferredShaderSource + volumetricShaderSource + hudShaderSource, options: options)
        let cf = colorFormat, df = depthFormat

        func pipeline(_ vs: String, _ fs: String, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vs)
            d.fragmentFunction = library.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = cf
            d.depthAttachmentPixelFormat = df
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .zero
                d.colorAttachments[0].destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        linePipeline = try pipeline("lineVertex", "lineFragment", blend: true)
        meshPipeline = try pipeline("meshVertex", "meshFragment", blend: false)
        blendPipeline = try pipeline("meshVertex", "meshFragment", blend: true)
        let qd = MTLRenderPipelineDescriptor()
        qd.vertexFunction = library.makeFunction(name: "quadVertex")
        qd.fragmentFunction = library.makeFunction(name: "quadFragment")
        qd.colorAttachments[0].pixelFormat = cf
        quadPipeline = try device.makeRenderPipelineState(descriptor: qd)
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .greater
        ds.isDepthWriteEnabled = true
        guard let dss = device.makeDepthStencilState(descriptor: ds) else { throw RendererError.setup("no depth state") }
        depthState = dss
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .greaterEqual
        dd.isDepthWriteEnabled = false
        guard let dds = device.makeDepthStencilState(descriptor: dd) else { throw RendererError.setup("no depth state") }
        decalDepthState = dds
        let od = MTLRenderPipelineDescriptor()
        od.vertexFunction = library.makeFunction(name: "lineVertex")
        od.fragmentFunction = library.makeFunction(name: "lineFragment")
        od.colorAttachments[0].pixelFormat = cf
        od.colorAttachments[0].isBlendingEnabled = true
        od.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        od.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        overlayLinePipeline = try device.makeRenderPipelineState(descriptor: od)
        atmosphere = try Atmosphere(device: device, library: library)
        shadows = try Shadows(device: device, library: library)
        deferred = try Deferred(device: device, library: library)
        atmosphere.env = deferred.env
        hud = try HUD(device: device, library: library, colorFormat: cf)
    }

    func upload(_ world: World) {
        lineCount = world.lines.count
        lineBuffer = lineCount > 0 ? device.makeBuffer(bytes: world.lines, length: lineCount * MemoryLayout<PointVertex>.stride) : nil
        scene = world.scene
        let ts = TextureStreamer(device: device, db: world.textures, queue: queue)
        let mr = MaterialRegistry(device: device)
        textures = ts
        materials = mr
        streamer = MeshStreamer(device: device, scene: world.scene, textures: ts, materials: mr)
        current = nil
        visForce = true
        hud.start(heights: world.heights)
    }

    static func planes(_ m: simd_float4x4) -> [SIMD4<Float>] {
        func row(_ i: Int) -> SIMD4<Float> { SIMD4(m.columns.0[i], m.columns.1[i], m.columns.2[i], m.columns.3[i]) }
        let r0 = row(0), r1 = row(1), r3 = row(3)
        return [r3 + r0, r3 - r0, r3 + r1, r3 - r1].map { p in p / simd_length(SIMD3(p.x, p.y, p.z)) }
    }

    static func lodLevel(_ info: (dist: SIMD4<Float>, known: Bool), _ d: Float, _ radius: Float) -> Int {
        guard info.known else { return d > max(250, radius * 30) ? 1 : 0 }
        var last = 0
        for i in 0..<4 where info.dist[i] > 0 {
            last = i
            if d < info.dist[i] { return i }
        }
        return last
    }

    let noRotation = ProcessInfo.processInfo.environment["MV_NOROT"] != nil
    let timeBase = CACurrentMediaTime()
    struct Occlusion {
        var depth: [Float]
        var viewProj: simd_float4x4
        var position: SIMD3<Float>
        var forward: SIMD3<Float>
        var tanHalf: Float
        var aspect: Float
    }
    let occlusionLock = NSLock()
    var occlusion: Occlusion?
    var occlusionEnabled = ProcessInfo.processInfo.environment["MV_NOOCCLUSION"] == nil
    var taaEnabled = true
    var taaAccumulating = false
    static let snapshotTAAFrames = 24
    var taaActive: Bool { (visEnabled || taaAccumulating) && taaEnabled }
    var lodFactor: Float = 1
    var debugUI: DebugUI?
    lazy var snapshotDebugState = DebugState()
    static let fadeSeconds: Float = 0.6
    static let minPixels: Float = 1.2
    static let referenceHeight: Float = 1080
    let skipBatches = ProcessInfo.processInfo.environment["MV_NOBATCH"] != nil
    let noSplit = ProcessInfo.processInfo.environment["MV_NOSPLIT"] != nil
    let skipPasses = Set((ProcessInfo.processInfo.environment["MV_SKIPPASS"] ?? "").split(separator: ",").compactMap { Int($0) })
    var benchEncode: Double = 0
    var benchGPU: Double = 0
    var prevShown = Set<Int32>()
    var fadeIn: [Int32: Float] = [:]
    var fadeOut: [Int32: Float] = [:]
    let lodScale = Float(ProcessInfo.processInfo.environment["MV_LODSCALE"] ?? "") ?? 4

    lazy var onlyDrawable: Int32? = {
        guard let name = ProcessInfo.processInfo.environment["MV_ONLY"], let sc = scene, let i = sc.catalog.byHash[Hash.joaat(name)] else { return nil }
        return Int32(i)
    }()

    func casterPlanes(camera: Camera, aspect: Float) -> [SIMD4<Float>]? {
        let sun = atmosphere.sunDirection
        guard shadows.enabled, sun.z > 0.02, let last = atmosphere.cascades(camera: camera, aspect: aspect).last else { return nil }
        return Shadows.casterPlanes(last, sun: sun)
    }

    func visibility(camera cam: Camera, aspect: Float, classes: [Bool], casters: [SIMD4<Float>]?, fading: Bool = false) -> VisibilityResult {
        let r = computeVisibility(camera: cam, aspect: aspect, classes: classes, fading: fading)
        if let cp = casters { r.shadow = computeVisibility(camera: cam, aspect: aspect, classes: classes, planes: cp) }
        return r
    }

    func computeVisibility(camera cam: Camera, aspect: Float, classes: [Bool], planes: [SIMD4<Float>]? = nil, fading: Bool = false) -> VisibilityResult {
        guard let scene = scene, let streamer = streamer else { return VisibilityResult(groups: [], instances: nil, visible: 0, prefetch: [], order: []) }
        let p = cam.position
        let wide = Camera(position: cam.position, yaw: cam.yaw, pitch: cam.pitch, fovY: min(cam.fovY * 1.2, 2.6))
        let pl = planes ?? Renderer.planes(wide.projectionMatrix(aspect: aspect) * wide.viewMatrix())
        var byKey: [Int64: Int] = [:]
        var lists: [(drawable: Int32, lod: Int, inst: [Int32], dist: Float)] = []
        var prefetch: [(key: Int64, dist: Float)] = []
        var count = 0
        let nodes = scene.nodes, kids = scene.children, ents = scene.world.entities
        var shown: [Int32] = []
        func inFrustum(_ n: Node) -> Bool {
            for q in pl where simd_dot(SIMD3(q.x, q.y, q.z), n.bcenter) + q.w < -n.bradius { return false }
            return true
        }
        let castersOnly = planes != nil
        let k = max(lodFactor, 0.05)
        occlusionLock.lock()
        var occ = castersOnly || !occlusionEnabled ? nil : occlusion
        occlusionLock.unlock()
        if let o = occ, simd_distance(o.position, p) > 8 || simd_dot(o.forward, cam.forward) < 0.985 { occ = nil }
        let ow = Deferred.occlusionSize.0, oh = Deferred.occlusionSize.1
        func occluded(_ n: Node) -> Bool {
            guard let o = occ else { return false }
            let r = n.bradius
            let along = simd_dot(n.bcenter - o.position, o.forward)
            if along - r < 2 { return false }
            let cc = o.viewProj * SIMD4(n.bcenter, 1)
            guard cc.w > 0 else { return false }
            let ry = r / ((along - r) * o.tanHalf), rx = ry / o.aspect
            let nx = cc.x / cc.w, ny = cc.y / cc.w
            let x0 = nx - rx, x1 = nx + rx, y0 = ny - ry, y1 = ny + ry
            if x0 < -1 || x1 > 1 || y0 < -1 || y1 > 1 { return false }
            let cx0 = max(0, Int((x0 * 0.5 + 0.5) * Float(ow))), cx1 = min(ow - 1, Int((x1 * 0.5 + 0.5) * Float(ow)))
            let cy0 = max(0, Int((0.5 - y1 * 0.5) * Float(oh))), cy1 = min(oh - 1, Int((0.5 - y0 * 0.5) * Float(oh)))
            if (cx1 - cx0 + 1) * (cy1 - cy0 + 1) > 400 { return false }
            let np = o.viewProj * SIMD4(n.bcenter - o.forward * r, 1)
            guard np.w > 0 else { return false }
            let zClose = np.z / np.w
            for y in cy0...cy1 {
                let row = y * ow
                for x in cx0...cx1 where o.depth[row + x] <= zClose { return false }
            }
            return true
        }
        let minAngular = Renderer.minPixels * 2 * tan(cam.fovY / 2) / Renderer.referenceHeight
        func emit(_ i: Int32, _ n: Node, _ d: Float, fadingOut: Bool = false) {
            guard n.drawable >= 0, classes[Int(n.level)] else { return }
            if !castersOnly && n.childCount == 0 && n.radius < d * minAngular { return }
            if skipBatches && ents[Int(i)].hasBasis { return }
            if castersOnly {
                let e = ents[Int(i)]
                if !e.hasBasis && e.flags & 0x18_0000 == 0 { return }
            }
            if let only = onlyDrawable, n.drawable != only { return }
            count += 1
            if !fadingOut { shown.append(i) }
            var lod = Renderer.lodLevel(streamer.lodInfo(n.drawable), max(0, d - n.radius * 0.5) / lodScale, n.radius)
            if streamer.isFailed(MeshStreamer.key(n.drawable, lod)) {
                for alt in [lod - 1, lod + 1, lod - 2, lod + 2, lod - 3, lod + 3] where (0...3).contains(alt) {
                    if !streamer.isFailed(MeshStreamer.key(n.drawable, alt)) {
                        lod = alt
                        break
                    }
                }
            }
            let k = MeshStreamer.key(n.drawable, lod)
            if let g = byKey[k] {
                lists[g].inst.append(i)
                lists[g].dist = min(lists[g].dist, d)
            } else {
                byKey[k] = lists.count
                lists.append((n.drawable, lod, [i], d))
            }
        }
        func visit(_ i: Int32, _ depth: Int, _ free: Bool) {
            let n = nodes[Int(i)]
            guard n.bradius > 0, inFrustum(n), !occluded(n) else { return }
            let d = simd_distance(n.center, p)
            if free && simd_distance(n.bcenter, p) > max(n.lodDist, n.childLodDist) * k + n.bradius { return }
            if n.childCount > 0 && depth < 8 {
                let want = n.drawable < 0 || d < n.childLodDist * k + n.radius * 0.25
                let parentResident = n.drawable < 0 || streamer.hasMesh(n.drawable)
                if want || !parentResident {
                    var ready = true
                    for c in kids[Int(n.firstChild)..<Int(n.firstChild + n.childCount)] {
                        let cn = nodes[Int(c)]
                        if cn.drawable < 0 {
                            if cn.drawable == -1 && cn.childCount == 0 { ready = false }
                            continue
                        }
                        if !streamer.hasMesh(cn.drawable) {
                            ready = false
                            if want { prefetch.append((MeshStreamer.key(cn.drawable, 0), d)) }
                        }
                    }
                    if (want && (ready || n.drawable < 0)) || (!want && ready) {
                        if !want { prefetch.append((MeshStreamer.key(n.drawable, 0), d)) }
                        for c in kids[Int(n.firstChild)..<Int(n.firstChild + n.childCount)] { visit(c, depth + 1, n.drawable < 0) }
                        return
                    }
                }
            }
            emit(i, n, d)
        }
        for g in 0..<scene.grids.count {
            scene.grids[g].query(p, radius: scene.gridLimits[g] * max(k, 1)) { r in
                let n = nodes[Int(r)]
                if simd_distance(n.bcenter, p) > max(n.lodDist, n.childLodDist) * k + n.bradius { return }
                visit(r, 0, false)
            }
        }
        let now = Float(CACurrentMediaTime() - timeBase)
        if fading {
            let set = Set(shown)
            for i in shown where !prevShown.contains(i) {
                var swap = false
                let par = ents[Int(i)].parent
                if par >= 0, prevShown.contains(par) {
                    swap = true
                    if fadeOut[par] == nil { fadeOut[par] = now }
                }
                let ni = nodes[Int(i)]
                if ni.childCount > 0 {
                    for c in kids[Int(ni.firstChild)..<Int(ni.firstChild + ni.childCount)] where prevShown.contains(c) {
                        swap = true
                        if fadeOut[c] == nil { fadeOut[c] = now }
                    }
                }
                if swap { fadeIn[i] = now }
            }
            for i in shown { fadeOut.removeValue(forKey: i) }
            for (j, t) in fadeOut {
                let nj = nodes[Int(j)]
                if now - t >= Renderer.fadeSeconds || nj.drawable < 0 || !inFrustum(nj) || !streamer.hasMesh(nj.drawable) {
                    fadeOut.removeValue(forKey: j)
                    continue
                }
                emit(j, nj, simd_distance(nj.center, p), fadingOut: true)
            }
            fadeIn = fadeIn.filter { now - $0.value < Renderer.fadeSeconds }
            prevShown = set
        } else if castersOnly {
            for (j, t) in fadeOut where now - t < Renderer.fadeSeconds {
                let nj = nodes[Int(j)]
                guard nj.drawable >= 0, inFrustum(nj), streamer.hasMesh(nj.drawable) else { continue }
                emit(j, nj, simd_distance(nj.center, p), fadingOut: true)
            }
        }
        lists.sort { $0.dist < $1.dist }
        var transforms: [InstanceGPU] = []
        transforms.reserveCapacity(count)
        var groups: [DrawGroup] = []
        groups.reserveCapacity(lists.count)
        var fadingTail: [InstanceGPU] = []
        for l in lists {
            var group = DrawGroup(drawable: l.drawable, lod: l.lod, first: transforms.count, count: l.inst.count, dist: l.dist, level: scene.world.entities[Int(l.inst[0])].lodLevel)
            fadingTail.removeAll(keepingCapacity: true)
            for i in l.inst {
                let n = nodes[Int(i)]
                var fade = SIMD4<Float>(repeating: 0)
                if fading || castersOnly {
                    if let t = fadeOut[i] {
                        fade = SIMD4(t, -1, 0, 0)
                    } else if let t = fadeIn[i] {
                        fade = SIMD4(t, 1, 0, 0)
                    } else if ents[Int(i)].parent < 0 {
                        let reach = max(n.lodDist, n.childLodDist) * k + n.radius
                        let a = (reach - simd_distance(n.center, p)) / max(reach * 0.12, 4)
                        if a < 1 { fade = SIMD4(max(a, 0), 2, 0, 0) }
                    }
                }
                let inst = noRotation
                    ? InstanceGPU(row0: SIMD4(1, 0, 0, n.row0.w), row1: SIMD4(0, 1, 0, n.row1.w), row2: SIMD4(0, 0, 1, n.row2.w), fade: fade)
                    : InstanceGPU(row0: n.row0, row1: n.row1, row2: n.row2, fade: fade)
                if fade.y == 0 { transforms.append(inst) } else { fadingTail.append(inst) }
            }
            group.solid = l.inst.count - fadingTail.count
            transforms.append(contentsOf: fadingTail)
            groups.append(group)
        }
        let buf = transforms.isEmpty ? nil : device.makeBuffer(bytes: transforms, length: transforms.count * MemoryLayout<InstanceGPU>.stride, options: .storageModeShared)
        var merged = groups.map { (key: MeshStreamer.key($0.drawable, $0.lod), dist: $0.dist) } + prefetch
        merged.sort { $0.dist < $1.dist }
        return VisibilityResult(groups: groups, instances: buf, visible: count, prefetch: prefetch.map { $0.key }, order: merged.map { $0.key })
    }

    func adopt(_ r: VisibilityResult) {
        current = r
        visibleInstances = r.visible
        streamer?.want(r.order + (r.shadow?.order ?? []))
    }

    func scheduleVisibility(aspect: Float) {
        visLock.lock()
        let ready = pending
        pending = nil
        let busy = visBusy
        visLock.unlock()
        if let r = ready { adopt(r) }
        guard visEnabled, !busy else { return }
        let cam = camera
        if !visForce, let last = visCamera, simd_distance(last.position, cam.position) < 1.5,
           abs(last.yaw - cam.yaw) < 0.015, abs(last.pitch - cam.pitch) < 0.015, frameCount % 30 != 0 { return }
        visForce = false
        visCamera = cam
        let classes = showClass
        let casters = casterPlanes(camera: cam, aspect: aspect)
        visLock.lock()
        visBusy = true
        visLock.unlock()
        visQueue.async { [weak self] in
            guard let self = self else { return }
            let r = self.visibility(camera: cam, aspect: aspect, classes: classes, casters: casters, fading: true)
            self.visLock.lock()
            self.pending = r
            self.visBusy = false
            self.visLock.unlock()
        }
    }

    func invalidateVisibility() { visForce = true }

    func prepareSnapshot(aspect: Float) {
        visEnabled = false
        let casters = casterPlanes(camera: camera, aspect: aspect)
        var r = visibility(camera: camera, aspect: aspect, classes: showClass, casters: casters)
        guard let streamer = streamer, let textures = textures else { return }
        for _ in 0..<8 {
            streamer.loadBlocking(r.groups.map { MeshStreamer.key($0.drawable, $0.lod) } + r.prefetch + (r.shadow.map { s in s.groups.map { MeshStreamer.key($0.drawable, $0.lod) } + s.prefetch } ?? []))
            let next = visibility(camera: camera, aspect: aspect, classes: showClass, casters: casters)
            let failing = next.groups.contains { streamer.isFailed(MeshStreamer.key($0.drawable, $0.lod)) && !streamer.isFailed(MeshStreamer.key($0.drawable, ($0.lod + 1) % 4)) }
            let done = (next.prefetch.isEmpty || Set(next.prefetch) == Set(r.prefetch)) && !failing
            r = next
            if done { break }
        }
        streamer.loadBlocking(r.groups.map { MeshStreamer.key($0.drawable, $0.lod) } + (r.shadow?.groups.map { MeshStreamer.key($0.drawable, $0.lod) } ?? []))
        current = r
        visibleInstances = r.visible
        var slots: [UInt32] = []
        for g in r.groups + (r.shadow?.groups ?? []) { if let m = streamer.mesh(g.drawable, lod: g.lod) { slots += m.textureSlots } }
        textures.loadBlocking(slots)
    }

    func encode(_ cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize) {
        if pickMode || viewMode != 0 || debugColors {
            encodeDirect(cmd, pass: pass, size: size)
            return
        }
        guard let target = pass.colorAttachments[0].texture else { return }
        frameCount += 1
        let aspect = Float(size.width / max(size.height, 1))
        if showMeshes { scheduleVisibility(aspect: aspect) }
        textures?.beginFrame()
        let jit = atmosphere.jitter(width: target.width, height: target.height, active: taaActive)
        let view = camera.viewMatrix()
        let unjittered = camera.projectionMatrix(aspect: aspect) * view
        var proj = camera.projectionMatrix(aspect: aspect)
        proj.columns.2.x -= jit.x
        proj.columns.2.y -= jit.y
        let viewProj = proj * view
        var a = atmosphere.params(camera: camera, aspect: aspect, height: target.height, viewProj: viewProj)
        a.taa = SIMD4(jit.x, jit.y, 1, 0)
        atmosphere.ensureTargets(width: target.width, height: target.height)
        deferred.ensure(width: target.width, height: target.height)
        atmosphere.prepare(cmd, &a)
        deferred.updateEnvironment(cmd, &a, atmosphere: atmosphere, force: !visEnabled)
        let (cascades, shadowOn) = renderShadows(cmd, atmosphere.cascades(camera: camera, aspect: aspect), settle: !visEnabled)
        var sd = Shadows.gpu(cascades, enabled: shadowOn)
        guard let hdr = atmosphere.hdr, let depth = atmosphere.depth,
              let enc = cmd.makeRenderCommandEncoder(descriptor: deferred.gbufferPass(hdr: hdr, depth: depth)) else { return }
        var u = Uniforms(viewProj: viewProj, camPos: SIMD4(camera.position, 1), viewport: SIMD2(Float(size.width), Float(size.height)),
                         time: Float(CACurrentMediaTime() - timeBase), debug: 0)
        enc.setCullMode(.none)
        drawnInstances = 0
        drawCalls = 0
        mainTris = 0
        atmosphere.fullscreen(enc, deferred.skyPipe, &a)
        let ready = readyGroups()
        if let ready = ready {
            bindMeshState(enc, &u)
            enc.setFragmentBytes(&a, length: MemoryLayout<AtmosGPU>.stride, index: 6)
            drawOpaque(enc, ready, solid: deferred.gbufferSolidPipe, cutout: deferred.gbufferPipe)
            drawMeshes(enc, ready, passes: [1], opaque: deferred.gbufferPipe, blend: deferred.decalPipe)
        }
        enc.endEncoding()
        if let ob = deferred.reduceDepth(cmd, depth: depth) {
            let snap = Occlusion(depth: [], viewProj: viewProj, position: camera.position, forward: camera.forward,
                                 tanHalf: tan(camera.fovY / 2), aspect: aspect)
            let count = Deferred.occlusionSize.0 * Deferred.occlusionSize.1
            cmd.addCompletedHandler { [weak self] _ in
                var o = snap
                o.depth = Array(UnsafeBufferPointer(start: ob.contents().bindMemory(to: Float.self, capacity: count), count: count))
                self?.occlusionLock.lock()
                self?.occlusion = o
                self?.occlusionLock.unlock()
            }
        }
        deferred.ssao(cmd, &a, depth: depth)
        let historyOK = atmosphere.prevCamera.map { simd_distance($0, camera.position) < 60 } ?? false
        deferred.indirect(cmd, &a, depth: depth, previous: historyOK ? atmosphere.hdrCopy : nil, prevViewProj: historyOK ? atmosphere.prevViewProj : nil)
        deferred.light(cmd, &a, &sd, shadowMap: shadows.map, atmosphere: atmosphere)
        atmosphere.volumetrics(cmd, &a, &sd, shadowMap: shadows.map)
        atmosphere.copyScene(cmd, &a)
        guard let fe = cmd.makeRenderCommandEncoder(descriptor: atmosphere.forwardPass()) else { return }
        fe.setCullMode(.none)
        atmosphere.fullscreen(fe, atmosphere.seedPipe, &a)
        atmosphere.fullscreen(fe, atmosphere.oceanPipe, &a, depthState: depthState)
        if let ready = ready {
            bindMeshState(fe, &u)
            atmosphere.bindLighting(fe, &a, &sd, shadows.map)
            drawMeshes(fe, ready, passes: [2], opaque: atmosphere.meshPipe, blend: atmosphere.meshBlendPipe)
        }
        fe.setDepthBias(0, slopeScale: 0, clamp: 0)
        atmosphere.fullscreen(fe, atmosphere.compositePipe, &a)
        fe.endEncoding()
        finishFrame(ready)
        let resolved = atmosphere.resolveTAA(cmd, &a, unjittered: unjittered, camera: camera.position, active: taaActive) ?? hdr
        hud.prepare(cmd, source: resolved, camera: camera, viewport: SIMD2(Float(target.width), Float(target.height)), waterLevel: a.waterExt.w, settle: !visEnabled)
        var hudAtmos = a
        atmosphere.post(cmd, target: target, source: resolved, &a, settle: !visEnabled) { enc in
            if self.showGrid, let lb = self.lineBuffer {
                enc.setRenderPipelineState(self.overlayLinePipeline)
                enc.setVertexBuffer(lb, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: self.lineCount)
            }
            self.hud.draw(enc, atmos: &hudAtmos, exposure: self.atmosphere.exposureBuffer, bloom: self.atmosphere.bloom)
            self.debugUI?.render(enc, width: target.width, height: target.height)
        }
    }

    func encodeDirect(_ cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize) {
        frameCount += 1
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        let aspect = Float(size.width / max(size.height, 1))
        if showMeshes { scheduleVisibility(aspect: aspect) }
        textures?.beginFrame()
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = Uniforms(viewProj: camera.projectionMatrix(aspect: aspect) * camera.viewMatrix(),
                         camPos: SIMD4(camera.position, 1),
                         viewport: SIMD2(Float(size.width), Float(size.height)),
                         time: Float(CACurrentMediaTime() - timeBase),
                         debug: pickMode ? (pickGroups ? 3 : 2) : (viewMode != 0 ? -viewMode : (debugColors ? 1 : 0)))
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        drawnInstances = 0
        drawCalls = 0
        let ready = readyGroups()
        if let ready = ready {
            bindMeshState(enc, &u)
            drawMeshes(enc, ready, passes: [0, 1, 2], opaque: meshPipeline, blend: blendPipeline)
        }
        finishFrame(ready)
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        enc.setDepthStencilState(depthState)
        if showGrid, let lb = lineBuffer {
            enc.setRenderPipelineState(linePipeline)
            enc.setVertexBuffer(lb, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineCount)
        }
        enc.endEncoding()
    }

    var shadowStats = [(Int, Int)](repeating: (0, 0), count: Shadows.count)
    var mainTris = 0

    var cascadeState: [Cascade]?
    var shadowFrame = 0

    func renderShadows(_ cmd: MTLCommandBuffer, _ fresh: [Cascade], settle: Bool) -> ([Cascade], Bool) {
        guard shadows.enabled, showMeshes, atmosphere.sunDirection.z > 0.02, let streamer = streamer, let ts = textures, let mats = materials,
              let sv = current?.shadow, let ib = sv.instances else {
            cascadeState = nil
            return (fresh, false)
        }
        shadowFrame += 1
        var cascades = cascadeState ?? fresh
        let all = settle || cascadeState == nil
        var update = [Bool](repeating: true, count: fresh.count)
        if !all {
            update[1] = shadowFrame % 2 == 1
            update[2] = shadowFrame % 2 == 0
            update[3] = shadowFrame % 4 == 1
        }
        for i in 0..<fresh.count where update[i] { cascades[i] = fresh[i] }
        cascadeState = cascades
        var ready: [(GPUMesh, DrawGroup, Float)] = []
        let cat = scene?.catalog
        for g in sv.groups {
            guard let m = streamer.mesh(g.drawable, lod: g.lod), m.ranges[0].count + m.ranges[3].count > 0 else { continue }
            ready.append((m, g, cat?.entries[Int(g.drawable)].radius ?? 1))
            ts.touch(m.textureSlots)
        }
        let stride = MemoryLayout<InstanceGPU>.stride
        for (ci, c) in cascades.enumerated() where update[ci] {
            let p = MTLRenderPassDescriptor()
            p.depthAttachment.texture = shadows.map
            p.depthAttachment.slice = ci
            p.depthAttachment.loadAction = .clear
            p.depthAttachment.clearDepth = 1
            p.depthAttachment.storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: p) else { return (cascades, false) }
            enc.setDepthStencilState(shadows.depthState)
            enc.setCullMode(.none)
            enc.setDepthBias(1.5, slopeScale: 2.5, clamp: 0)
            var vp = c.vp
            enc.setVertexBytes(&vp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            enc.setVertexBuffer(ib, offset: 0, index: 2)
            enc.setFragmentBuffer(mats.buffer, offset: 0, index: 3)
            enc.setFragmentBuffer(ts.table, offset: 0, index: 4)
            var now = Float(CACurrentMediaTime() - timeBase)
            enc.setFragmentBytes(&now, length: 4, index: 5)
            let reach = ci == cascades.count - 1 ? Float.infinity : c.split * 1.5 + 60
            var lastVB: MTLBuffer?
            let minRadius = c.texel * 4
            var tris = 0, draws = 0
            defer { shadowStats[ci] = (draws, tris) }
            for phase in 0..<2 {
                enc.setRenderPipelineState(phase == 0 && !noSplit ? shadows.solidPipeline : shadows.pipeline)
                for (m, g, rad) in ready where g.dist <= reach && rad >= minRadius {
                    let parts: [(range: (start: Int, count: Int), first: Int, count: Int)] = phase == 0
                        ? [(m.ranges[0], g.first, g.solid)]
                        : [(m.ranges[3], g.first, g.count), (m.ranges[0], g.first + g.solid, g.count - g.solid)]
                    for part in parts where part.range.count > 0 && part.count > 0 {
                        tris += part.range.count / 3 * part.count
                        draws += 1
                        if lastVB !== m.vertices {
                            enc.setVertexBuffer(m.vertices, offset: 0, index: 0)
                            lastVB = m.vertices
                        }
                        enc.setVertexBufferOffset(part.first * stride, index: 2)
                        enc.drawIndexedPrimitives(type: .triangle, indexCount: part.range.count, indexType: m.indexType, indexBuffer: m.indices,
                                                  indexBufferOffset: part.range.start * m.indexSize, instanceCount: part.count)
                    }
                }
            }
            enc.endEncoding()
        }
        return (cascades, true)
    }

    func readyGroups() -> [(GPUMesh, DrawGroup, UInt32)]? {
        guard showMeshes, let streamer = streamer, let ts = textures, let vis = current, vis.instances != nil else { return nil }
        streamer.frame += 1
        var ready: [(GPUMesh, DrawGroup, UInt32)] = []
        ready.reserveCapacity(vis.groups.count)
        for (gi, g) in vis.groups.enumerated() {
            guard let m = streamer.mesh(g.drawable, lod: g.lod) else { continue }
            ready.append((m, g, UInt32(gi)))
            ts.touch(m.textureSlots)
        }
        return ready
    }

    func bindMeshState(_ enc: MTLRenderCommandEncoder, _ u: inout Uniforms) {
        guard let ts = textures, let mats = materials, let ib = current?.instances else { return }
        var zero: UInt32 = 0
        enc.setFragmentBytes(&zero, length: 4, index: 5)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setVertexBuffer(ib, offset: 0, index: 2)
        enc.setFragmentBuffer(mats.buffer, offset: 0, index: 3)
        enc.setFragmentBuffer(ts.table, offset: 0, index: 4)
    }

    func drawOpaque(_ enc: MTLRenderCommandEncoder, _ ready: [(GPUMesh, DrawGroup, UInt32)], solid: MTLRenderPipelineState, cutout: MTLRenderPipelineState) {
        guard !skipPasses.contains(0) else { return }
        let stride = MemoryLayout<InstanceGPU>.stride
        enc.setDepthStencilState(depthState)
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        for phase in 0..<2 {
            enc.setRenderPipelineState(phase == 0 && !noSplit ? solid : cutout)
            var lastVB: MTLBuffer?
            for (m, g, _) in ready {
                let parts: [(range: (start: Int, count: Int), first: Int, count: Int)] = phase == 0
                    ? [(m.ranges[0], g.first, g.solid)]
                    : [(m.ranges[3], g.first, g.count), (m.ranges[0], g.first + g.solid, g.count - g.solid)]
                for part in parts where part.range.count > 0 && part.count > 0 {
                    if lastVB !== m.vertices {
                        enc.setVertexBuffer(m.vertices, offset: 0, index: 0)
                        lastVB = m.vertices
                    }
                    enc.setVertexBufferOffset(part.first * stride, index: 2)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: part.range.count, indexType: m.indexType, indexBuffer: m.indices,
                                              indexBufferOffset: part.range.start * m.indexSize, instanceCount: part.count)
                    drawCalls += 1
                    mainTris += part.range.count / 3 * part.count
                }
            }
        }
        for (_, g, _) in ready { drawnInstances += g.count }
    }

    func drawMeshes(_ enc: MTLRenderCommandEncoder, _ ready: [(GPUMesh, DrawGroup, UInt32)], passes: [Int],
                    opaque: MTLRenderPipelineState, blend: MTLRenderPipelineState) {
        let stride = MemoryLayout<InstanceGPU>.stride
        for pass in passes where !skipPasses.contains(pass) {
            if pass == 0 {
                enc.setRenderPipelineState(opaque)
                enc.setDepthStencilState(depthState)
                enc.setDepthBias(0, slopeScale: 0, clamp: 0)
            } else if pass == 1 {
                enc.setRenderPipelineState(blend)
                enc.setDepthStencilState(decalDepthState)
                enc.setDepthBias(4, slopeScale: 2, clamp: 0)
            } else {
                enc.setRenderPipelineState(blend)
                enc.setDepthStencilState(decalDepthState)
                enc.setDepthBias(0, slopeScale: 0, clamp: 0)
            }
            var lastVB: MTLBuffer?
            for (m, g, gi) in (pass == 2 ? Array(ready.reversed()) : ready) {
              for r in (pass == 0 ? [m.ranges[0], m.ranges[3]] : [m.ranges[pass]]) {
                guard r.count > 0 else { continue }
                if pickGroups {
                    var id = gi
                    enc.setFragmentBytes(&id, length: 4, index: 5)
                } else if viewMode == 6 {
                    var lv = UInt32(g.level)
                    enc.setFragmentBytes(&lv, length: 4, index: 5)
                }
                if lastVB !== m.vertices {
                    enc.setVertexBuffer(m.vertices, offset: 0, index: 0)
                    lastVB = m.vertices
                }
                enc.setVertexBufferOffset(g.first * stride, index: 2)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: r.count, indexType: m.indexType, indexBuffer: m.indices,
                                          indexBufferOffset: r.start * m.indexSize, instanceCount: g.count)
                drawCalls += 1
                if pass == 0 {
                    drawnInstances += g.count
                    mainTris += r.count / 3 * g.count
                }
              }
            }
        }
    }

    func finishFrame(_ ready: [(GPUMesh, DrawGroup, UInt32)]?) {
        guard let ready = ready, let streamer = streamer, let ts = textures else { return }
        if frameCount % 4 == 1 {
            var want: [UInt32] = []
            for (m, _, _) in ready.prefix(8000) { want += m.textureSlots }
            ts.want(want)
        }
        streamer.evict()
        ts.evict()
    }

    func preview(_ tex: MTLTexture, level: Int) throws -> CGImage {
        let w = max(1, tex.width >> level), h = max(1, tex.height >> level)
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: w, height: h, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]
        cd.storageMode = .shared
        guard let color = device.makeTexture(descriptor: cd), let cmd = queue.makeCommandBuffer() else { throw RendererError.setup("no preview target") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { throw RendererError.setup("no encoder") }
        var lod = Float(level)
        enc.setRenderPipelineState(quadPipeline)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentBytes(&lod, length: 4, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return try image(color)
    }

    func image(_ color: MTLTexture) throws -> CGImage {
        let width = color.width, height = color.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        color.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else { throw RendererError.setup("cannot build image") }
        return img
    }

    func snapshot(width: Int, height: Int) throws -> CGImage {
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: width, height: height, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]
        cd.storageMode = .shared
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: depthFormat, width: width, height: height, mipmapped: false)
        dd.usage = .renderTarget
        dd.storageMode = .private
        guard let color = device.makeTexture(descriptor: cd), let depth = device.makeTexture(descriptor: dd),
              let cmd = queue.makeCommandBuffer() else { throw RendererError.setup("no offscreen target") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.depthAttachment.texture = depth
        if debugUI == nil, ProcessInfo.processInfo.environment["MV_DEBUGUI"] != nil {
            debugUI = try DebugUI(device: device, colorFormat: colorFormat)
        }
        if let ui = debugUI {
            for _ in 0..<3 { ui.frame(renderer: self, state: snapshotDebugState, size: CGSize(width: width, height: height), scale: 1, dt: 1.0 / 60) }
        }
        let needsHistory = atmosphere.hdrCopy.map { $0.width != width || $0.height != height } ?? true
            || (atmosphere.prevCamera.map { simd_distance($0, camera.position) > 1 } ?? true)
        if needsHistory, let warm = queue.makeCommandBuffer() {
            encode(warm, pass: pass, size: CGSize(width: width, height: height))
            warm.commit()
            warm.waitUntilCompleted()
        }
        taaAccumulating = taaEnabled
        defer { taaAccumulating = false }
        if taaAccumulating {
            for _ in 0..<Renderer.snapshotTAAFrames {
                guard let c = queue.makeCommandBuffer() else { break }
                encode(c, pass: pass, size: CGSize(width: width, height: height))
                c.commit()
            }
        }
        let te = CACurrentMediaTime()
        encode(cmd, pass: pass, size: CGSize(width: width, height: height))
        benchEncode += CACurrentMediaTime() - te
        cmd.commit()
        cmd.waitUntilCompleted()
        benchGPU += cmd.gpuEndTime - cmd.gpuStartTime
        return try image(color)
    }
}

enum RendererError: Error {
    case setup(String)
}
