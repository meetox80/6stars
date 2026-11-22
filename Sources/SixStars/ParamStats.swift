import Foundation
import Metal
import RPFKit

enum ParamStats {
    static func run(device: MTLDevice, archive: String, index indexPath: String, samples: Int, out: String) throws {
        let renderer = try Renderer(device: device)
        let file = try MappedFile(path: archive)
        let index = try ArchiveIndex.read(from: indexPath)
        let dir = (indexPath as NSString).deletingLastPathComponent
        let catalog = try Catalog.read(from: "\(dir)/catalog.bin")
        let db = TextureDB(roots: textureRoots, aliasArchive: textureAliases)
        var shaderParams: [UInt32: [UInt32: Int]] = [:]
        var shaderOrder: [UInt32: [UInt32]] = [:]
        var paramTextures: [UInt32: Set<UInt64>] = [:]
        var paramCount: [UInt32: Int] = [:]
        var paramShaders: [UInt32: Set<UInt32>] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: samples) { k in
            let e = catalog.entries[(k * 7919) % catalog.entries.count]
            guard let m = try? Drawable.load(index, file, resource: e.resource, base: Int(e.base)) else { return }
            lock.lock()
            for s in m.shaders {
                if shaderOrder[s.name] == nil || shaderOrder[s.name]!.count < s.textures.count { shaderOrder[s.name] = s.textures.map { $0.param } }
                for t in s.textures {
                    shaderParams[s.name, default: [:]][t.param, default: 0] += 1
                    paramCount[t.param, default: 0] += 1
                    paramShaders[t.param, default: []].insert(s.name)
                    if paramTextures[t.param, default: []].count < 48 { paramTextures[t.param, default: []].insert(t.hash) }
                }
            }
            lock.unlock()
        }
        var lines: [String] = []
        for (p, texs) in paramTextures.sorted(by: { paramCount[$0.key]! > paramCount[$1.key]! }) {
            var fmts: [Int: Int] = [:]
            var sum = SIMD4<Double>(repeating: 0), sq = SIMD4<Double>(repeating: 0)
            var n = 0, normalish = 0, missing = 0, sizes: [String: Int] = [:]
            for h in texs {
                guard let (f, i) = db.find(h) else { missing += 1; continue }
                let inf = f.info(i)
                fmts[inf.format, default: 0] += 1
                sizes["\(inf.width)x\(inf.height)", default: 0] += 1
                guard let img = try? f.image(i), let tex = GPUTexture.make(device, img) else { continue }
                var level = 0
                while max(tex.width >> level, tex.height >> level) > 64 && level + 1 < tex.mipmapLevelCount { level += 1 }
                guard let cg = try? renderer.preview(tex, level: level), let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { continue }
                let w = cg.width, hgt = cg.height, bpr = cg.bytesPerRow
                var s = SIMD4<Double>(repeating: 0), q = SIMD4<Double>(repeating: 0)
                var nn = 0
                for y in 0..<hgt {
                    for x in 0..<w {
                        let o = y * bpr + x * 4
                        let c = SIMD4(Double(bytes[o + 2]), Double(bytes[o + 1]), Double(bytes[o]), Double(bytes[o + 3])) / 255
                        s += c
                        q += c * c
                        if c.z > 0.7 && abs(c.x - 0.5) < 0.3 && abs(c.y - 0.5) < 0.3 { nn += 1 }
                    }
                }
                let cnt = Double(w * hgt)
                sum += s / cnt
                sq += q / cnt
                if Double(nn) / cnt > 0.6 { normalish += 1 }
                n += 1
            }
            let mean = n > 0 ? sum / Double(n) : .zero
            let sh = paramShaders[p]?.count ?? 0
            let hex = String(p, radix: 16)
            let fm = fmts.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            let sz = sizes.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key):\($0.value)" }.joined(separator: ",")
            let mc = [mean.x, mean.y, mean.z, mean.w].map { String(Int($0 * 100)) }.joined(separator: " ")
            lines.append("\(hex)\tuses \(paramCount[p] ?? 0)\tshaders \(sh)\ttex \(texs.count)\tmissing \(missing)\tnormalish \(normalish)/\(n)\tmean% \(mc)\tfmts \(fm)\tsizes \(sz)")
        }
        lines.append("---- shader param order")
        for (s, order) in shaderOrder.sorted(by: { (shaderParams[$0.key] ?? [:]).values.reduce(0, +) > (shaderParams[$1.key] ?? [:]).values.reduce(0, +) }) {
            lines.append(String(format: "%08x\t", s) + order.map { String(format: "%08x", $0) }.joined(separator: " "))
        }
        try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        print("wrote \(out)")
    }
}
