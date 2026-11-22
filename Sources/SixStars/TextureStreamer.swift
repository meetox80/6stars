import Foundation
import Metal
import RPFKit

final class TextureStreamer {
    let device: MTLDevice
    let db: TextureDB
    let lock = NSLock()
    let capacity = 400_000
    let table: MTLBuffer
    let residency: MTLResidencySet
    let fallbacks: [MTLTexture]
    var slotOf: [UInt64: UInt32] = [:]
    var hashOf: [UInt64] = []
    var fallbackOf: [UInt8] = []
    var usedFrame: UnsafeMutablePointer<Int32>
    var textures: [UInt32: (texture: MTLTexture, bytes: Int)] = [:]
    var failed = Set<UInt32>()
    var inFlight = Set<UInt32>()
    var queue: [UInt32] = []
    var graveyard: [(texture: MTLTexture, frame: Int)] = []
    var totalBytes = 0
    var frame = 0
    var residencyDirty = false
    var budget = 8 << 30
    let maxInFlight = 6
    let work = DispatchQueue(label: "texture-decode", qos: .utility, attributes: .concurrent)

    init(device: MTLDevice, db: TextureDB, queue commandQueue: MTLCommandQueue) {
        self.device = device
        self.db = db
        table = device.makeBuffer(length: capacity * 8, options: .storageModeShared)!
        let rd = MTLResidencySetDescriptor()
        rd.initialCapacity = 65536
        residency = try! device.makeResidencySet(descriptor: rd)
        func solid(_ px: [UInt8], _ format: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            let t = device.makeTexture(descriptor: d)!
            px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
            return t
        }
        fallbacks = [solid([150, 146, 140, 255], .rgba8Unorm_srgb), solid([128, 128, 255, 255], .rgba8Unorm), solid([0, 153, 255, 255], .rgba8Unorm)]
        usedFrame = UnsafeMutablePointer<Int32>.allocate(capacity: capacity)
        usedFrame.initialize(repeating: 0, count: capacity)
        for t in fallbacks { residency.addAllocation(t) }
        residency.commit()
        commandQueue.addResidencySet(residency)
        for (i, t) in fallbacks.prefix(2).enumerated() {
            hashOf.append(0)
            fallbackOf.append(UInt8(i))
            table.contents().advanced(by: i * 8).storeBytes(of: t.gpuResourceID, as: MTLResourceID.self)
        }
    }

    func exists(_ hash: UInt64) -> Bool { hash != 0 && db.find(hash) != nil }

    func specSlot(_ hash: UInt64) -> UInt32 {
        guard exists(hash) else { return 0 }
        return slot(hash, fallback: 2)
    }

    func slot(_ hash: UInt64, normal: Bool) -> UInt32 {
        let fb: UInt32 = normal ? 1 : 0
        guard exists(hash) else { return fb }
        return slot(hash, fallback: fb)
    }

    private func slot(_ hash: UInt64, fallback fb: UInt32) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        if let s = slotOf[hash] { return s }
        guard hashOf.count < capacity else { return fb }
        let s = UInt32(hashOf.count)
        hashOf.append(hash)
        fallbackOf.append(UInt8(fb))
        slotOf[hash] = s
        table.contents().advanced(by: Int(s) * 8).storeBytes(of: fallbacks[Int(fb)].gpuResourceID, as: MTLResourceID.self)
        return s
    }

    func load(_ slot: UInt32) -> MTLTexture? {
        lock.lock()
        let hash = hashOf[Int(slot)]
        lock.unlock()
        guard let (f, i) = db.find(hash), let img = try? f.image(i) else { return nil }
        return GPUTexture.make(device, img)
    }

    func install(_ slot: UInt32, _ tex: MTLTexture) {
        textures[slot] = (tex, tex.allocatedSize)
        totalBytes += tex.allocatedSize
        residency.addAllocation(tex)
        residencyDirty = true
        table.contents().advanced(by: Int(slot) * 8).storeBytes(of: tex.gpuResourceID, as: MTLResourceID.self)
        usedFrame[Int(slot)] = Int32(frame)
    }

    func finish(_ slot: UInt32, _ tex: MTLTexture?) {
        lock.lock()
        inFlight.remove(slot)
        if let t = tex { install(slot, t) } else { failed.insert(slot) }
        lock.unlock()
        pump()
    }

    func isPending(_ s: UInt32) -> Bool { s >= 2 && textures[s] == nil && !failed.contains(s) && !inFlight.contains(s) }

    func want(_ ordered: [UInt32]) {
        lock.lock()
        var seen = Set<UInt32>()
        queue = ordered.filter { isPending($0) && seen.insert($0).inserted }
        lock.unlock()
        pump()
    }

    func pump() {
        lock.lock()
        var start: [UInt32] = []
        while inFlight.count < maxInFlight, !queue.isEmpty {
            let s = queue.removeFirst()
            guard isPending(s) else { continue }
            inFlight.insert(s)
            start.append(s)
        }
        lock.unlock()
        for s in start {
            work.async { [weak self] in
                guard let self = self else { return }
                self.finish(s, self.load(s))
            }
        }
    }

    func loadBlocking(_ slots: [UInt32]) {
        lock.lock()
        let todo = Array(Set(slots.filter { isPending($0) }))
        lock.unlock()
        let out = UnsafeMutableBufferPointer<MTLTexture?>.allocate(capacity: todo.count)
        out.initialize(repeating: nil)
        defer { out.deallocate() }
        DispatchQueue.concurrentPerform(iterations: todo.count) { i in out[i] = load(todo[i]) }
        lock.lock()
        for (i, s) in todo.enumerated() {
            if let t = out[i] { install(s, t) } else { failed.insert(s) }
        }
        lock.unlock()
    }

    @inline(__always) func touch(_ slots: [UInt32]) {
        let f = Int32(frame)
        for s in slots { usedFrame[Int(s)] = f }
    }

    func beginFrame() {
        frame += 1
        lock.lock()
        var changed = residencyDirty
        residencyDirty = false
        if !graveyard.isEmpty {
            let dead = graveyard.filter { frame - $0.frame > 4 }
            if !dead.isEmpty {
                for d in dead { residency.removeAllocation(d.texture) }
                graveyard.removeAll { frame - $0.frame > 4 }
                changed = true
            }
        }
        lock.unlock()
        if changed { residency.commit() }
    }

    func evict() {
        lock.lock()
        defer { lock.unlock() }
        guard totalBytes > budget else { return }
        let f = Int32(frame)
        let old = textures.filter { f - usedFrame[Int($0.key)] > 120 }.sorted { usedFrame[Int($0.key)] < usedFrame[Int($1.key)] }
        for (s, e) in old {
            if totalBytes <= budget * 9 / 10 { break }
            textures.removeValue(forKey: s)
            totalBytes -= e.bytes
            table.contents().advanced(by: Int(s) * 8).storeBytes(of: fallbacks[Int(fallbackOf[Int(s)])].gpuResourceID, as: MTLResourceID.self)
            graveyard.append((e.texture, frame))
        }
    }

    var stats: (loaded: Int, pending: Int, failed: Int, bytes: Int, slots: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (textures.count, inFlight.count + queue.count, failed.count, totalBytes, hashOf.count)
    }
}
