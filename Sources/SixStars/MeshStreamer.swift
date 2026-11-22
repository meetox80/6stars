import Foundation
import Metal
import RPFKit
import simd

struct GPUVertex {
    var x: Float
    var y: Float
    var z: Float
    var normal: UInt32
    var u: Float
    var v: Float
    var uv1: UInt32
    var color0: UInt32
    var color1: UInt32
    var material: UInt32
}

final class GPUMesh {
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let indexType: MTLIndexType
    let ranges: [(start: Int, count: Int)]
    let textureSlots: [UInt32]
    let bytes: Int
    let lod: Int
    var lastUsed: Int = 0

    init(vertices: MTLBuffer, indices: MTLBuffer, indexType: MTLIndexType, ranges: [(start: Int, count: Int)], textureSlots: [UInt32], lod: Int) {
        self.vertices = vertices
        self.indices = indices
        self.indexType = indexType
        self.ranges = ranges
        self.textureSlots = textureSlots
        self.lod = lod
        bytes = vertices.length + indices.length
    }

    var indexSize: Int { indexType == .uint16 ? 2 : 4 }
}

final class MeshStreamer {
    let device: MTLDevice
    let scene: Scene
    let textures: TextureStreamer
    let materials: MaterialRegistry
    let lock = NSLock()
    var meshes: [Int64: GPUMesh] = [:]
    var failed = Set<Int64>()
    var inFlight = Set<Int64>()
    var queue: [Int64] = []
    var totalBytes = 0
    var frame = 0
    var budget = 10 << 30
    let maxInFlight = max(8, ProcessInfo.processInfo.activeProcessorCount * 2)
    let lodTable: UnsafeMutablePointer<UInt64>
    let work = DispatchQueue(label: "mesh-decode", qos: .utility, attributes: .concurrent)

    init(device: MTLDevice, scene: Scene, textures: TextureStreamer, materials: MaterialRegistry) {
        self.device = device
        self.scene = scene
        self.textures = textures
        self.materials = materials
        let n = scene.catalog.entries.count
        lodTable = UnsafeMutablePointer<UInt64>.allocate(capacity: n)
        lodTable.initialize(repeating: 0, count: n)
    }

    static func key(_ drawable: Int32, _ lod: Int) -> Int64 { Int64(drawable) << 2 | Int64(lod) }

    func lodInfo(_ drawable: Int32) -> (dist: SIMD4<Float>, known: Bool) {
        let v = lodTable[Int(drawable)]
        guard v != 0 else { return (SIMD4(repeating: 0), false) }
        let d = SIMD4<Float>(Float(Float16(bitPattern: UInt16(v & 0xFFFF))), Float(Float16(bitPattern: UInt16((v >> 16) & 0xFFFF))),
                             Float(Float16(bitPattern: UInt16((v >> 32) & 0xFFFF))), Float(Float16(bitPattern: UInt16(v >> 48))))
        return (d, true)
    }

    func recordLod(_ drawable: Int32, _ m: MeshData) {
        guard m.lodPresent.count == 4, m.lodDistances.count == 4 else { return }
        var v: UInt64 = 0
        for i in 0..<4 {
            var d = m.lodPresent[i] ? m.lodDistances[i] : 0
            if !d.isFinite || d < 0 { d = 0 }
            if m.lodPresent[i] && d <= 0 { d = 0.01 }
            v |= UInt64(Float16(min(d, 60000)).bitPattern) << (16 * UInt64(i))
        }
        if v == 0 { v = 1 }
        lodTable[Int(drawable)] = v
    }

    static func packNormal(_ n: SIMD3<Float>) -> UInt32 {
        func c(_ x: Float) -> UInt32 { UInt32(max(0, min(1023, ((x * 0.5 + 0.5) * 1023).rounded()))) }
        return c(n.x) | c(n.y) << 10 | c(n.z) << 20
    }

    static func half2(_ v: SIMD2<Float>) -> UInt32 {
        func h(_ x: Float) -> UInt32 { UInt32(Float16(max(-65000, min(65000, x.isFinite ? x : 0))).bitPattern) }
        return h(v.x) | h(v.y) << 16
    }

    func material(_ s: ShaderInfo) -> (id: UInt32, kind: MaterialKind, slots: [UInt32], cut: Bool) {
        let d = ShaderTable.describe(s, exists: textures.exists)
        var diff = [UInt32](repeating: 0, count: 4), norm = [UInt32](repeating: 1, count: 4)
        let layers = d.scheme == .baseRGB ? 4 : (d.scheme == .single ? 1 : 2)
        for i in 0..<min(4, d.diffuse.count) { diff[i] = textures.slot(d.diffuse[i], normal: false) }
        for i in 0..<min(4, d.normal.count) { norm[i] = textures.slot(d.normal[i], normal: true) }
        var flags = d.flags
        if norm.prefix(layers).allSatisfy({ $0 == 1 }) { flags &= ~MaterialFlags.normalMap }
        let spec = d.spec != 0 ? textures.specSlot(d.spec) : 0
        let gm = GPUMaterial(diffuse: (diff[0], diff[1], diff[2], diff[3]), normal: (norm[0], norm[1], norm[2], norm[3]),
                             kind: d.kind.rawValue, scheme: d.scheme.rawValue, flags: flags, layers: UInt32(layers), spec: spec)
        let key = "\(d.kind.rawValue)|\(d.scheme.rawValue)|\(flags)|\(diff)|\(norm)|\(spec)"
        let slots = (diff.prefix(layers) + norm.prefix(layers) + [spec]).filter { $0 >= 2 }
        return (materials.add(gm, key: key), d.kind, slots, d.kind == .cutout || (flags & MaterialFlags.alphaTest) != 0)
    }

    func build(_ m: MeshData) -> GPUMesh? {
        let mats = m.shaders.map { material($0) }
        let n = m.positions.count
        var verts = [GPUVertex]()
        verts.reserveCapacity(n)
        for i in 0..<n {
            let p = m.positions[i]
            let nn = i < m.normals.count ? m.normals[i] : SIMD3(0, 0, 1)
            let t = i < m.uvs.count ? m.uvs[i] : .zero
            let t1 = i < m.uvs1.count ? m.uvs1[i] : t
            verts.append(GPUVertex(x: p.x, y: p.y, z: p.z, normal: MeshStreamer.packNormal(nn), u: t.x, v: t.y, uv1: MeshStreamer.half2(t1),
                                   color0: i < m.colors0.count ? m.colors0[i] : 0xFFFF_FFFF,
                                   color1: i < m.colors1.count ? m.colors1[i] : 0xFF00_0000, material: 0))
        }
        var lists: [[UInt32]] = [[], [], [], []]
        var slotSet = Set<UInt32>()
        for part in m.parts {
            let mat = part.shader < mats.count ? mats[part.shader] : (id: UInt32(0), kind: MaterialKind.opaque, slots: [], cut: false)
            let pass: Int
            switch mat.kind {
            case .hidden: continue
            case .opaque, .cutout: pass = mat.cut ? 3 : 0
            case .decal: pass = 1
            case .alpha, .water: pass = 2
            }
            for s in mat.slots { slotSet.insert(s) }
            let idx = m.indices[part.indexStart..<part.indexStart + part.indexCount]
            for v in idx { verts[Int(v)].material = mat.id }
            lists[pass].append(contentsOf: idx)
        }
        let total = lists.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        var ranges: [(start: Int, count: Int)] = []
        var start = 0
        for l in lists {
            ranges.append((start, l.count))
            start += l.count
        }
        let all = lists.flatMap { $0 }
        let small = n <= 65535
        let ib: MTLBuffer?
        if small {
            let i16 = all.map { UInt16($0) }
            ib = device.makeBuffer(bytes: i16, length: i16.count * 2, options: .storageModeShared)
        } else {
            ib = device.makeBuffer(bytes: all, length: all.count * 4, options: .storageModeShared)
        }
        guard let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<GPUVertex>.stride, options: .storageModeShared),
              let ib = ib else { return nil }
        return GPUMesh(vertices: vb, indices: ib, indexType: small ? .uint16 : .uint32, ranges: ranges, textureSlots: Array(slotSet), lod: m.lod)
    }

    func load(_ key: Int64) -> GPUMesh? {
        let id = Int32(key >> 2), lod = Int(key & 3)
        let e = scene.catalog.entries[Int(id)]
        guard let m = try? Drawable.load(scene.index, scene.file, resource: e.resource, base: Int(e.base), lod: lod) else { return nil }
        recordLod(id, m)
        return build(m)
    }

    func isFailed(_ key: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed.contains(key)
    }

    func finish(_ key: Int64, _ mesh: GPUMesh?) {
        lock.lock()
        inFlight.remove(key)
        if let mesh = mesh {
            mesh.lastUsed = frame
            meshes[key] = mesh
            totalBytes += mesh.bytes
        } else {
            failed.insert(key)
        }
        lock.unlock()
        pump()
    }

    func want(_ ordered: [Int64]) {
        lock.lock()
        queue = ordered.filter { meshes[$0] == nil && !failed.contains($0) && !inFlight.contains($0) }
        lock.unlock()
        pump()
    }

    func pump() {
        lock.lock()
        var start: [Int64] = []
        while inFlight.count < maxInFlight, !queue.isEmpty {
            let k = queue.removeFirst()
            if meshes[k] != nil || failed.contains(k) || inFlight.contains(k) { continue }
            inFlight.insert(k)
            start.append(k)
        }
        lock.unlock()
        for k in start {
            work.async { [weak self] in
                guard let self = self else { return }
                self.finish(k, self.load(k))
            }
        }
    }

    func loadBlocking(_ keys: [Int64]) {
        lock.lock()
        let todo = Array(Set(keys.filter { meshes[$0] == nil && !failed.contains($0) }))
        lock.unlock()
        let out = UnsafeMutableBufferPointer<GPUMesh?>.allocate(capacity: todo.count)
        out.initialize(repeating: nil)
        defer { out.deallocate() }
        DispatchQueue.concurrentPerform(iterations: todo.count) { i in out[i] = load(todo[i]) }
        lock.lock()
        for (i, k) in todo.enumerated() {
            if let m = out[i] {
                meshes[k] = m
                totalBytes += m.bytes
            } else {
                failed.insert(k)
            }
        }
        lock.unlock()
    }

    func mesh(_ drawable: Int32, lod: Int) -> GPUMesh? {
        lock.lock()
        defer { lock.unlock() }
        if let m = meshes[MeshStreamer.key(drawable, lod)] {
            m.lastUsed = frame
            return m
        }
        for d in [1, -1, 2, -2, 3, -3] {
            let l = lod + d
            guard l >= 0, l < 4, let m = meshes[MeshStreamer.key(drawable, l)] else { continue }
            m.lastUsed = frame
            return m
        }
        return nil
    }

    func hasMesh(_ drawable: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        for l in 0..<4 {
            if let m = meshes[MeshStreamer.key(drawable, l)] {
                m.lastUsed = frame
                return true
            }
        }
        return false
    }

    func evict() {
        lock.lock()
        defer { lock.unlock() }
        guard totalBytes > budget else { return }
        let old = meshes.filter { frame - $0.value.lastUsed > 120 }.sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (k, m) in old {
            if totalBytes <= budget * 9 / 10 { break }
            meshes.removeValue(forKey: k)
            totalBytes -= m.bytes
        }
    }

    var stats: (loaded: Int, pending: Int, failed: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (meshes.count, inFlight.count + queue.count, failed.count, totalBytes)
    }
}
