import Foundation
import simd

public struct HeightTile: Sendable {
    public var name: String
    public var width: Int
    public var height: Int
    public var minBound: SIMD3<Float>
    public var maxBound: SIMD3<Float>
    public var surface: [Float]
    public var ground: [Float]

    public init(bytes b: [UInt8]) throws {
        guard b.count >= 0x2C, b[0] == 0x50, b[1] == 0x41, b[2] == 0x4D, b[3] == 0x48 else { throw RPFError.format("not a PAMH heightmap") }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        func f32(_ o: Int) -> Float { Float(bitPattern: UInt32(u32(o))) }
        let nameBytes = b[5..<12].prefix { $0 != 0 }
        name = String(decoding: nameBytes, as: UTF8.self)
        width = u16(0x0C)
        height = u16(0x0E)
        minBound = SIMD3(f32(0x10), f32(0x14), f32(0x18))
        maxBound = SIMD3(f32(0x1C), f32(0x20), f32(0x24))
        let dataSize = u32(0x28)
        let rowTable = 0x2C
        let data = rowTable + 8 * height
        let layer = (dataSize - 8 * height) / 2
        guard width > 0, height > 0, data + 2 * layer <= b.count else { throw RPFError.format("heightmap tile truncated") }
        surface = [Float](repeating: .nan, count: width * height)
        ground = [Float](repeating: .nan, count: width * height)
        let lo = minBound.z, span = maxBound.z - minBound.z
        for r in 0..<height {
            let start = u16(rowTable + 8 * r)
            let count = u16(rowTable + 8 * r + 2)
            let off = u32(rowTable + 8 * r + 4)
            for c in 0..<count where start + c < width && off + c < layer {
                surface[r * width + start + c] = lo + Float(b[data + off + c]) / 255 * span
                ground[r * width + start + c] = lo + Float(b[data + layer + off + c]) / 255 * span
            }
        }
    }
}

public struct HeightField: Sendable {
    public var origin: SIMD2<Float>
    public var cell: Float
    public var width: Int
    public var height: Int
    public var surface: [Float]
    public var ground: [Float]
    public var tiles: Int

    public static func load(index: ArchiveIndex, file: MappedFile) -> HeightField? {
        let entries = index.entries.filter { $0.kind == .zlib && $0.magic == "PAMH" }
        let slots = UnsafeMutableBufferPointer<HeightTile?>.allocate(capacity: entries.count)
        slots.initialize(repeating: nil)
        defer { slots.deallocate() }
        DispatchQueue.concurrentPerform(iterations: entries.count) { i in
            if let d = try? index.load(entries[i], from: file) { slots[i] = try? HeightTile(bytes: d) }
        }
        let tiles = slots.compactMap { $0 }
        guard let first = tiles.first else { return nil }
        let cell = (first.maxBound.x - first.minBound.x) / Float(first.width)
        let x0 = tiles.map { $0.minBound.x }.min()!, y0 = tiles.map { $0.minBound.y }.min()!
        let x1 = tiles.map { $0.maxBound.x }.max()!, y1 = tiles.map { $0.maxBound.y }.max()!
        let w = Int(((x1 - x0) / cell).rounded()), h = Int(((y1 - y0) / cell).rounded())
        var surface = [Float](repeating: .nan, count: w * h)
        var ground = [Float](repeating: .nan, count: w * h)
        for t in tiles {
            let cx = Int(((t.minBound.x - x0) / cell).rounded()), cy = Int(((t.minBound.y - y0) / cell).rounded())
            for r in 0..<t.height where cy + r < h {
                for c in 0..<t.width where cx + c < w {
                    surface[(cy + r) * w + cx + c] = t.surface[r * t.width + c]
                    ground[(cy + r) * w + cx + c] = t.ground[r * t.width + c]
                }
            }
        }
        return HeightField(origin: SIMD2(x0, y0), cell: cell, width: w, height: h, surface: surface, ground: ground, tiles: tiles.count)
    }

    public func position(_ i: Int, _ j: Int) -> SIMD2<Float> {
        origin + SIMD2(Float(i) + 0.5, Float(j) + 0.5) * cell
    }

    public func densestTallArea(minRise: Float = 60) -> SIMD2<Float>? {
        var sum = SIMD2<Double>(0, 0)
        var n = 0.0
        for j in 0..<height {
            for i in 0..<width {
                let s = surface[j * width + i], g = ground[j * width + i]
                if s.isFinite && g.isFinite && s > 10 && s - g > minRise {
                    let p = position(i, j)
                    sum += SIMD2(Double(p.x), Double(p.y))
                    n += 1
                }
            }
        }
        guard n > 0 else { return nil }
        return SIMD2(Float(sum.x / n), Float(sum.y / n))
    }

    public func groundHeight(at p: SIMD2<Float>) -> Float? {
        let i = Int((p.x - origin.x) / cell), j = Int((p.y - origin.y) / cell)
        guard i >= 0, j >= 0, i < width, j < height else { return nil }
        let v = ground[j * width + i]
        return v.isFinite ? v : nil
    }

    public func surfaceHeight(at p: SIMD2<Float>) -> Float? {
        let i = Int((p.x - origin.x) / cell), j = Int((p.y - origin.y) / cell)
        guard i >= 0, j >= 0, i < width, j < height else { return nil }
        let v = surface[j * width + i]
        return v.isFinite ? v : nil
    }
}
