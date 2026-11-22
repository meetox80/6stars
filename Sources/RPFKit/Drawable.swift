import Foundation
import simd

public struct MeshPart: Sendable {
    public var indexStart: Int
    public var indexCount: Int
    public var shader: Int
}

public struct ShaderTexture: Sendable {
    public var param: UInt32
    public var hash: UInt64
}

public struct ShaderInfo: Sendable {
    public var name: UInt32
    public var textures: [ShaderTexture]
}

public struct MeshData: Sendable {
    public var positions: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var uvs: [SIMD2<Float>] = []
    public var uvs1: [SIMD2<Float>] = []
    public var colors0: [UInt32] = []
    public var colors1: [UInt32] = []
    public var indices: [UInt32] = []
    public var lodDistances: [Float] = []
    public var lodPresent: [Bool] = []
    public var parts: [MeshPart] = []
    public var shaders: [ShaderInfo] = []
    public var lod = 0
    public var geometries = 0
    public var failedGeometries = 0

    public init() {}

    public var boundsMin: SIMD3<Float> { positions.reduce(SIMD3(repeating: .infinity)) { simd_min($0, $1) } }
    public var boundsMax: SIMD3<Float> { positions.reduce(SIMD3(repeating: -.infinity)) { simd_max($0, $1) } }
}

struct ByteView {
    let p: UnsafeRawBufferPointer

    @inline(__always) func has(_ o: Int, _ n: Int) -> Bool { o >= 0 && n >= 0 && o + n <= p.count }
    @inline(__always) func u8(_ o: Int) -> UInt8 { p[o] }
    @inline(__always) func u16(_ o: Int) -> UInt16 { p.loadUnaligned(fromByteOffset: o, as: UInt16.self) }
    @inline(__always) func u32(_ o: Int) -> UInt32 { p.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
    @inline(__always) func u64(_ o: Int) -> UInt64 { p.loadUnaligned(fromByteOffset: o, as: UInt64.self) }
    @inline(__always) func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }

    func vptr(_ o: Int) -> Int? {
        guard has(o, 8) else { return nil }
        let v = u64(o)
        return (v >> 32) == 0 && (v >> 28) == 5 ? Int(v & 0x0FFF_FFFF) : nil
    }

    func pptr(_ o: Int) -> Int? {
        guard has(o, 8) else { return nil }
        let v = u64(o)
        return (v >> 32) == 0 && (v >> 28) == 6 ? Int(v & 0x0FFF_FFFF) : nil
    }
}

public enum Drawable {
    static let lodSlots = [0x50, 0x58, 0x60, 0x68]

    public static var debugFailures: ((String) -> Void)?

    public static func lodLevels(_ virtual: [UInt8], at base: Int = 0) -> [Bool] {
        virtual.withUnsafeBytes { vb in
            let v = ByteView(p: vb)
            return lodSlots.map { v.vptr(base + $0) != nil }
        }
    }

    public static func lodDistances(_ virtual: [UInt8], at base: Int = 0) -> [Float] {
        virtual.withUnsafeBytes { vb in
            let v = ByteView(p: vb)
            return (0..<4).map { v.has(base + 0x70 + 4 * $0, 4) ? v.f32(base + 0x70 + 4 * $0) : 0 }
        }
    }

    static func lodSlot(_ v: ByteView, _ base: Int, _ want: Int) -> Int? {
        let present = lodSlots.map { v.vptr(base + $0) }
        let order = Array(want..<4) + Array((0..<want).reversed())
        for i in order { if let p = present[i], v.has(p, 10) { return i } }
        return nil
    }

    public static func physicalExtent(_ virtual: [UInt8], at base: Int = 0, lod want: Int = 0) -> Int {
        virtual.withUnsafeBytes { vb in
            let v = ByteView(p: vb)
            var need = 0
            guard let li = lodSlot(v, base, want), let lod = v.vptr(base + lodSlots[li]), let models = v.vptr(lod) else { return 0 }
            for mi in 0..<Int(v.u16(lod + 8)) {
                guard let m = v.vptr(models + 8 * mi), v.has(m, 0x12), let garr = v.vptr(m + 8) else { continue }
                for gi in 0..<Int(v.u16(m + 0x10)) {
                    guard let g = v.vptr(garr + 8 * gi), v.has(g, 0xA0) else { continue }
                    if let vd = v.pptr(g + 0x68) { need = max(need, vd + Int(v.u32(g + 0x58)) * 4) }
                    if let ip = v.vptr(g + 0x40), let idesc = v.vptr(ip), v.has(idesc, 0x20), let id = v.pptr(idesc + 0x18) {
                        need = max(need, id + Int(v.u32(idesc + 0x08)) * 4)
                    }
                }
            }
            return need
        }
    }

    public static func load(_ index: ArchiveIndex, _ f: MappedFile, resource: UInt64, base: Int, lod: Int = 0) throws -> MeshData {
        let (virt, streams) = try index.virtualSegment(at: resource, from: f)
        let need = physicalExtent(virt, at: base, lod: lod)
        guard need > 0 else { throw RPFError.format("drawable has no geometry buffers") }
        let phys = try index.physicalSegment(streams, from: f, upTo: need)
        return try decode(Resource(virtual: virt, physical: phys), at: base, lod: lod)
    }

    public static func shaderNames(_ virtual: [UInt8], at base: Int) -> [UInt32] {
        virtual.withUnsafeBytes { vb in shaders(ByteView(p: vb), base).map { $0.name } }
    }

    static func shaders(_ v: ByteView, _ base: Int) -> [ShaderInfo] {
        guard let sg = v.vptr(base + 0x10), v.has(sg, 0x1A), let arr = v.vptr(sg + 0x10) else { return [] }
        var out: [ShaderInfo] = []
        for i in 0..<Int(v.u16(sg + 0x18)) {
            guard let sh = v.vptr(arr + 8 * i), v.has(sh, 0x28) else { out.append(ShaderInfo(name: 0, textures: [])); continue }
            var tex: [ShaderTexture] = []
            if let tp = v.vptr(sh + 0x10), let params = v.vptr(sh + 0x20), v.has(params, 8) {
                let n = Int(v.u8(params + 1))
                for t in 0..<n where v.has(params + 8 + 8 * t, 8) {
                    guard let ts = v.vptr(tp + 8 * t), let rec = v.vptr(ts + 0x30), v.has(rec, 0x10) else { continue }
                    tex.append(ShaderTexture(param: v.u32(params + 8 + 8 * t), hash: v.u64(rec + 8)))
                }
            }
            out.append(ShaderInfo(name: v.u32(sh), textures: tex))
        }
        return out
    }

    static func uv(_ P: ByteView, _ page: Int, _ slot: UInt32, count: Int, range: Float) -> [SIMD2<Float>]? {
        let off = page + Int(slot >> 8) * 2
        switch slot & 0xFF {
        case 0x28:
            guard P.has(off, 4 * count) else { return nil }
            let k = 2 * range / 65535
            return (0..<count).map { i in SIMD2(Float(P.u16(off + 4 * i)) * k - range, Float(P.u16(off + 4 * i + 2)) * k - range) }
        case 0x42:
            guard P.has(off, 8 * count) else { return nil }
            return (0..<count).map { i in SIMD2(P.f32(off + 8 * i), P.f32(off + 8 * i + 4)) }
        default:
            return nil
        }
    }

    static func words(_ P: ByteView, _ page: Int, _ slot: UInt32, count: Int) -> [UInt32]? {
        guard slot != 0, (slot & 0xF0) == 0x20 else { return nil }
        let off = page + Int(slot >> 8) * 2
        guard P.has(off, 4 * count) else { return nil }
        return (0..<count).map { P.u32(off + 4 * $0) }
    }

    static func octNormal(_ w: UInt32) -> SIMD3<Float> {
        let a = Float((w >> 10) & 1023) / 1023 * 2 - 1, b = Float(w & 1023) / 1023 * 2 - 1
        var n = SIMD3(a, b, 1 - abs(a) - abs(b))
        if n.z < 0 { n = SIMD3((1 - abs(b)) * (a >= 0 ? 1 : -1), (1 - abs(a)) * (b >= 0 ? 1 : -1), n.z) }
        return simd_normalize(n)
    }

    static func vertexNormals(_ P: ByteView, _ page: Int, count: Int) -> [SIMD3<Float>]? {
        guard P.has(page, 0x80) else { return nil }
        let slot = P.u32(page + 8)
        switch slot & 0xFF {
        case 0x21:
            guard let w = words(P, page, slot, count: count) else { return nil }
            return w.map { v in
                let n = octNormal(v)
                return SIMD3(n.y, n.x, n.z)
            }
        case 0x63:
            let off = page + Int(slot >> 8) * 2
            guard P.has(off, 12 * count) else { return nil }
            return (0..<count).map { i in SIMD3(P.f32(off + 12 * i), P.f32(off + 12 * i + 4), P.f32(off + 12 * i + 8)) }
        default:
            return nil
        }
    }

    public static func decode(_ r: Resource, at base: Int = 0, lod want: Int = 0) throws -> MeshData {
        var mesh = MeshData()
        try r.virtual.withUnsafeBytes { vb in
            try r.physical.withUnsafeBytes { pb in
                let v = ByteView(p: vb), ph = ByteView(p: pb)
                guard let li = lodSlot(v, base, want), let lod = v.vptr(base + lodSlots[li]) else { throw RPFError.format("drawable has no LOD") }
                mesh.lod = li
                mesh.shaders = shaders(v, base)
                mesh.lodPresent = lodSlots.map { v.vptr(base + $0) != nil }
                mesh.lodDistances = (0..<4).map { v.has(base + 0x70 + 4 * $0, 4) ? v.f32(base + 0x70 + 4 * $0) : 0 }
                guard let models = v.vptr(lod) else { throw RPFError.format("drawable LOD has no models") }
                let mcount = Int(v.u16(lod + 8))
                for mi in 0..<mcount {
                    guard let m = v.vptr(models + 8 * mi), v.has(m, 0x12), let garr = v.vptr(m + 8) else { continue }
                    let gcount = Int(v.u16(m + 0x10))
                    let map = v.vptr(m + 0x20)
                    for gi in 0..<gcount {
                        mesh.geometries += 1
                        guard let g = v.vptr(garr + 8 * gi), v.has(g, 0xA0),
                              let vdata = v.pptr(g + 0x50 + 0x18),
                              let ip = v.vptr(g + 0x40), let idesc = v.vptr(ip), let idata = v.pptr(idesc + 0x18) else {
                            mesh.failedGeometries += 1
                            if let dbg = debugFailures, let g = v.vptr(garr + 8 * gi), v.has(g, 0xA0) {
                                let words = (0..<20).map { String(format: "%016llx", v.u64(g + 8 * $0)) }.joined(separator: " ")
                                dbg("chain g=\(String(g, radix: 16)) \(words)")
                            }
                            continue
                        }
                        let vbytes = v.has(g + 0x58, 4) ? Int(v.u32(g + 0x58)) * 4 : 0
                        guard let pos = page(ph, vdata, bytes: vbytes) else {
                            mesh.failedGeometries += 1
                            if let dbg = debugFailures {
                                let hb = ph.has(vdata, 0x80) ? (0..<16).map { String(format: "%08x", ph.u32(vdata + 4 * $0)) }.joined(separator: " ") : "oob \(vdata) of \(ph.p.count)"
                                dbg("page \(hb) vbytes \(vbytes)")
                            }
                            continue
                        }
                        guard let tris = meshlets(ph, idata, vertexCount: pos.count), !tris.isEmpty else {
                            mesh.failedGeometries += 1
                            if let dbg = debugFailures {
                                let hb = ph.has(idata, 32) ? (0..<8).map { String(format: "%08x", ph.u32(idata + 4 * $0)) }.joined(separator: " ") : "oob \(idata) of \(ph.p.count)"
                                dbg("meshlet \(hb) verts \(pos.count)")
                            }
                            continue
                        }
                        let quantized = (ph.u32(vdata) & 0xFF) == 0x42 && (ph.u32(vdata) >> 8) * 2 == 0x80
                        let rw = quantized ? ph.f32(vdata + 0x7C) : 4
                        let range = rw.isFinite && rw > 0 && rw < 1e6 ? rw : 4
                        let n = pos.count
                        let uvs = uv(ph, vdata, ph.u32(vdata + 12), count: n, range: range)
                        let uvs1 = uv(ph, vdata, ph.u32(vdata + 16), count: n, range: range)
                        let shader = map.flatMap { v.has($0 + 2 * gi, 2) ? Int(v.u16($0 + 2 * gi)) : nil } ?? 0
                        let first = UInt32(mesh.positions.count)
                        mesh.parts.append(MeshPart(indexStart: mesh.indices.count, indexCount: tris.count, shader: shader))
                        mesh.positions += pos
                        if let nn = vertexNormals(ph, vdata, count: n) {
                            mesh.normals += nn
                        } else {
                            mesh.normals += faceNormals(pos, tris)
                        }
                        mesh.uvs += uvs ?? [SIMD2<Float>](repeating: .zero, count: n)
                        mesh.uvs1 += uvs1 ?? uvs ?? [SIMD2<Float>](repeating: .zero, count: n)
                        mesh.colors0 += words(ph, vdata, ph.u32(vdata + 4), count: n) ?? [UInt32](repeating: 0xFFFF_FFFF, count: n)
                        mesh.colors1 += words(ph, vdata, ph.u32(vdata + 48), count: n) ?? [UInt32](repeating: 0xFF00_0000, count: n)
                        mesh.indices += tris.map { $0 + first }
                    }
                }
            }
        }
        guard !mesh.indices.isEmpty else { throw RPFError.format("drawable produced no triangles") }
        return mesh
    }

    public static func slotSurvey(_ r: Resource, at base: Int = 0) -> [[UInt32]] {
        var out: [[UInt32]] = []
        r.virtual.withUnsafeBytes { vb in
            r.physical.withUnsafeBytes { pb in
                let v = ByteView(p: vb), ph = ByteView(p: pb)
                guard let lod = lodSlots.lazy.compactMap({ v.vptr(base + $0) }).first, v.has(lod, 10), let models = v.vptr(lod) else { return }
                for mi in 0..<Int(v.u16(lod + 8)) {
                    guard let m = v.vptr(models + 8 * mi), v.has(m, 0x12), let garr = v.vptr(m + 8) else { continue }
                    for gi in 0..<Int(v.u16(m + 0x10)) {
                        guard let g = v.vptr(garr + 8 * gi), v.has(g, 0xA0), let vd = v.pptr(g + 0x68), ph.has(vd, 0x40) else { continue }
                        out.append((0..<16).map { ph.u32(vd + 4 * $0) })
                    }
                }
            }
        }
        return out
    }

    public static func rawSlot(_ r: Resource, at base: Int, geometry: Int, slot: Int, count: Int) -> [UInt32] {
        var out: [UInt32] = []
        r.virtual.withUnsafeBytes { vb in
            r.physical.withUnsafeBytes { pb in
                let v = ByteView(p: vb), ph = ByteView(p: pb)
                guard let li = lodSlot(v, base, 0), let lod = v.vptr(base + lodSlots[li]), let models = v.vptr(lod) else { return }
                var k = 0
                for mi in 0..<Int(v.u16(lod + 8)) {
                    guard let m = v.vptr(models + 8 * mi), let garr = v.vptr(m + 8) else { continue }
                    for gi in 0..<Int(v.u16(m + 0x10)) {
                        defer { k += 1 }
                        guard k == geometry, let g = v.vptr(garr + 8 * gi), let vd = v.pptr(g + 0x68), ph.has(vd, 0x40) else { continue }
                        let w = ph.u32(vd + 4 * slot)
                        guard w != 0 else { return }
                        let off = vd + Int(w >> 8) * 2, es = Int(w & 0xF0) >> 3
                        let vbytes = Int(v.u32(g + 0x58)) * 4
                        let next = (0..<16).map { ph.u32(vd + 4 * $0) }.filter { $0 != 0 }.map { vd + Int($0 >> 8) * 2 }.filter { $0 > off }.min() ?? (vd + vbytes)
                        let n = min(count, (next - off) / max(es, 1))
                        for i in 0..<n where ph.has(off + es * i, 4) { out.append(ph.u32(off + es * i)) }
                    }
                }
            }
        }
        return out
    }

    public static func pageHeaders(_ r: Resource, at base: Int) -> [(slots: [UInt32], header: [UInt32], uvRaw: [UInt32])] {
        var out: [(slots: [UInt32], header: [UInt32], uvRaw: [UInt32])] = []
        r.virtual.withUnsafeBytes { vb in
            r.physical.withUnsafeBytes { pb in
                let v = ByteView(p: vb), ph = ByteView(p: pb)
                guard let li = lodSlot(v, base, 0), let lod = v.vptr(base + lodSlots[li]), let models = v.vptr(lod) else { return }
                for mi in 0..<Int(v.u16(lod + 8)) {
                    guard let m = v.vptr(models + 8 * mi), let garr = v.vptr(m + 8) else { continue }
                    for gi in 0..<Int(v.u16(m + 0x10)) {
                        guard let g = v.vptr(garr + 8 * gi), let vd = v.pptr(g + 0x68), ph.has(vd, 0x80) else { continue }
                        let slots = (0..<16).map { ph.u32(vd + 4 * $0) }
                        let header = (16..<32).map { ph.u32(vd + 4 * $0) }
                        var raw: [UInt32] = []
                        let w = slots[3]
                        if w != 0 {
                            let off = vd + Int(w >> 8) * 2
                            for i in 0..<64 where ph.has(off + 4 * i, 4) { raw.append(ph.u32(off + 4 * i)) }
                        }
                        out.append((slots, header, raw))
                    }
                }
            }
        }
        return out
    }

    static func page(_ P: ByteView, _ o: Int, bytes: Int) -> [SIMD3<Float>]? {
        guard P.has(o, 0x40) else { return nil }
        var slots: [(off: Int, fmt: UInt32)] = []
        for i in 0..<16 {
            let s = P.u32(o + 4 * i)
            if s != 0 { slots.append((Int(s >> 8) * 2, s & 0xFF)) }
        }
        slots.sort { $0.off < $1.off }
        guard let first = slots.first else { return nil }
        let elem = Int(first.fmt >> 4) * 2
        guard elem > 0 else { return nil }
        let span = slots.count > 1 ? slots[1].off - first.off : bytes - first.off
        let n = span / elem
        let raw = o + first.off
        guard n > 0, n < 4_000_000, P.has(raw, elem * n) else { return nil }
        var out = [SIMD3<Float>](repeating: .zero, count: n)
        switch first.fmt {
        case 0x42:
            guard first.off == 0x80 else { return nil }
            let b = SIMD3(P.f32(o + 0x60), P.f32(o + 0x64), P.f32(o + 0x68))
            let k = Int32(bitPattern: P.u32(o + 0x6C))
            let s = SIMD3(P.f32(o + 0x70), P.f32(o + 0x74), P.f32(o + 0x78))
            for i in 0..<n {
                let r = raw + 8 * i
                let r0 = UInt32(P.u8(r)), r1 = UInt32(P.u8(r + 1)), r2 = UInt32(P.u8(r + 2)), r3 = UInt32(P.u8(r + 3))
                let r4 = UInt32(P.u8(r + 4)), r5 = UInt32(P.u8(r + 5)), r6 = UInt32(P.u8(r + 6)), r7 = UInt32(P.u8(r + 7))
                let f1 = Float(r3 << 16 | r2 << 8 | r1)
                let f2 = Float(r5 << 16 | r4 << 8 | r0)
                let f3 = Float(r7 << 8 | r6)
                switch k {
                case 1: out[i] = SIMD3(b.y + f2 * s.y, b.z + f3 * s.z, b.x + f1 * s.x)
                case 0: out[i] = SIMD3(b.z + f3 * s.z, b.y + f2 * s.y, b.x + f1 * s.x)
                default: out[i] = SIMD3(b.x + f1 * s.x, b.y + f2 * s.y, b.z + f3 * s.z)
                }
            }
        case 0x63:
            for i in 0..<n {
                let r = raw + 12 * i
                out[i] = SIMD3(P.f32(r), P.f32(r + 4), P.f32(r + 8))
            }
        default:
            return nil
        }
        return out
    }

    nonisolated(unsafe) public static var meshletStats = [Int](repeating: 0, count: 6)
    nonisolated(unsafe) public static var meshletDump: ((String) -> Void)? = nil

    static func meshlets(_ P: ByteView, _ o: Int, vertexCount: Int) -> [UInt32]? {
        guard P.has(o, 12) else { return nil }
        let w = P.u32(o)
        guard w & 0x8000_0000 != 0 else { return nil }
        let cnt = Int(w & 0xFFFF)
        let ntri = Int(P.u32(o + 4)), nvert = Int(P.u32(o + 8))
        let tri0 = o + 12 + 16 * cnt
        let vl0 = tri0 + 4 * ntri
        guard cnt > 0, ntri > 0, P.has(o + 12, 16 * cnt), P.has(tri0, 4 * ntri), P.has(vl0, 2 * nvert) else { return nil }
        var voffs = [Int](repeating: 0, count: cnt), toffs = [Int](repeating: 0, count: cnt + 1)
        var vwrap = 0, twrap = 0, pv = -1, pt = -1
        for m in 0..<cnt {
            var vo = Int(P.u16(o + 12 + 16 * m + 4)) + vwrap
            var to = Int(P.u16(o + 12 + 16 * m + 6)) + twrap
            if vo < pv { vwrap += 0x10000; vo += 0x10000 }
            if to < pt { twrap += 0x10000; to += 0x10000 }
            voffs[m] = vo
            toffs[m] = to
            pv = vo
            pt = to
        }
        toffs[cnt] = ntri
        if let d = meshletDump {
            var hdr: [String] = []
            for m in 0..<min(cnt, 4) { hdr.append((0..<4).map { String(format: "%08x", P.u32(o + 12 + 16 * m + 4 * $0)) }.joined(separator: " ")) }
            d("meshlets cnt \(cnt) ntri \(ntri) nvert \(nvert) verts \(vertexCount) head \(String(format: "%08x", w)) | " + hdr.joined(separator: " | "))
            meshletStats[4] += cnt
            for m in 0..<cnt where toffs[m + 1] < toffs[m] { meshletStats[5] += 1 }
        }
        var out: [UInt32] = []
        out.reserveCapacity(ntri * 3)
        for m in 0..<cnt {
            let t1 = min(toffs[m + 1], ntri)
            var t = toffs[m]
            while t < t1 {
                let word = P.u32(tri0 + 4 * t)
                let l0 = Int(word & 0x7F), l1 = Int((word >> 7) & 0x7F), l2 = Int((word >> 14) & 0x7F)
                let a = voffs[m] + l0, b = voffs[m] + l1, c = voffs[m] + l2
                if meshletDump != nil { meshletStats[0] += 1 }
                if a < nvert, b < nvert, c < nvert {
                    let ia = Int(P.u16(vl0 + 2 * a)), ib = Int(P.u16(vl0 + 2 * b)), ic = Int(P.u16(vl0 + 2 * c))
                    if ia < vertexCount, ib < vertexCount, ic < vertexCount, ia != ib, ib != ic, ia != ic {
                        out.append(UInt32(ia))
                        out.append(UInt32(ib))
                        out.append(UInt32(ic))
                    } else if meshletDump != nil {
                        if ia >= vertexCount || ib >= vertexCount || ic >= vertexCount { meshletStats[2] += 1 } else { meshletStats[3] += 1 }
                    }
                } else if meshletDump != nil {
                    meshletStats[1] += 1
                }
                t += 1
            }
        }
        return out
    }

    static func faceNormals(_ pos: [SIMD3<Float>], _ idx: [UInt32]) -> [SIMD3<Float>] {
        normals(pos, idx)
    }

    static func normals(_ pos: [SIMD3<Float>], _ idx: [UInt32]) -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: pos.count)
        var i = 0
        while i + 2 < idx.count {
            let a = Int(idx[i]), b = Int(idx[i + 1]), c = Int(idx[i + 2])
            let fn = simd_cross(pos[b] - pos[a], pos[c] - pos[a])
            n[a] += fn
            n[b] += fn
            n[c] += fn
            i += 3
        }
        for k in n.indices {
            let l = simd_length(n[k])
            n[k] = l > 1e-12 ? n[k] / l : SIMD3(0, 0, 1)
        }
        return n
    }
}
