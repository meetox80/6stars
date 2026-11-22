import Foundation
import Metal
import simd

final class GameTAA {
    static let directory = "\(NSHomeDirectory())/testing/6stars-data/rdna/taa"
    static let kernelFile = "_TemporalAA_CS_ApplyTemporalAA_b2b938f9_Wrapped.metal"
    static let ringSize = 3
    static let tableT = 0x340
    static let tableX = 0x100
    static let cbBytes = 0x200

    static let prepSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void taaPrep(depth2d<float> depth [[texture(0)]], texture2d<float, access::write> lin [[texture(1)]],
                        texture2d<float, access::write> flags [[texture(2)]], texture2d<float, access::write> expo [[texture(3)]],
                        device const float* state [[buffer(0)]], constant float& key [[buffer(1)]],
                        uint2 p [[thread_position_in_grid]]) {
        int2 sz = int2(depth.get_width(), depth.get_height());
        if (int(p.x) >= sz.x || int(p.y) >= sz.y) return;
        float d = depth.read(p);
        lin.write(float4(d, 0.0, 0.0, 0.0), p);
        float best = d;
        int2 o = int2(0);
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                int2 q = clamp(int2(p) + int2(x, y), int2(0), sz - 1);
                float e = depth.read(uint2(q));
                if (e > best) { best = e; o = int2(x, y); }
            }
        }
        uint bx = o.x < 0 ? 1u : (o.x > 0 ? 2u : 0u);
        uint by = o.y < 0 ? 1u : (o.y > 0 ? 2u : 0u);
        flags.write(float4(0.0, 0.0, float(by | (bx << 2)) / 255.0, 0.0), p);
        if (p.x == 0 && p.y == 0) expo.write(float4(0.0, log(max(key, 1e-6)) - state[0], 0.0, 0.0), uint2(0));
    }
    """

    let device: MTLDevice
    let rt: RDNARuntime
    let kernel: RDNARuntime.Kernel
    let prep: MTLComputePipelineState
    let ring: [(t: UInt64, x: UInt64, cb0: UInt64, cbA: UInt64, cbB: UInt64, cbX: UInt64, view: UInt64)]
    var ringIndex = 0
    var width = 0, height = 0
    var source: MTLTexture?
    var depthLin: MTLTexture!
    var flags: MTLTexture!
    var prevFlags: MTLTexture!
    var weight: MTLTexture!
    var halfDist: MTLTexture!
    var velocity: MTLTexture!
    var exposure: MTLTexture!
    var sideCurrent: MTLTexture!
    var side: [MTLTexture] = []
    var history: [MTLTexture] = []
    var output: MTLTexture!
    var slot: [ObjectIdentifier: Int] = [:]
    var historyIndex = 0

    init?(device: MTLDevice) {
        let dir = GameTAA.directory
        guard ProcessInfo.processInfo.environment["MV_GAMETAA"] == "1",
              FileManager.default.fileExists(atPath: "\(dir)/\(GameTAA.kernelFile)"),
              FileManager.default.fileExists(atPath: "\(dir)/rdna_rt.h") else { return nil }
        do {
            self.device = device
            rt = try RDNARuntime(device: device, headerPath: "\(dir)/rdna_rt.h")
            kernel = try rt.compileKernel(path: "\(dir)/\(GameTAA.kernelFile)", threads: 32)
            let lib = try device.makeLibrary(source: GameTAA.prepSource, options: nil)
            prep = try device.makeComputePipelineState(function: lib.makeFunction(name: "taaPrep")!)
        } catch {
            FileHandle.standardError.write("game TAA unavailable: \(error)\n".data(using: .utf8)!)
            return nil
        }
        var r: [(t: UInt64, x: UInt64, cb0: UInt64, cbA: UInt64, cbB: UInt64, cbX: UInt64, view: UInt64)] = []
        for _ in 0..<GameTAA.ringSize {
            r.append((rt.alloc(GameTAA.tableT), rt.alloc(GameTAA.tableX), rt.alloc(GameTAA.cbBytes), rt.alloc(256),
                      rt.alloc(256), rt.alloc(256), rt.alloc(GameTAA.cbBytes)))
        }
        ring = r
    }

    func texture(_ f: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(w, 1), height: max(h, 1), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    func ensure(source cur: MTLTexture, cmd: MTLCommandBuffer) {
        if cur === source && cur.width == width && cur.height == height { return }
        width = cur.width
        height = cur.height
        source = cur
        depthLin = texture(.r32Float, width, height)
        flags = texture(.rgba8Unorm, width, height)
        prevFlags = texture(.rg8Unorm, width, height)
        weight = texture(.r8Unorm, width, height)
        halfDist = texture(.r16Float, (width + 1) / 2, (height + 1) / 2)
        velocity = texture(.rg16Float, width, height)
        exposure = texture(.rg32Float, 1, 1)
        sideCurrent = texture(.r16Float, width, height)
        side = (0..<2).map { _ in texture(.r16Float, width, height) }
        history = (0..<2).map { _ in texture(.rgba16Float, width, height) }
        output = texture(.rgba16Float, width, height)
        var zeroed: [MTLTexture] = [prevFlags, weight, halfDist, velocity, sideCurrent, output]
        zeroed.append(contentsOf: side)
        zeroed.append(contentsOf: history)
        if let blit = cmd.makeBlitCommandEncoder() {
            for t in zeroed {
                let bpp = t.pixelFormat == .rgba16Float ? 8 : t.pixelFormat == .rg16Float ? 4 : t.pixelFormat == .r16Float || t.pixelFormat == .rg8Unorm ? 2 : 1
                let bytes = t.width * t.height * bpp
                if let b = device.makeBuffer(length: bytes, options: .storageModePrivate) {
                    blit.fill(buffer: b, range: 0..<bytes, value: 0)
                    blit.copy(from: b, sourceOffset: 0, sourceBytesPerRow: t.width * bpp, sourceBytesPerImage: bytes,
                              sourceSize: MTLSize(width: t.width, height: t.height, depth: 1), to: t, destinationSlice: 0,
                              destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                }
            }
            blit.endEncoding()
        }
        rt.resident.removeAll()
        rt.nextSlot = 1
        slot.removeAll()
        for t in [cur] { slot[ObjectIdentifier(t)] = rt.register(t, in: [.t2d]) }
        var writable: [MTLTexture] = [depthLin, flags, prevFlags, weight, halfDist, velocity, exposure, sideCurrent, output]
        writable.append(contentsOf: side)
        writable.append(contentsOf: history)
        for t in writable {
            slot[ObjectIdentifier(t)] = rt.register(t, in: [.t2d, .w2d])
        }
        historyIndex = 0
    }

    func tdesc(_ t: MTLTexture) -> [UInt32] {
        rt.tdesc(slot: slot[ObjectIdentifier(t)]!, tex: t)
    }

    static func weights(jitterPixels j: SIMD2<Float>) -> [Float] {
        var w: [Float] = []
        for y in -1...1 {
            for x in -1...1 {
                let d = SIMD2<Float>(Float(x), Float(y)) - j
                w.append(exp(-2.29 * simd_length_squared(d)))
            }
        }
        return w
    }

    func upload(_ cmd: MTLCommandBuffer, _ items: [(UInt64, [UInt32])]) {
        guard let blit = cmd.makeBlitCommandEncoder() else { return }
        for (addr, words) in items {
            guard let b = words.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { continue }
            blit.copy(from: b, sourceOffset: 0, to: rt.arena, destinationOffset: Int(addr), size: words.count * 4)
        }
        blit.endEncoding()
    }

    func resolve(_ cmd: MTLCommandBuffer, a: AtmosGPU, hdr cur: MTLTexture, depth: MTLTexture, prevViewProj: simd_float4x4,
                 reset: Bool, exposureState: MTLBuffer) -> MTLTexture? {
        ensure(source: cur, cmd: cmd)
        var key = a.expo.x
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(prep)
            enc.setTexture(depth, index: 0)
            enc.setTexture(depthLin, index: 1)
            enc.setTexture(flags, index: 2)
            enc.setTexture(exposure, index: 3)
            enc.setBuffer(exposureState, offset: 0, index: 0)
            enc.setBytes(&key, length: 4, index: 1)
            enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            enc.endEncoding()
        }
        let r = ring[ringIndex]
        ringIndex = (ringIndex + 1) % GameTAA.ringSize
        let w = Float(width), h = Float(height)
        let histWeight: Float = reset ? 0 : 1 - Atmosphere.taaBlend
        let jit = SIMD2<Float>(a.taa.x * w * 0.5, -a.taa.y * h * 0.5)
        var cb0 = [Float](repeating: 0, count: GameTAA.cbBytes / 4)
        cb0[0] = 1 / w; cb0[1] = 1 / h; cb0[2] = w; cb0[3] = h
        cb0[4] = 0; cb0[5] = 0
        cb0[8] = 1; cb0[9] = 1
        cb0[10] = -a.misc.w; cb0[11] = -1
        let toWorld = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(a.camPos.x, a.camPos.y, a.camPos.z, 1)))
        for c in 0..<4 { for k in 0..<4 { cb0[16 + c * 4 + k] = toWorld[c][k] } }
        cb0[54] = histWeight; cb0[55] = histWeight
        cb0[58] = 1; cb0[59] = 0
        cb0[60] = 0; cb0[61] = 0; cb0[62] = histWeight
        cb0[69] = 0.1
        cb0[71] = 0
        cb0[72] = 1.25; cb0[73] = 1.25; cb0[74] = 1; cb0[75] = 1.25
        cb0[76] = 0
        cb0[77] = reset ? 1e30 : 0
        cb0[78] = reset ? 2e30 : 1
        let fw = GameTAA.weights(jitterPixels: -jit)
        for i in 0..<9 { cb0[84 + i] = fw[i] }
        for item in (ProcessInfo.processInfo.environment["MV_GTAA_CB"] ?? "").split(separator: ",") {
            let kv = item.split(separator: ":")
            if kv.count == 2, let i = Int(kv[0], radix: 16), let v = Float(kv[1]), i / 4 < cb0.count { cb0[i / 4] = v }
        }
        var uploads: [(UInt64, [UInt32])] = []
        uploads.append((r.cb0, cb0.map { $0.bitPattern }))
        uploads.append((r.cbA, [Float(1), 0, 0, 0].map { $0.bitPattern }))
        var cbB = [Float](repeating: 0, count: 32)
        cbB[14] = 1e5; cbB[17] = w; cbB[18] = h
        uploads.append((r.cbB, cbB.map { $0.bitPattern }))
        uploads.append((r.cbX, [Float(1), 1, 0, 0].map { $0.bitPattern }))
        var view = [Float](repeating: 0, count: GameTAA.cbBytes / 4)
        let rx = SIMD3(a.camRight.x, a.camRight.y, a.camRight.z) * a.camRight.w
        let uy = SIMD3(a.camUp.x, a.camUp.y, a.camUp.z) * a.camUp.w
        let f = SIMD3(a.camFwd.x, a.camFwd.y, a.camFwd.z)
        view[32] = rx.x; view[33] = rx.y; view[34] = rx.z
        view[36] = uy.x; view[37] = uy.y; view[38] = uy.z
        view[40] = -f.x; view[41] = -f.y; view[42] = -f.z
        for c in 0..<4 { for k in 0..<4 { view[104 + c * 4 + k] = prevViewProj[c][k] } }
        uploads.append((r.view, view.map { $0.bitPattern }))
        let prevHist = history[historyIndex], nextHist = history[1 - historyIndex]
        let prevSide = side[historyIndex], nextSide = side[1 - historyIndex]
        var tw = [UInt32](repeating: 0, count: GameTAA.tableT / 4)
        func put(_ off: Int, _ words: [UInt32]) { for (i, x) in words.enumerated() { tw[off / 4 + i] = x } }
        put(0x00, rt.vdesc(addr: r.cbA, bytes: 256))
        put(0x20, rt.vdesc(addr: r.cbB, bytes: 256))
        put(0x40, tdesc(sideCurrent))
        put(0x60, tdesc(prevFlags))
        put(0xA0, tdesc(velocity))
        put(0x100, tdesc(depthLin))
        put(0x120, tdesc(exposure))
        put(0x140, tdesc(prevHist))
        put(0x180, tdesc(cur))
        put(0x1A0, tdesc(flags))
        put(0x200, tdesc(prevSide))
        put(0x240, tdesc(weight))
        put(0x260, tdesc(halfDist))
        put(0x2A0, tdesc(nextHist))
        put(0x2C0, tdesc(output))
        put(0x2E0, tdesc(nextSide))
        put(0x300, rt.vdesc(addr: r.view, bytes: GameTAA.cbBytes))
        put(0x320, rt.vdesc(addr: r.cb0, bytes: GameTAA.cbBytes))
        uploads.append((r.t, tw))
        var xw = [UInt32](repeating: 0, count: GameTAA.tableX / 4)
        let cbx = rt.vdesc(addr: r.cbX, bytes: 256)
        for i in 0..<4 { xw[0x80 / 4 + i] = cbx[i] }
        uploads.append((r.x, xw))
        upload(cmd, uploads)
        rt.dispatch(cmd, kernel, user: [0, 0, 0, 0, UInt32(r.x), UInt32(r.t)],
                    groups: MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1))
        historyIndex = 1 - historyIndex
        return output
    }
}
