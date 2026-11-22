import CoreGraphics
import Metal
import RPFKit

enum GPUTexture {
    static func pixelFormat(_ dxgi: Int) -> MTLPixelFormat? {
        switch dxgi {
        case 70, 71: return .bc1_rgba
        case 72: return .bc1_rgba_srgb
        case 73, 74: return .bc2_rgba
        case 75: return .bc2_rgba_srgb
        case 76, 77: return .bc3_rgba
        case 78: return .bc3_rgba_srgb
        case 79, 80: return .bc4_rUnorm
        case 81: return .bc4_rSnorm
        case 82, 83: return .bc5_rgUnorm
        case 84: return .bc5_rgSnorm
        case 94, 95: return .bc6H_rgbuFloat
        case 96: return .bc6H_rgbFloat
        case 97, 98: return .bc7_rgbaUnorm
        case 99: return .bc7_rgbaUnorm_srgb
        case 2: return .rgba32Float
        case 10: return .rgba16Float
        case 11: return .rgba16Unorm
        case 24: return .rgb10a2Unorm
        case 26: return .rg11b10Float
        case 27, 28: return .rgba8Unorm
        case 29: return .rgba8Unorm_srgb
        case 31: return .rgba8Snorm
        case 34: return .rg16Float
        case 35: return .rg16Unorm
        case 41: return .r32Float
        case 49: return .rg8Unorm
        case 54: return .r16Float
        case 56: return .r16Unorm
        case 61: return .r8Unorm
        case 65: return .a8Unorm
        case 87, 88: return .bgra8Unorm
        case 90, 91: return .bgra8Unorm_srgb
        default: return nil
        }
    }

    static func make(_ device: MTLDevice, _ img: TextureImage) -> MTLTexture? {
        guard let pf = pixelFormat(img.info.format), let eb = img.info.elementBytes else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pf, width: img.info.width, height: img.info.height, mipmapped: img.mips.count > 1)
        d.mipmapLevelCount = img.mips.count
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        let bs = img.info.blockSize
        var w = img.info.width, h = img.info.height
        for (level, data) in img.mips.enumerated() {
            let ew = (w + bs - 1) / bs
            data.withUnsafeBytes { p in
                t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: level, withBytes: p.baseAddress!, bytesPerRow: ew * eb)
            }
            w = max(1, w / 2)
            h = max(1, h / 2)
        }
        return t
    }
}
