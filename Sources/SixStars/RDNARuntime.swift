import Foundation
import Metal

enum HeapArray: Int {
    case t2d = 0, u2d, t3d, tcube, t2da, w2d, wu2d, w3d, w2da, d2d, d2da
}

final class RDNARuntime {
    static let heapT = 1024
    static let heapS = 2048
    static let codeBase: UInt64 = 1 << 40

    let device: MTLDevice
    let queue: MTLCommandQueue
    let arena: MTLBuffer
    let heap: MTLBuffer
    var arenaTop = 4096
    var nextSlot = 1
    var resident: [MTLResource] = []
    var samplers: [MTLSamplerState] = []
    let header: String

    init(device: MTLDevice, headerPath: String, arenaBytes: Int = 64 << 20) throws {
        self.device = device
        queue = device.makeCommandQueue()!
        arena = device.makeBuffer(length: arenaBytes, options: .storageModeShared)!
        memset(arena.contents(), 0, arenaBytes)
        let heapBytes = (11 * RDNARuntime.heapT + RDNARuntime.heapS) * 8
        heap = device.makeBuffer(length: heapBytes, options: .storageModeShared)!
        memset(heap.contents(), 0, heapBytes)
        header = try String(contentsOfFile: headerPath, encoding: .utf8)
        buildSamplers()
    }

    func buildSamplers() {
        let p = heap.contents().advanced(by: 11 * RDNARuntime.heapT * 8)
        for key in 0..<RDNARuntime.heapS {
            let d = MTLSamplerDescriptor()
            func mode(_ m: Int) -> MTLSamplerAddressMode { [MTLSamplerAddressMode.repeat, .mirrorRepeat, .clampToEdge, .clampToBorderColor][m] }
            d.sAddressMode = mode(key & 3)
            d.tAddressMode = mode((key >> 2) & 3)
            d.rAddressMode = d.sAddressMode
            let lin = (key >> 4) & 1 == 1
            d.minFilter = lin ? .linear : .nearest
            d.magFilter = lin ? .linear : .nearest
            let mip = (key >> 5) & 3
            d.mipFilter = mip == 0 ? .notMipmapped : mip == 1 ? .nearest : .linear
            let cmp = (key >> 7) & 7
            if cmp != 0 {
                d.compareFunction = [MTLCompareFunction.never, .less, .equal, .lessEqual, .greater, .notEqual, .greaterEqual, .always][cmp]
            }
            if (key >> 10) & 1 == 1 && mip != 0 { d.maxAnisotropy = 16 }
            d.borderColor = .transparentBlack
            d.supportArgumentBuffers = true
            let s = device.makeSamplerState(descriptor: d)!
            samplers.append(s)
            p.storeBytes(of: s.gpuResourceID, toByteOffset: key * 8, as: MTLResourceID.self)
        }
    }

    func alloc(_ bytes: Int, align: Int = 256) -> UInt64 {
        arenaTop = (arenaTop + align - 1) / align * align
        let a = arenaTop
        arenaTop += bytes
        precondition(arenaTop <= arena.length, "arena full")
        return UInt64(a)
    }

    func write<T>(_ value: T, at addr: UInt64) {
        arena.contents().advanced(by: Int(addr)).storeBytes(of: value, as: T.self)
    }

    func write(words: [UInt32], at addr: UInt64) {
        let p = arena.contents().advanced(by: Int(addr)).bindMemory(to: UInt32.self, capacity: words.count)
        for (i, w) in words.enumerated() { p[i] = w }
    }

    func write(floats: [Float], at addr: UInt64) {
        write(words: floats.map { $0.bitPattern }, at: addr)
    }

    func read(words n: Int, at addr: UInt64) -> [UInt32] {
        let p = arena.contents().advanced(by: Int(addr)).bindMemory(to: UInt32.self, capacity: n)
        return (0..<n).map { p[$0] }
    }

    func register(_ tex: MTLTexture, in arrays: [HeapArray]) -> Int {
        let slot = nextSlot
        nextSlot += 1
        for a in arrays {
            heap.contents().storeBytes(of: tex.gpuResourceID, toByteOffset: (a.rawValue * RDNARuntime.heapT + slot) * 8, as: MTLResourceID.self)
        }
        resident.append(tex)
        return slot
    }

    static func gfx10Format(_ f: MTLPixelFormat) -> UInt32 {
        switch f {
        case .r8Unorm: return 1
        case .r16Unorm: return 7
        case .r16Uint: return 11
        case .r16Float: return 13
        case .rg8Unorm: return 14
        case .r32Uint: return 20
        case .r32Sint: return 21
        case .r32Float: return 22
        case .rg16Unorm: return 23
        case .rg16Float: return 29
        case .rg11b10Float: return 43
        case .rgb10a2Unorm: return 44
        case .rgba8Unorm, .bgra8Unorm, .rgba8Unorm_srgb: return 56
        case .rgba8Uint: return 60
        case .rg32Uint: return 62
        case .rg32Float: return 64
        case .rgba16Unorm: return 65
        case .rgba16Float: return 71
        case .rgba32Uint: return 75
        case .rgba32Float: return 77
        default: return 56
        }
    }

    func tdesc(slot: Int, tex: MTLTexture) -> [UInt32] {
        let fmt = RDNARuntime.gfx10Format(tex.pixelFormat)
        let w = UInt32(tex.width - 1), h = UInt32(tex.height - 1)
        let sel: UInt32 = 4 | (5 << 3) | (6 << 6) | (7 << 9)
        let type: UInt32 = tex.textureType == .type3D ? 10 : tex.textureType == .typeCube ? 11 : tex.textureType == .type2DArray ? 13 : 9
        let lastLevel = UInt32(max(tex.mipmapLevelCount - 1, 0))
        return [UInt32(slot), (fmt << 20) | ((w & 3) << 30), (w >> 2) | (h << 14), sel | (lastLevel << 16) | (type << 28),
                UInt32(max(tex.depth, tex.arrayLength) - 1), 0, 0, 0]
    }

    func vdesc(addr: UInt64, bytes: Int, stride: Int = 0, format: UInt32 = 20) -> [UInt32] {
        let sel: UInt32 = 4 | (5 << 3) | (6 << 6) | (7 << 9)
        return [UInt32(addr & 0xffff_ffff), UInt32((addr >> 32) & 0xffff) | (UInt32(stride) << 16),
                UInt32(stride == 0 ? bytes : bytes / stride), sel | (format << 12) | (3 << 28)]
    }

    func makeTexture(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, depth: Int = 1, type: MTLTextureType = .type2D, mips: Int = 1, writable: Bool = true) -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = type
        d.pixelFormat = fmt
        d.width = w
        d.height = h
        d.depth = type == .type3D ? depth : 1
        d.arrayLength = type == .type2DArray ? depth : 1
        d.mipmapLevelCount = mips
        d.storageMode = .shared
        d.usage = writable ? [.shaderRead, .shaderWrite, .pixelFormatView] : [.shaderRead]
        return device.makeTexture(descriptor: d)!
    }

    struct Kernel {
        let pipeline: MTLComputePipelineState
        let threads: Int
    }

    func compileKernel(path: String, threads: Int) throws -> Kernel {
        let src = try String(contentsOfFile: path, encoding: .utf8).replacingOccurrences(of: "#include \"rdna_rt.h\"", with: header)
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_1
        let lib = try device.makeLibrary(source: src, options: opts)
        let fn = lib.makeFunction(name: lib.functionNames[0])!
        let d = MTLComputePipelineDescriptor()
        d.computeFunction = fn
        d.threadGroupSizeIsMultipleOfThreadExecutionWidth = true
        let p = try device.makeComputePipelineState(descriptor: d, options: [], reflection: nil)
        return Kernel(pipeline: p, threads: threads)
    }

    func dispatch(_ cmd: MTLCommandBuffer, _ k: Kernel, user: [UInt32], groups: MTLSize) {
        let e = cmd.makeComputeCommandEncoder()!
        e.setComputePipelineState(k.pipeline)
        e.setBuffer(arena, offset: 0, index: 0)
        var u = user + [UInt32](repeating: 0, count: max(0, 32 - user.count))
        e.setBytes(&u, length: u.count * 4, index: 1)
        e.setBuffer(heap, offset: 0, index: 2)
        for r in resident { e.useResource(r, usage: [.read, .write]) }
        e.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: k.threads, height: 1, depth: 1))
        e.endEncoding()
    }
}
