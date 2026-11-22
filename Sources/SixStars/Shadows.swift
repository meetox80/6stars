import Foundation
import Metal
import simd

struct ShadowGPU {
    var vp: (simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4) = (matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4)
    var splits = SIMD4<Float>(repeating: 0)
    var texel = SIMD4<Float>(repeating: 0)
    var zinv = SIMD4<Float>(repeating: 0)
    var info = SIMD4<Float>(repeating: 0)
}

struct Cascade {
    var vp: simd_float4x4
    var split: Float
    var texel: Float
    var zinv: Float
    var center: SIMD3<Float>
    var radius: Float
}

final class Shadows {
    static let size = 2048
    static let count = 4
    static let baseSplits: [Float] = [10, 100, 300, 900]
    static let casterReach: Float = 1500

    let map: MTLTexture
    let pipeline: MTLRenderPipelineState
    let solidPipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    var enabled = true

    init(device: MTLDevice, library: MTLLibrary) throws {
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .depth32Float
        d.width = Shadows.size
        d.height = Shadows.size
        d.arrayLength = Shadows.count
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw RendererError.setup("no shadow map") }
        map = t
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = library.makeFunction(name: "shadowVertex")
        p.fragmentFunction = library.makeFunction(name: "shadowFragment")
        p.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: p)
        p.fragmentFunction = nil
        solidPipeline = try device.makeRenderPipelineState(descriptor: p)
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        guard let s = device.makeDepthStencilState(descriptor: ds) else { throw RendererError.setup("no shadow depth state") }
        depthState = s
    }

    static func basis(_ sun: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let lz = -sun
        let ref = abs(lz.z) > 0.99 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
        let lx = simd_normalize(simd_cross(ref, lz))
        let ly = simd_cross(lz, lx)
        return (lx, ly, lz)
    }

    static func cascades(camera: Camera, aspect: Float, sun: SIMD3<Float>, scale0: Float, distanceMult: Float) -> [Cascade] {
        let (lx, ly, lz) = basis(sun)
        let f = camera.forward
        let r = simd_normalize(simd_cross(f, Camera.up))
        let u = simd_cross(r, f)
        let ty = tan(camera.fovY / 2), tx = ty * aspect
        var splits = baseSplits.map { $0 * distanceMult }
        splits[0] *= scale0
        var out: [Cascade] = []
        var near: Float = camera.near
        for far in splits {
            var corners: [SIMD3<Float>] = []
            for d in [near, far] {
                for sx: Float in [-1, 1] {
                    for sy: Float in [-1, 1] {
                        corners.append(camera.position + f * d + r * (d * tx * sx) + u * (d * ty * sy))
                    }
                }
            }
            let c = corners.reduce(SIMD3<Float>(repeating: 0), +) / Float(corners.count)
            let rad = ceil(corners.map { simd_distance($0, c) }.max()!)
            let texel = 2 * rad / Float(size)
            var cl = SIMD3(simd_dot(lx, c), simd_dot(ly, c), simd_dot(lz, c))
            cl.x = floor(cl.x / texel) * texel
            cl.y = floor(cl.y / texel) * texel
            let zmin = cl.z - rad - casterReach, zmax = cl.z + rad
            let zi = 1 / (zmax - zmin)
            let vp = simd_float4x4(rows: [
                SIMD4(lx / rad, -cl.x / rad),
                SIMD4(ly / rad, -cl.y / rad),
                SIMD4(lz * zi, -zmin * zi),
                SIMD4(0, 0, 0, 1),
            ])
            out.append(Cascade(vp: vp, split: far, texel: texel, zinv: zi, center: cl, radius: rad))
            near = far
        }
        return out
    }

    static func casterPlanes(_ c: Cascade, sun: SIMD3<Float>) -> [SIMD4<Float>] {
        let (lx, ly, lz) = basis(sun)
        let cl = c.center, r = c.radius
        return [
            SIMD4(lx, -(cl.x - r)),
            SIMD4(-lx, cl.x + r),
            SIMD4(ly, -(cl.y - r)),
            SIMD4(-ly, cl.y + r),
            SIMD4(-lz, cl.z + r),
        ]
    }

    static func gpu(_ cs: [Cascade], enabled: Bool) -> ShadowGPU {
        var s = ShadowGPU()
        s.vp = (cs[0].vp, cs[1].vp, cs[2].vp, cs[3].vp)
        s.splits = SIMD4(cs[0].split, cs[1].split, cs[2].split, cs[3].split)
        s.texel = SIMD4(cs[0].texel, cs[1].texel, cs[2].texel, cs[3].texel)
        s.zinv = SIMD4(cs[0].zinv, cs[1].zinv, cs[2].zinv, cs[3].zinv)
        s.info = SIMD4(enabled ? 1 : 0, 1 / Float(size), 0, 0)
        return s
    }
}
