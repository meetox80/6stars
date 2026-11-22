import Foundation
import Metal
import QuartzCore
import simd

struct AtmosGPU {
    var sunDir = SIMD4<Float>(repeating: 0)
    var sunColor = SIMD4<Float>(repeating: 0)
    var rayleigh = SIMD4<Float>(repeating: 0)
    var mieScat = SIMD4<Float>(repeating: 0)
    var mieAbs = SIMD4<Float>(repeating: 0)
    var ozone = SIMD4<Float>(repeating: 0)
    var ozoneLin = SIMD4<Float>(repeating: 0)
    var planet = SIMD4<Float>(repeating: 0)
    var ambient = SIMD4<Float>(repeating: 0)
    var waterExt = SIMD4<Float>(repeating: 0)
    var waterScat = SIMD4<Float>(repeating: 0)
    var filmic0 = SIMD4<Float>(repeating: 0)
    var filmic1 = SIMD4<Float>(repeating: 0)
    var expo = SIMD4<Float>(repeating: 0)
    var sunDisc = SIMD4<Float>(repeating: 0)
    var misc = SIMD4<Float>(repeating: 0)
    var cloud0 = SIMD4<Float>(repeating: 0)
    var cloud1 = SIMD4<Float>(repeating: 0)
    var cloud2 = SIMD4<Float>(repeating: 0)
    var fog0 = SIMD4<Float>(repeating: 0)
    var fog1 = SIMD4<Float>(repeating: 0)
    var fog2 = SIMD4<Float>(repeating: 0)
    var fog3 = SIMD4<Float>(repeating: 0)
    var post0 = SIMD4<Float>(repeating: 0)
    var taa = SIMD4<Float>(repeating: 0)
    var grade = SIMD4<Float>(0, 1, 1, 0)
    var waterLook = SIMD4<Float>(0.5, 0, 0, 0)
    var sharpen = SIMD4<Float>(0, 0, 0, 0)
    var viewProj = matrix_identity_float4x4
    var camRight = SIMD4<Float>(repeating: 0)
    var camUp = SIMD4<Float>(repeating: 0)
    var camFwd = SIMD4<Float>(repeating: 0)
    var camPos = SIMD4<Float>(repeating: 0)
}

final class Atmosphere {
    static let hdrFormat: MTLPixelFormat = .rgba16Float
    static let distFormat: MTLPixelFormat = .r32Float
    static let latitude: Float = 25.76
    static let rayleighScale: Float = 0.0331
    static let mieScatterScale: Float = 0.003996
    static let mieAbsorptionScale: Float = 0.000444
    static let ozoneScale: Float = 0.001881
    static let sunAngularRadius: Float = 0.004654
    static let waterUnit: Float = 0.05
    static let groundAlbedo: Float = 0.3
    static let emissiveLuminance: Float = 1000
    static let lightCloudCoverage: Float = 0.35
    static let froxelRange: Float = 1500
    static let bloomLevels = 7
    var bloomEnabled = true
    var sharpness: Float = Float(ProcessInfo.processInfo.environment["MV_SHARPEN"] ?? "") ?? 0.5
    static let defaultGrade: [Float] = [1.1, 1.4, 1.3, 0.5]
    var exposureBias: Float = Atmosphere.gradeOverride(0)
    var saturation: Float = Atmosphere.gradeOverride(1)
    var contrast: Float = Atmosphere.gradeOverride(2)
    var warmth: Float = Atmosphere.gradeOverride(3)

    static func gradeOverride(_ i: Int) -> Float {
        let parts = (ProcessInfo.processInfo.environment["MV_GRADE"] ?? "").split(separator: ",").compactMap { Float($0) }
        return i < parts.count ? parts[i] : defaultGrade[i]
    }
    var meterLow: Float = 0.3
    var meterHigh: Float = 0.2
    static let bloomDecay: Float = 0.55
    static let bloomLerpScale: Float = 0.25

    let device: MTLDevice
    let timecycle: Timecycle?
    var hour: Float
    let dayOfYear: Int
    let start = CACurrentMediaTime()
    var lastFrame = CACurrentMediaTime()

    let transPipe: MTLRenderPipelineState
    let msPipe: MTLRenderPipelineState
    let skyLUTPipe: MTLRenderPipelineState
    let lumPipe: MTLRenderPipelineState
    let tonePipe: MTLRenderPipelineState
    let skyPipe: MTLRenderPipelineState
    let oceanPipe: MTLRenderPipelineState
    let compositePipe: MTLRenderPipelineState
    let cloudPipe: MTLRenderPipelineState
    let linearPipe: MTLRenderPipelineState
    let seedPipe: MTLRenderPipelineState
    let fogInject: MTLComputePipelineState
    let fogIntegrate: MTLComputePipelineState
    let bloomDownPipe: MTLRenderPipelineState
    let bloomUpPipe: MTLRenderPipelineState
    let taaPipe: MTLRenderPipelineState
    var taaTex: [MTLTexture] = []
    var taaIndex = 0
    var taaFrame = 0
    var prevViewProj: simd_float4x4?
    var prevCamera: SIMD3<Float>?
    static let taaBlend: Float = 0.1
    let fogScatter: MTLTexture
    let fogVolume: MTLTexture
    var bloom: MTLTexture?
    var bloomViews: [MTLTexture] = []
    var env: MTLTexture?
    let meshPipe: MTLRenderPipelineState
    let meshBlendPipe: MTLRenderPipelineState
    let shKernel: MTLComputePipelineState
    let adaptKernel: MTLComputePipelineState
    let fullscreenDepth: MTLDepthStencilState
    let transLUT: MTLTexture
    let msLUT: MTLTexture
    let skyLUT: MTLTexture
    let shBuffer: MTLBuffer
    let exposureBuffer: MTLBuffer
    var hdr: MTLTexture?
    var dist: MTLTexture?
    var depth: MTLTexture?
    var lum: MTLTexture?
    var clouds: MTLTexture?
    var cloudDist: MTLTexture?
    var hdrCopy: MTLTexture?
    var distCopy: MTLTexture?

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        let home = NSHomeDirectory()
        do {
            timecycle = try Timecycle.load(archive: "\(home)/testing/common.rpf", indexPath: "\(home)/testing/6stars-data/common.idx", cycle: "Sunny")
        } catch {
            FileHandle.standardError.write("timecycle: \(error)\n".data(using: .utf8)!)
            timecycle = nil
        }
        hour = Float(ProcessInfo.processInfo.environment["MV_HOUR"] ?? "") ?? 14
        dayOfYear = Calendar(identifier: .gregorian).ordinality(of: .day, in: .year, for: Date()) ?? 172

        func fn(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw RendererError.setup("missing shader \(name)") }
            return f
        }
        func simple(_ fs: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try fn("quadVertex")
            d.fragmentFunction = try fn(fs)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        func scene(_ vs: String, _ fs: String, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try fn(vs)
            d.fragmentFunction = try fn(fs)
            d.colorAttachments[0].pixelFormat = Atmosphere.hdrFormat
            d.colorAttachments[1].pixelFormat = Atmosphere.distFormat
            d.depthAttachmentPixelFormat = .depth32Float
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .zero
                d.colorAttachments[0].destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        transPipe = try simple("transLUTFragment", Atmosphere.hdrFormat)
        msPipe = try simple("msLUTFragment", Atmosphere.hdrFormat)
        skyLUTPipe = try simple("skyLUTFragment", Atmosphere.hdrFormat)
        lumPipe = try simple("lumFragment", .r16Float)
        tonePipe = try simple("tonemapFragment", .bgra8Unorm_srgb)
        skyPipe = try scene("quadVertex", "skyFragment", blend: false)
        oceanPipe = try scene("quadVertex", "oceanFragment", blend: false)
        compositePipe = try scene("quadVertex", "compositeFragment", blend: false)
        let cd = MTLRenderPipelineDescriptor()
        cd.vertexFunction = try fn("quadVertex")
        cd.fragmentFunction = try fn("cloudFragment")
        cd.colorAttachments[0].pixelFormat = Atmosphere.hdrFormat
        cd.colorAttachments[1].pixelFormat = Atmosphere.distFormat
        cloudPipe = try device.makeRenderPipelineState(descriptor: cd)
        linearPipe = try simple("linearDepthFragment", Atmosphere.distFormat)
        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = try fn("quadVertex")
        sd.fragmentFunction = try fn("seedFragment")
        sd.colorAttachments[0].pixelFormat = Atmosphere.hdrFormat
        sd.colorAttachments[0].writeMask = []
        sd.colorAttachments[1].pixelFormat = Atmosphere.distFormat
        sd.depthAttachmentPixelFormat = .depth32Float
        seedPipe = try device.makeRenderPipelineState(descriptor: sd)
        fogInject = try device.makeComputePipelineState(function: try fn("fogInjectKernel"))
        fogIntegrate = try device.makeComputePipelineState(function: try fn("fogIntegrateKernel"))
        bloomDownPipe = try simple("bloomDownFragment", .rg11b10Float)
        let bu = MTLRenderPipelineDescriptor()
        bu.vertexFunction = try fn("quadVertex")
        bu.fragmentFunction = try fn("bloomUpFragment")
        bu.colorAttachments[0].pixelFormat = .rg11b10Float
        bu.colorAttachments[0].isBlendingEnabled = true
        bu.colorAttachments[0].sourceRGBBlendFactor = .blendColor
        bu.colorAttachments[0].destinationRGBBlendFactor = .one
        bloomUpPipe = try device.makeRenderPipelineState(descriptor: bu)
        taaPipe = try simple("taaFragment", Atmosphere.hdrFormat)
        func volume() throws -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = .type3D
            d.pixelFormat = .rgba16Float
            d.width = 160
            d.height = 90
            d.depth = 64
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.setup("no fog volume") }
            return t
        }
        fogScatter = try volume()
        fogVolume = try volume()
        meshPipe = try scene("meshVertex", "meshFragmentHDR", blend: false)
        meshBlendPipe = try scene("meshVertex", "meshFragmentHDR", blend: true)
        shKernel = try device.makeComputePipelineState(function: try fn("skySHKernel"))
        adaptKernel = try device.makeComputePipelineState(function: try fn("adaptKernel"))
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .always
        dd.isDepthWriteEnabled = false
        guard let ds = device.makeDepthStencilState(descriptor: dd) else { throw RendererError.setup("no depth state") }
        fullscreenDepth = ds
        func lut(_ w: Int, _ h: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Atmosphere.hdrFormat, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.setup("no LUT texture") }
            return t
        }
        transLUT = try lut(256, 64)
        msLUT = try lut(32, 32)
        skyLUT = try lut(192, 108)
        guard let sb = device.makeBuffer(length: 64, options: .storageModePrivate),
              let eb = device.makeBuffer(length: 16, options: .storageModeShared) else { throw RendererError.setup("no atmosphere buffers") }
        shBuffer = sb
        exposureBuffer = eb
        eb.contents().storeBytes(of: Float.nan, as: Float.self)
    }

    var weather: String { timecycle?.cycle ?? "no timecycle" }

    var sunDirection: SIMD3<Float> { Timecycle.sunDirection(hour: hour, dayOfYear: dayOfYear, latitude: Atmosphere.latitude) }

    func cascades(camera: Camera, aspect: Float) -> [Cascade] {
        Shadows.cascades(camera: camera, aspect: aspect, sun: sunDirection, scale0: value("dir_shadow_cascade0_scale", 3),
                         distanceMult: value("dir_shadow_distance_multiplier", 1))
    }

    func value(_ name: String, _ fallback: Float) -> Float {
        timecycle?.value(name, at: hour) ?? fallback
    }

    func color(_ prefix: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(value(prefix + "_r", fallback.x), value(prefix + "_g", fallback.y), value(prefix + "_b", fallback.z))
    }

    func params(camera: Camera, aspect: Float, height: Int, viewProj: simd_float4x4) -> AtmosGPU {
        var a = AtmosGPU()
        let sun = sunDirection
        a.sunDir = SIMD4(sun, value("sky_scattering_sun_illuminance", 99968))
        let lightCol = color("light_dir_col", SIMD3(1, 1, 1)) * value("light_dir_mult", 1) * value("light_dir_sun_mult", 1)
        a.sunColor = SIMD4(lightCol, value("postfx_exposure", 0))
        a.rayleigh = SIMD4(color("sky_new_ray_scattering_col", SIMD3(0.1598, 0.3738, 0.9131)) * value("sky_new_ray_scattering_intensity", 1) * Atmosphere.rayleighScale,
                           value("sky_new_ray_density_scale", 8))
        a.mieScat = SIMD4(color("sky_new_mie_scattering_col", SIMD3(repeating: 0.5767)) * value("sky_new_mie_scattering_intensity", 1) * Atmosphere.mieScatterScale,
                          value("sky_new_mie_density_scale", 1.1973))
        a.mieAbs = SIMD4(color("sky_new_mie_absorption_col", SIMD3(repeating: 0.5767)) * value("sky_new_mie_absorption_intensity", 1) * Atmosphere.mieAbsorptionScale,
                         value("sky_new_mie_phase_eccentricity", 0.7798))
        a.ozone = SIMD4(color("sky_new_ozo_extinction_col", SIMD3(0.3262, 0.9434, 0.0427)) * value("sky_new_ozo_extinction_intensity", 1) * Atmosphere.ozoneScale,
                        value("sky_new_ozo_0_width", 25))
        a.ozoneLin = SIMD4(value("sky_new_ozo_0_linear", 0.0666), value("sky_new_ozo_0_constant", -0.6646),
                           value("sky_new_ozo_1_linear", -0.0666), value("sky_new_ozo_1_constant", 2.6641))
        let R = value("sky_new_planet_radius", 6360)
        let top = R + value("sky_new_karman_line", 100)
        a.planet = SIMD4(R, top, R + max(camera.position.z, 1) * 0.001, Atmosphere.groundAlbedo)
        a.ambient = SIMD4(color("ambient_sky_color_mult", SIMD3(1, 1, 1)) * value("indirect_light_sky_multiplier", 1),
                          value("sky_new_intensity_multiscattering", 1))
        a.waterExt = SIMD4(color("water_clip_extinction", SIMD3(11.1875, 6.5977, 6.5977)) * value("water_clip_extinction_scale", 1) * Atmosphere.waterUnit,
                           value("water_height", 0) + value("water_ocean_tidal_offset", 0))
        a.waterScat = SIMD4(color("water_clip_scattering", SIMD3(0.06, 0.12, 0.3997)) * value("water_clip_scattering_scale", 1) * Atmosphere.waterUnit,
                            value("water_ocean_beaufort_scale", 3))
        a.waterLook = SIMD4(value("water_reflection_color_mult", 0.5), 0, 0, 0)
        a.sharpen = SIMD4(sharpness, 0, 0, 0)
        a.filmic0 = SIMD4(value("postfx_tonemap_filmic_a", 0.1), value("postfx_tonemap_filmic_b", 0.3997),
                          value("postfx_tonemap_filmic_c", 0.1), value("postfx_tonemap_filmic_d", 0.2))
        a.filmic1 = SIMD4(value("postfx_tonemap_filmic_e", 0.01), value("postfx_tonemap_filmic_f", 0.2996),
                          value("postfx_tonemap_filmic_w", 4), value("postfx_contrast_amount", 1))
        a.expo = SIMD4(value("postfx_exposure_key_value", 0.1797), value("postfx_exposure_min", -11), value("postfx_exposure_max", 32),
                       Float(CACurrentMediaTime() - start))
        a.sunDisc = SIMD4(Atmosphere.sunAngularRadius * value("sky_sun_disc_size", 2), value("sky_scattering_sun_disk_intensity_multiplier", 256),
                          value("sky_new_intensity_aerial", 1), value("sky_new_intensity_sky", 1))
        meterLow = value("postfx_exposure_lowlights_percent", 0.3)
        meterHigh = value("postfx_exposure_highlights_percent", 0.2)
        a.grade = SIMD4(exposureBias, saturation, contrast, warmth)
        a.misc = SIMD4(value("postfx_contrast_pivot", 0.18), 2 * tan(camera.fovY / 2) / Float(max(height, 1)), Atmosphere.emissiveLuminance, camera.near)
        let w = timecycle?.weather ?? [:]
        let windAngle = (w["WindAngle"] ?? 135) * Float.pi / 180
        let windSpeed = ((w["WindMin"] ?? 1.6) + (w["WindMax"] ?? 2.4)) / 2
        a.cloud0 = SIMD4(value("local_atmosphere_cloud_height", 200), value("local_atmosphere_cloud_height_top", 1500),
                         Atmosphere.lightCloudCoverage, value("local_atmosphere_custom_cloud_group_0_density", 1))
        a.cloud1 = SIMD4(value("local_atmosphere_cloud_cirrus_height", 8000), value("local_atmosphere_cloud_cirrus_density_y", 0.2991),
                         windSpeed * value("local_atmosphere_cloud_wind_velocity_scale", 0.5) * 4, value("local_atmosphere_cloud_shadow_alpha", 0.7979))
        a.cloud2 = SIMD4(cos(windAngle), sin(windAngle), value("water_foam_intensity_mult", 1), 2 * value("local_atmosphere_cloud_multi_scatter_radiance_scale", 1))
        let global = value("local_atmosphere_fog_volume_global_density_mult", 1)
        a.fog0 = SIMD4(value("local_atmosphere_fog_density", 0.0003) * global, value("local_atmosphere_fog_height", 100),
                       value("local_atmosphere_fog_falloff", 500), value("local_atmosphere_fog_density_layer_1", 0) * global)
        a.fog1 = SIMD4(value("local_atmosphere_fog_height_layer_1", 0), value("local_atmosphere_fog_falloff_layer_1", 50),
                       value("local_atmosphere_haze_phase_anisotropy", 0.6499), value("local_atmosphere_fog_shadow_intensity", 1))
        a.fog2 = SIMD4(color("local_atmosphere_direct_light_color", SIMD3(1, 1, 1)) * value("local_atmosphere_direct_light_intensity", 1)
                           * value("local_atmosphere_dir_light_scattering_strength", 1),
                       value("local_atmosphere_multiscatter_compensation", 1.5))
        a.fog3 = SIMD4(color("local_atmosphere_sky_col", SIMD3(1, 1, 1)) * value("local_atmosphere_sky_intensity", 1), Atmosphere.froxelRange)
        let bloomNorm = (0..<Atmosphere.bloomLevels).reduce(Float(0)) { $0 + pow(Atmosphere.bloomDecay, Float($1)) }
        a.post0 = SIMD4(!bloomEnabled || ProcessInfo.processInfo.environment["MV_NOBLOOM"] != nil ? 0 : value("postfx_intensity_bloom", 0.1498) * Atmosphere.bloomLerpScale, bloomNorm,
                        value("local_atmosphere_voxel_noise_min", 0.5) * 2, value("local_atmosphere_voxel_noise_max", 0.584) * 2)
        a.viewProj = viewProj
        let t = tan(camera.fovY / 2)
        let f = camera.forward
        let r = simd_normalize(simd_cross(f, Camera.up))
        let u = simd_cross(r, f)
        a.camRight = SIMD4(r, t * aspect)
        a.camUp = SIMD4(u, t)
        a.camFwd = SIMD4(f, 0)
        a.camPos = SIMD4(camera.position, 1)
        return a
    }

    func ensureTargets(width: Int, height: Int) {
        if let h = hdr, h.width == width, h.height == height { return }
        let hd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Atmosphere.hdrFormat, width: width, height: height, mipmapped: false)
        hd.usage = [.renderTarget, .shaderRead]
        hd.storageMode = .private
        hdr = device.makeTexture(descriptor: hd)
        hdrCopy = device.makeTexture(descriptor: hd)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Atmosphere.distFormat, width: width, height: height, mipmapped: false)
        dd.usage = [.renderTarget, .shaderRead]
        dd.storageMode = .private
        dist = device.makeTexture(descriptor: dd)
        taaTex = (0..<2).compactMap { _ in device.makeTexture(descriptor: hd) }
        prevViewProj = nil
        let dc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Atmosphere.distFormat, width: width, height: height, mipmapped: false)
        dc.usage = [.renderTarget, .shaderRead]
        dc.storageMode = .private
        distCopy = device.makeTexture(descriptor: dc)
        let zd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        zd.usage = [.renderTarget, .shaderRead]
        zd.storageMode = .private
        depth = device.makeTexture(descriptor: zd)
        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg11b10Float, width: max(1, width / 2), height: max(1, height / 2), mipmapped: true)
        bd.mipmapLevelCount = min(Atmosphere.bloomLevels, bd.mipmapLevelCount)
        bd.usage = [.renderTarget, .shaderRead]
        bd.storageMode = .private
        bloom = device.makeTexture(descriptor: bd)
        bloomViews = bloom.map { b in (0..<b.mipmapLevelCount).compactMap { b.makeTextureView(pixelFormat: .rg11b10Float, textureType: .type2D, levels: $0..<($0 + 1), slices: 0..<1) } } ?? []
        let cw = max(1, width / 4), ch = max(1, height / 4)
        let cdesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Atmosphere.hdrFormat, width: cw, height: ch, mipmapped: false)
        cdesc.usage = [.renderTarget, .shaderRead]
        cdesc.storageMode = .private
        clouds = device.makeTexture(descriptor: cdesc)
        let cdd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Atmosphere.distFormat, width: cw, height: ch, mipmapped: false)
        cdd.usage = [.renderTarget, .shaderRead]
        cdd.storageMode = .private
        cloudDist = device.makeTexture(descriptor: cdd)
        if lum == nil {
            let ld = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: 512, height: 256, mipmapped: true)
            ld.usage = [.renderTarget, .shaderRead]
            ld.storageMode = .private
            lum = device.makeTexture(descriptor: ld)
        }
    }

    func prepare(_ cmd: MTLCommandBuffer, _ a: inout AtmosGPU) {
        func pass(_ target: MTLTexture, _ pipe: MTLRenderPipelineState, _ inputs: [MTLTexture]) {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = target
            p.colorAttachments[0].loadAction = .dontCare
            p.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
            enc.setRenderPipelineState(pipe)
            enc.setFragmentBytes(&a, length: MemoryLayout<AtmosGPU>.stride, index: 0)
            for (i, t) in inputs.enumerated() { enc.setFragmentTexture(t, index: i) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        pass(transLUT, transPipe, [])
        pass(msLUT, msPipe, [transLUT])
        pass(skyLUT, skyLUTPipe, [transLUT, msLUT])
        if let c = cmd.makeComputeCommandEncoder() {
            c.setComputePipelineState(shKernel)
            c.setTexture(skyLUT, index: 0)
            c.setBuffer(shBuffer, offset: 0, index: 0)
            c.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            c.endEncoding()
        }
        guard let ct = clouds, let cdt = cloudDist else { return }
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = ct
        p.colorAttachments[0].loadAction = .dontCare
        p.colorAttachments[0].storeAction = .store
        p.colorAttachments[1].texture = cdt
        p.colorAttachments[1].loadAction = .dontCare
        p.colorAttachments[1].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
        enc.setRenderPipelineState(cloudPipe)
        enc.setFragmentBytes(&a, length: MemoryLayout<AtmosGPU>.stride, index: 0)
        enc.setFragmentBuffer(shBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(transLUT, index: 0)
        enc.setFragmentTexture(msLUT, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    func forwardPass() -> MTLRenderPassDescriptor {
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = hdr
        p.colorAttachments[0].loadAction = .load
        p.colorAttachments[0].storeAction = .store
        p.colorAttachments[1].texture = dist
        p.colorAttachments[1].loadAction = .dontCare
        p.colorAttachments[1].storeAction = .store
        p.depthAttachment.texture = depth
        p.depthAttachment.loadAction = .load
        p.depthAttachment.storeAction = .dontCare
        return p
    }

    func copyScene(_ cmd: MTLCommandBuffer, _ a: inout AtmosGPU) {
        guard let h = hdr, let hc = hdrCopy, let d = depth, let dc = distCopy else { return }
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = dc
        p.colorAttachments[0].loadAction = .dontCare
        p.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: p) {
            enc.setRenderPipelineState(linearPipe)
            enc.setFragmentBytes(&a, length: MemoryLayout<AtmosGPU>.stride, index: 0)
            enc.setFragmentTexture(d, index: 11)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        guard let b = cmd.makeBlitCommandEncoder() else { return }
        b.copy(from: h, to: hc)
        b.endEncoding()
    }

    func bindLighting(_ enc: MTLRenderCommandEncoder, _ a: inout AtmosGPU, _ sd: inout ShadowGPU, _ map: MTLTexture) {
        enc.setFragmentTexture(env, index: 13)
        enc.setFragmentBytes(&sd, length: MemoryLayout<ShadowGPU>.stride, index: 8)
        enc.setFragmentTexture(map, index: 3)
        enc.setFragmentBytes(&a, length: MemoryLayout<AtmosGPU>.stride, index: 6)
        enc.setFragmentBuffer(shBuffer, offset: 0, index: 7)
        enc.setFragmentTexture(transLUT, index: 0)
        enc.setFragmentTexture(msLUT, index: 1)
        enc.setFragmentTexture(skyLUT, index: 2)
    }

    func fullscreen(_ enc: MTLRenderCommandEncoder, _ pipe: MTLRenderPipelineState, _ a: inout AtmosGPU, depthState: MTLDepthStencilState? = nil) {
        enc.setRenderPipelineState(pipe)
        enc.setDepthStencilState(depthState ?? fullscreenDepth)
        enc.setFragmentBytes(&a, length: MemoryLayout<AtmosGPU>.stride, index: 0)
        enc.setFragmentBuffer(shBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(transLUT, index: 0)
        enc.setFragmentTexture(msLUT, index: 1)
        enc.setFragmentTexture(skyLUT, index: 2)
        enc.setFragmentTexture(clouds, index: 4)
        enc.setFragmentTexture(cloudDist, index: 5)
        enc.setFragmentTexture(hdrCopy, index: 6)
        enc.setFragmentTexture(distCopy, index: 7)
        enc.setFragmentTexture(env, index: 13)
        enc.setFragmentTexture(fogVolume, index: 14)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    func volumetrics(_ cmd: MTLCommandBuffer, _ a: inout AtmosGPU, _ sd: inout ShadowGPU, shadowMap: MTLTexture) {
        guard let c = cmd.makeComputeCommandEncoder() else { return }
        c.setComputePipelineState(fogInject)
        c.setTexture(fogScatter, index: 0)
        c.setTexture(transLUT, index: 1)
        c.setTexture(shadowMap, index: 2)
        c.setBytes(&a, length: MemoryLayout<AtmosGPU>.stride, index: 0)
        c.setBuffer(shBuffer, offset: 0, index: 1)
        c.setBytes(&sd, length: MemoryLayout<ShadowGPU>.stride, index: 2)
        c.dispatchThreads(MTLSize(width: 160, height: 90, depth: 64), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
        c.setComputePipelineState(fogIntegrate)
        c.setTexture(fogScatter, index: 0)
        c.setTexture(fogVolume, index: 1)
        c.dispatchThreads(MTLSize(width: 160, height: 90, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        c.endEncoding()
    }

    func bloomChain(_ cmd: MTLCommandBuffer, hdr: MTLTexture, _ a: inout AtmosGPU) {
        guard let b = bloom, bloomViews.count == b.mipmapLevelCount else { return }
        func pass(_ target: MTLTexture, _ pipe: MTLRenderPipelineState, load: Bool, src: MTLTexture, info: SIMD2<Float>) {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = target
            p.colorAttachments[0].loadAction = load ? .load : .dontCare
            p.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
            var inf = info
            enc.setRenderPipelineState(pipe)
            enc.setBlendColor(red: Atmosphere.bloomDecay, green: Atmosphere.bloomDecay, blue: Atmosphere.bloomDecay, alpha: 1)
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentBytes(&inf, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            enc.setFragmentBuffer(exposureBuffer, offset: 0, index: 1)
            enc.setFragmentBytes(&a, length: MemoryLayout<AtmosGPU>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        pass(bloomViews[0], bloomDownPipe, load: false, src: hdr, info: SIMD2(0, 1))
        for i in 1..<bloomViews.count { pass(bloomViews[i], bloomDownPipe, load: false, src: bloomViews[i - 1], info: SIMD2(0, 0)) }
        for i in stride(from: bloomViews.count - 2, through: 0, by: -1) { pass(bloomViews[i], bloomUpPipe, load: true, src: bloomViews[i + 1], info: SIMD2(0, 0)) }
    }

    static func halton(_ i: Int, _ b: Int) -> Float {
        var f: Float = 1, r: Float = 0, n = i
        while n > 0 {
            f /= Float(b)
            r += f * Float(n % b)
            n /= b
        }
        return r
    }

    func jitter(width: Int, height: Int, active: Bool) -> SIMD2<Float> {
        guard active else { return .zero }
        taaFrame += 1
        let i = taaFrame % 16 + 1
        return SIMD2((Atmosphere.halton(i, 2) - 0.5) * 2 / Float(width), (Atmosphere.halton(i, 3) - 0.5) * 2 / Float(height))
    }

    func resolveTAA(_ cmd: MTLCommandBuffer, _ a: inout AtmosGPU, unjittered: simd_float4x4, camera: SIMD3<Float>, active: Bool) -> MTLTexture? {
        guard let cur = hdr, let d = dist, taaTex.count == 2 else { return hdr }
        let teleport = prevCamera.map { simd_distance($0, camera) > 60 } ?? true
        var prev = prevViewProj ?? unjittered
        a.taa.z = (!active || prevViewProj == nil || teleport) ? 1 : Atmosphere.taaBlend
        let out = taaTex[taaIndex], history = taaTex[1 - taaIndex]
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = out
        p.colorAttachments[0].loadAction = .dontCare
        p.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: p) {
            enc.setRenderPipelineState(taaPipe)
            enc.setFragmentBytes(&a, length: MemoryLayout<AtmosGPU>.stride, index: 0)
            enc.setFragmentBytes(&prev, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            enc.setFragmentBuffer(exposureBuffer, offset: 0, index: 2)
            enc.setFragmentTexture(cur, index: 0)
            enc.setFragmentTexture(history, index: 1)
            enc.setFragmentTexture(d, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        taaIndex = 1 - taaIndex
        prevViewProj = unjittered
        prevCamera = camera
        return out
    }

    func post(_ cmd: MTLCommandBuffer, target: MTLTexture, source: MTLTexture, _ a: inout AtmosGPU, settle: Bool, overlay: (MTLRenderCommandEncoder) -> Void) {
        guard let lum = lum else { return }
        let hdr = source
        let now = CACurrentMediaTime()
        let dt = Float(min(0.25, now - lastFrame))
        lastFrame = now
        let lp = MTLRenderPassDescriptor()
        lp.colorAttachments[0].texture = lum
        lp.colorAttachments[0].loadAction = .dontCare
        lp.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: lp) {
            enc.setRenderPipelineState(lumPipe)
            enc.setFragmentTexture(hdr, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        if let b = cmd.makeBlitCommandEncoder() {
            b.generateMipmaps(for: lum)
            b.endEncoding()
        }
        if let c = cmd.makeComputeCommandEncoder() {
            var params = SIMD4<Float>(2, settle ? 1 : 1 - exp(-dt * 1.5), meterLow, meterHigh)
            c.setComputePipelineState(adaptKernel)
            c.setTexture(lum, index: 0)
            c.setBuffer(exposureBuffer, offset: 0, index: 0)
            c.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            c.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            c.endEncoding()
        }
        bloomChain(cmd, hdr: hdr, &a)
        let tp = MTLRenderPassDescriptor()
        tp.colorAttachments[0].texture = target
        tp.colorAttachments[0].loadAction = .dontCare
        tp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: tp) else { return }
        enc.setRenderPipelineState(tonePipe)
        enc.setFragmentTexture(hdr, index: 0)
        enc.setFragmentBytes(&a, length: MemoryLayout<AtmosGPU>.stride, index: 0)
        enc.setFragmentBuffer(exposureBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(bloom, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        overlay(enc)
        enc.endEncoding()
    }
}
