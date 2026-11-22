import Foundation
import Metal
import simd

struct IndirectParams {
    var prevVP: simd_float4x4
    var info: SIMD4<Float>
}

struct CubeParams {
    var face: UInt32
    var roughness: Float
    var srcMips: Float
    var srcSize: Float
}

final class Deferred {
    static let gbFormats: [MTLPixelFormat] = [.rgba8Unorm_srgb, .rgb10a2Unorm, .rgba8Unorm]
    static let envSize = 128
    static let envInterval = 8

    let device: MTLDevice
    let gbufferPipe: MTLRenderPipelineState
    let gbufferSolidPipe: MTLRenderPipelineState
    let decalPipe: MTLRenderPipelineState
    let skyPipe: MTLRenderPipelineState
    let ssaoPipe: MTLRenderPipelineState
    let blurPipe: MTLRenderPipelineState
    let lightPipe: MTLRenderPipelineState
    let envFacePipe: MTLRenderPipelineState
    let envPrefilterPipe: MTLRenderPipelineState
    let indirectPipe: MTLRenderPipelineState
    let accumPipe: MTLRenderPipelineState
    var giTex: MTLTexture?
    var reflTex: MTLTexture?
    var giHist: [MTLTexture] = []
    var reflHist: [MTLTexture] = []
    var histIndex = 0
    var giOut: MTLTexture?
    var reflOut: MTLTexture?
    static let indirectBlend: Float = 0.12
    var giEnabled = ProcessInfo.processInfo.environment["MV_NOINDIRECT"] == nil
    var reflectionsEnabled = ProcessInfo.processInfo.environment["MV_NOINDIRECT"] == nil
    var indirectFrame = 0
    var giMultiplier: Float = 1
    let envSrc: MTLTexture
    let env: MTLTexture
    var gb: [MTLTexture] = []
    var aoRaw: MTLTexture?
    var ao: MTLTexture?
    var envFrame = 0
    var envReady = false
    static let occlusionSize = (160, 90)
    let occlusionPipe: MTLComputePipelineState
    let occlusionBuffers: [MTLBuffer]
    var occlusionIndex = 0

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        func fn(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw RendererError.setup("missing shader \(name)") }
            return f
        }
        func gbuffer(_ vs: String, _ fs: String, blend: Bool, onlyEmissive: Bool, solid: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try fn(vs)
            if fs == "meshGBuffer" {
                let cv = MTLFunctionConstantValues()
                var canDiscard = !solid
                cv.setConstantValue(&canDiscard, type: .bool, index: 0)
                d.fragmentFunction = try library.makeFunction(name: fs, constantValues: cv)
            } else {
                d.fragmentFunction = try fn(fs)
            }
            for (i, f) in Deferred.gbFormats.enumerated() {
                d.colorAttachments[i].pixelFormat = f
                if onlyEmissive || (blend && i > 0) { d.colorAttachments[i].writeMask = [] }
            }
            d.colorAttachments[3].pixelFormat = Atmosphere.hdrFormat
            d.depthAttachmentPixelFormat = .depth32Float
            if blend {
                for i in [0, 3] {
                    d.colorAttachments[i].isBlendingEnabled = true
                    d.colorAttachments[i].sourceRGBBlendFactor = .sourceAlpha
                    d.colorAttachments[i].destinationRGBBlendFactor = .oneMinusSourceAlpha
                    d.colorAttachments[i].sourceAlphaBlendFactor = .zero
                    d.colorAttachments[i].destinationAlphaBlendFactor = .one
                }
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        func simple(_ fs: String, _ format: MTLPixelFormat, additive: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try fn("quadVertex")
            d.fragmentFunction = try fn(fs)
            d.colorAttachments[0].pixelFormat = format
            if additive {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .one
                d.colorAttachments[0].sourceAlphaBlendFactor = .zero
                d.colorAttachments[0].destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        gbufferPipe = try gbuffer("meshVertex", "meshGBuffer", blend: false, onlyEmissive: false)
        gbufferSolidPipe = try gbuffer("meshVertex", "meshGBuffer", blend: false, onlyEmissive: false, solid: true)
        decalPipe = try gbuffer("meshVertex", "meshGBuffer", blend: true, onlyEmissive: false)
        skyPipe = try gbuffer("quadVertex", "skyFragment", blend: false, onlyEmissive: true)
        ssaoPipe = try simple("ssaoFragment", .r16Float)
        blurPipe = try simple("ssaoBlurFragment", .r16Float)
        lightPipe = try simple("lightFragment", Atmosphere.hdrFormat, additive: true)
        envFacePipe = try simple("envFaceFragment", Atmosphere.hdrFormat)
        envPrefilterPipe = try simple("envPrefilterFragment", Atmosphere.hdrFormat)
        let id = MTLRenderPipelineDescriptor()
        id.vertexFunction = try fn("quadVertex")
        id.fragmentFunction = try fn("indirectFragment")
        id.colorAttachments[0].pixelFormat = .rgba16Float
        id.colorAttachments[1].pixelFormat = .rgba16Float
        indirectPipe = try device.makeRenderPipelineState(descriptor: id)
        id.fragmentFunction = try fn("indirectAccumFragment")
        accumPipe = try device.makeRenderPipelineState(descriptor: id)
        func cube() throws -> MTLTexture {
            let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: Atmosphere.hdrFormat, size: Deferred.envSize, mipmapped: true)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.setup("no environment cube") }
            return t
        }
        envSrc = try cube()
        env = try cube()
        occlusionPipe = try device.makeComputePipelineState(function: try fn("occlusionKernel"))
        let bytes = Deferred.occlusionSize.0 * Deferred.occlusionSize.1 * 4
        occlusionBuffers = try (0..<3).map { _ in
            guard let b = device.makeBuffer(length: bytes, options: .storageModeShared) else { throw RendererError.setup("no occlusion buffer") }
            return b
        }
    }

    func reduceDepth(_ cmd: MTLCommandBuffer, depth: MTLTexture) -> MTLBuffer? {
        guard let c = cmd.makeComputeCommandEncoder() else { return nil }
        let buf = occlusionBuffers[occlusionIndex]
        occlusionIndex = (occlusionIndex + 1) % occlusionBuffers.count
        var dims = SIMD2<UInt32>(UInt32(Deferred.occlusionSize.0), UInt32(Deferred.occlusionSize.1))
        c.setComputePipelineState(occlusionPipe)
        c.setTexture(depth, index: 0)
        c.setBuffer(buf, offset: 0, index: 0)
        c.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
        c.dispatchThreads(MTLSize(width: Deferred.occlusionSize.0, height: Deferred.occlusionSize.1, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        c.endEncoding()
        return buf
    }

    func ensure(width: Int, height: Int) {
        if let g = gb.first, g.width == width, g.height == height { return }
        gb = Deferred.gbFormats.compactMap { f in
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        let ad = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: width, height: height, mipmapped: false)
        ad.usage = [.renderTarget, .shaderRead]
        ad.storageMode = .private
        aoRaw = device.makeTexture(descriptor: ad)
        ao = device.makeTexture(descriptor: ad)
        let hd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, width / 2), height: max(1, height / 2), mipmapped: false)
        hd.usage = [.renderTarget, .shaderRead]
        hd.storageMode = .private
        giTex = device.makeTexture(descriptor: hd)
        reflTex = device.makeTexture(descriptor: hd)
        giHist = (0..<2).compactMap { _ in device.makeTexture(descriptor: hd) }
        reflHist = (0..<2).compactMap { _ in device.makeTexture(descriptor: hd) }
        histIndex = 0
        giOut = giTex
        reflOut = reflTex
    }

    func indirect(_ cmd: MTLCommandBuffer, _ a: inout AtmosGPU, depth: MTLTexture, previous: MTLTexture?, prevViewProj: simd_float4x4?) {
        guard let gi = giTex, let rf = reflTex, gb.count == 3 else { return }
        indirectFrame += 1
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = gi
        p.colorAttachments[1].texture = rf
        for i in 0..<2 {
            p.colorAttachments[i].loadAction = .clear
            p.colorAttachments[i].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            p.colorAttachments[i].storeAction = .store
        }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
        let valid = previous != nil && prevViewProj != nil
        var params = IndirectParams(prevVP: prevViewProj ?? matrix_identity_float4x4,
                                    info: SIMD4(valid ? 1 : 0, Float(indirectFrame % 64), giEnabled ? giMultiplier : 0, reflectionsEnabled ? 1 : 0))
        var at = a
        if valid {
            enc.setRenderPipelineState(indirectPipe)
            enc.setFragmentBytes(&at, length: MemoryLayout<AtmosGPU>.stride, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<IndirectParams>.stride, index: 1)
            enc.setFragmentTexture(previous, index: 7)
            enc.setFragmentTexture(gb[1], index: 9)
            enc.setFragmentTexture(gb[2], index: 10)
            enc.setFragmentTexture(depth, index: 11)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        accumulate(cmd, &at, depth: depth, prevViewProj: prevViewProj)
    }

    func accumulate(_ cmd: MTLCommandBuffer, _ a: inout AtmosGPU, depth: MTLTexture, prevViewProj: simd_float4x4?) {
        guard let gi = giTex, let rf = reflTex, giHist.count == 2, reflHist.count == 2 else { return }
        let src = histIndex, dst = 1 - histIndex
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = giHist[dst]
        p.colorAttachments[1].texture = reflHist[dst]
        for i in 0..<2 {
            p.colorAttachments[i].loadAction = .dontCare
            p.colorAttachments[i].storeAction = .store
        }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
        var params = IndirectParams(prevVP: prevViewProj ?? matrix_identity_float4x4,
                                    info: SIMD4(prevViewProj != nil ? 1 : 0, Deferred.indirectBlend, 0, 0))
        enc.setRenderPipelineState(accumPipe)
        enc.setFragmentBytes(&a, length: MemoryLayout<AtmosGPU>.stride, index: 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<IndirectParams>.stride, index: 1)
        enc.setFragmentTexture(gi, index: 0)
        enc.setFragmentTexture(rf, index: 1)
        enc.setFragmentTexture(giHist[src], index: 2)
        enc.setFragmentTexture(reflHist[src], index: 3)
        enc.setFragmentTexture(depth, index: 11)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        giOut = giHist[dst]
        reflOut = reflHist[dst]
        histIndex = dst
    }

    func gbufferPass(hdr: MTLTexture, depth: MTLTexture) -> MTLRenderPassDescriptor {
        let p = MTLRenderPassDescriptor()
        for (i, t) in gb.enumerated() {
            p.colorAttachments[i].texture = t
            p.colorAttachments[i].loadAction = .dontCare
            p.colorAttachments[i].storeAction = .store
        }
        p.colorAttachments[3].texture = hdr
        p.colorAttachments[3].loadAction = .dontCare
        p.colorAttachments[3].storeAction = .store
        p.depthAttachment.texture = depth
        p.depthAttachment.loadAction = .clear
        p.depthAttachment.clearDepth = 0
        p.depthAttachment.storeAction = .store
        return p
    }

    private func fullscreen(_ cmd: MTLCommandBuffer, target: MTLTexture, load: Bool, _ pipe: MTLRenderPipelineState,
                            _ bind: (MTLRenderCommandEncoder) -> Void) {
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = target
        p.colorAttachments[0].loadAction = load ? .load : .dontCare
        p.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
        enc.setRenderPipelineState(pipe)
        bind(enc)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    func ssao(_ cmd: MTLCommandBuffer, _ a: inout AtmosGPU, depth: MTLTexture) {
        guard let raw = aoRaw, let out = ao, gb.count == 3 else { return }
        var at = a
        fullscreen(cmd, target: raw, load: false, ssaoPipe) { enc in
            enc.setFragmentBytes(&at, length: MemoryLayout<AtmosGPU>.stride, index: 0)
            enc.setFragmentTexture(self.gb[1], index: 9)
            enc.setFragmentTexture(depth, index: 11)
        }
        fullscreen(cmd, target: out, load: false, blurPipe) { enc in
            enc.setFragmentBytes(&at, length: MemoryLayout<AtmosGPU>.stride, index: 0)
            enc.setFragmentTexture(raw, index: 12)
            enc.setFragmentTexture(depth, index: 11)
        }
    }

    func light(_ cmd: MTLCommandBuffer, _ a: inout AtmosGPU, _ sd: inout ShadowGPU, shadowMap: MTLTexture, atmosphere: Atmosphere) {
        guard let hdr = atmosphere.hdr, let depth = atmosphere.depth, let ao = ao, gb.count == 3 else { return }
        var at = a, s = sd
        fullscreen(cmd, target: hdr, load: true, lightPipe) { enc in
            enc.setFragmentBytes(&at, length: MemoryLayout<AtmosGPU>.stride, index: 0)
            enc.setFragmentBuffer(atmosphere.shBuffer, offset: 0, index: 1)
            enc.setFragmentBytes(&s, length: MemoryLayout<ShadowGPU>.stride, index: 2)
            enc.setFragmentTexture(atmosphere.transLUT, index: 0)
            enc.setFragmentTexture(shadowMap, index: 3)
            enc.setFragmentTexture(self.gb[0], index: 8)
            enc.setFragmentTexture(self.gb[1], index: 9)
            enc.setFragmentTexture(self.gb[2], index: 10)
            enc.setFragmentTexture(depth, index: 11)
            enc.setFragmentTexture(ao, index: 12)
            enc.setFragmentTexture(self.env, index: 13)
            enc.setFragmentTexture(self.giOut, index: 14)
            enc.setFragmentTexture(self.reflOut, index: 15)
        }
    }

    func updateEnvironment(_ cmd: MTLCommandBuffer, _ a: inout AtmosGPU, atmosphere: Atmosphere, force: Bool) {
        envFrame += 1
        guard force || !envReady || envFrame % Deferred.envInterval == 0 else { return }
        var at = a
        for face in 0..<6 {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = envSrc
            p.colorAttachments[0].slice = face
            p.colorAttachments[0].level = 0
            p.colorAttachments[0].loadAction = .dontCare
            p.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
            var cp = CubeParams(face: UInt32(face), roughness: 0, srcMips: 1, srcSize: Float(Deferred.envSize))
            enc.setRenderPipelineState(envFacePipe)
            enc.setFragmentBytes(&at, length: MemoryLayout<AtmosGPU>.stride, index: 0)
            enc.setFragmentBuffer(atmosphere.shBuffer, offset: 0, index: 1)
            enc.setFragmentBytes(&cp, length: MemoryLayout<CubeParams>.stride, index: 2)
            enc.setFragmentTexture(atmosphere.transLUT, index: 0)
            enc.setFragmentTexture(atmosphere.msLUT, index: 1)
            enc.setFragmentTexture(atmosphere.skyLUT, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        if let b = cmd.makeBlitCommandEncoder() {
            b.generateMipmaps(for: envSrc)
            b.endEncoding()
        }
        let levels = env.mipmapLevelCount
        for level in 0..<levels {
            for face in 0..<6 {
                let p = MTLRenderPassDescriptor()
                p.colorAttachments[0].texture = env
                p.colorAttachments[0].slice = face
                p.colorAttachments[0].level = level
                p.colorAttachments[0].loadAction = .dontCare
                p.colorAttachments[0].storeAction = .store
                guard let enc = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
                var cp = CubeParams(face: UInt32(face), roughness: Float(level) / Float(max(levels - 1, 1)),
                                    srcMips: Float(envSrc.mipmapLevelCount), srcSize: Float(Deferred.envSize))
                enc.setRenderPipelineState(envPrefilterPipe)
                enc.setFragmentBytes(&cp, length: MemoryLayout<CubeParams>.stride, index: 2)
                enc.setFragmentTexture(envSrc, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }
        envReady = true
    }
}
