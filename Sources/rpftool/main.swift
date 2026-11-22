import Foundation
import RPFKit
import simd

func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

func parseOffset(_ s: String) -> UInt64? {
    s.hasPrefix("0x") ? UInt64(s.dropFirst(2), radix: 16) : UInt64(s)
}

func gb(_ v: UInt64) -> String { String(format: "%.2f GB", Double(v) / 1e9) }

func stats(_ idx: ArchiveIndex) {
    var kinds: [String: (Int, UInt64)] = [:]
    var magics: [String: (Int, UInt64, UInt64)] = [:]
    var covered: UInt64 = 0
    var gaps: [(UInt64, UInt64)] = []
    var cursor: UInt64 = 0
    for e in idx.entries {
        let k = "\(e.kind.name)\(e.padded ? "" : " (unpadded)")"
        kinds[k] = ((kinds[k]?.0 ?? 0) + 1, (kinds[k]?.1 ?? 0) + e.size)
        if e.kind == .zlib {
            let m = magics[e.magic] ?? (0, 0, 0)
            magics[e.magic] = (m.0 + 1, m.1 + e.size, m.2 + e.unpacked)
        }
        if e.offset > cursor { gaps.append((cursor, e.offset - cursor)) }
        if e.kind == .zlib || e.kind == .rpf9 {
            covered += e.size
            cursor = max(cursor, e.offset + e.size)
        } else {
            cursor = max(cursor, e.offset)
        }
    }
    if idx.archiveSize > cursor { gaps.append((cursor, idx.archiveSize - cursor)) }
    print("archive \(gb(idx.archiveSize)), \(idx.entries.count) entries, explained by zlib+toc: \(gb(covered)) (\(String(format: "%.1f", Double(covered) * 100 / Double(idx.archiveSize)))%)")
    for (k, v) in kinds.sorted(by: { $0.value.0 > $1.value.0 }) {
        print(String(format: "  %-20@ %8d  %@", k as NSString, v.0, gb(v.1) as NSString))
    }
    print("zlib content by magic (count, packed, unpacked):")
    for (k, v) in magics.sorted(by: { $0.value.1 > $1.value.1 }).prefix(30) {
        print(String(format: "  %-10@ %8d  %10@  %10@", k as NSString, v.0, gb(v.1) as NSString, gb(v.2) as NSString))
    }
    let bigGaps = gaps.filter { $0.1 >= 0x10000 }.sorted { $0.1 > $1.1 }
    let gapTotal = bigGaps.reduce(UInt64(0)) { $0 + $1.1 }
    print("unexplained regions >= 64 KB: \(bigGaps.count), \(gb(gapTotal))")
    for g in bigGaps.prefix(10) { print(String(format: "  0x%011llx  %10llu bytes", g.0, g.1)) }
}

let args = CommandLine.arguments
let usage = "usage: rpftool scan <rpf> <index> | stats <index> | dump <rpf> <index> <offset> <out> | list <index> <magic> [limit]"
guard args.count >= 2 else { fail(usage) }

switch args[1] {
case "scan":
    guard args.count == 4 else { fail(usage) }
    let f = try MappedFile(path: args[2])
    let t0 = Date()
    let idx = ArchiveIndex.scan(f) { d, n in
        if d % 8 == 0 || d == n {
            FileHandle.standardError.write(String(format: "\r%d/%d segments", d, n).data(using: .utf8)!)
        }
    }
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    try idx.write(to: args[3])
    print(String(format: "scanned in %.1fs", Date().timeIntervalSince(t0)))
    stats(idx)
case "stats":
    guard args.count == 3 else { fail(usage) }
    stats(try ArchiveIndex.read(from: args[2]))
case "list":
    guard args.count >= 4 else { fail(usage) }
    let idx = try ArchiveIndex.read(from: args[2])
    let limit = args.count > 4 ? Int(args[4]) ?? 20 : 20
    for e in idx.entries.filter({ $0.magic == args[3] || $0.kind.name == args[3] }).prefix(limit) {
        print(String(format: "0x%011llx  %@  packed=%llu unpacked=%llu", e.offset, e.kind.name as NSString, e.size, e.unpacked))
    }
case "extract":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let want = args[4]
    let dir = args[5]
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let all = idx.entries.filter { $0.kind == .zlib }.sorted { $0.offset < $1.offset }
    var n = 0
    var i = 0
    while i < all.count {
        let e = all[i]
        i += 1
        guard e.magic == want, var b = try? idx.load(e, from: f) else { continue }
        var last = b.count
        while last == 0x10000, i < all.count, let nb = try? idx.load(all[i], from: f) {
            b += nb
            last = nb.count
            i += 1
        }
        try Data(b).write(to: URL(fileURLWithPath: "\(dir)/\(String(e.offset, radix: 16)).bin"))
        n += 1
    }
    print("extracted \(n) \(want) entries to \(dir)")
case "dump":
    guard args.count == 6, let off = parseOffset(args[4]) else { fail(usage) }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    guard let e = idx.entry(at: off) else { fail("no entry at \(args[4])") }
    let bytes = try idx.load(e, from: f)
    try Data(bytes).write(to: URL(fileURLWithPath: args[5]))
    print("\(e.kind.name) at \(args[4]): wrote \(bytes.count) bytes")
case "dumpres":
    guard args.count == 7, let off = parseOffset(args[4]), let maxChunks = Int(args[6]) else {
        fail("usage: rpftool dumpres <rpf> <index> <offset> <out> <chunks>")
    }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    guard var i = idx.entries.firstIndex(where: { $0.offset == off }) else { fail("no entry at \(args[4])") }
    var out: [UInt8] = []
    var sizes: [Int] = []
    while sizes.count < maxChunks && i < idx.entries.count {
        let e = idx.entries[i]
        out += try idx.load(e, from: f)
        sizes.append(Int(e.unpacked))
        let next = (e.offset + e.size + 15) & ~15
        i += 1
        if i >= idx.entries.count || idx.entries[i].offset != next || idx.entries[i].kind != .zlib { break }
    }
    try Data(out).write(to: URL(fileURLWithPath: args[5]))
    print("chunks \(sizes.map { String(format: "0x%x", $0) }.joined(separator: " ")) total 0x\(String(out.count, radix: 16))")
case "grep32":
    guard args.count >= 5 else { fail("usage: rpftool grep32 <rpf> <index> <hex32>...") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let needles = Set(args[4...].compactMap { UInt32($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: 16) })
    let zl = idx.entries.filter { $0.kind == .zlib }
    let lock = NSLock()
    var hits: [(UInt64, UInt32, Int)] = []
    DispatchQueue.concurrentPerform(iterations: zl.count) { i in
        guard let d = try? idx.load(zl[i], from: f), d.count >= 4 else { return }
        var local: [(UInt64, UInt32, Int)] = []
        d.withUnsafeBytes { p in
            var o = 0
            while o + 4 <= p.count {
                let v = p.loadUnaligned(fromByteOffset: o, as: UInt32.self)
                if needles.contains(v) { local.append((zl[i].offset, v, o)) }
                o += 4
            }
        }
        if !local.isEmpty {
            lock.lock()
            hits += local
            lock.unlock()
        }
    }
    for h in hits.sorted(by: { $0.0 < $1.0 }) {
        let e = idx.entry(at: h.0)!
        print(String(format: "0x%011llx  value %08x at +0x%x  chunk-head %@", h.0, h.1, h.2, e.magic as NSString))
    }
    print("\(hits.count) hits")
case "entities":
    guard args.count == 5 else { fail("usage: rpftool entities <rpf> <index> <out>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let t0 = Date()
    let files = Entities.loadAll(index: idx, file: f)
    var d = Data()
    func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
    var total = 0
    var archetypes = Set<UInt32>()
    var types: [UInt32: Int] = [:]
    for (off, ents) in files {
        for e in ents {
            put(off); put(e.position.x); put(e.position.y); put(e.position.z)
            put(e.rotation.x); put(e.rotation.y); put(e.rotation.z); put(e.rotation.w)
            put(e.name64); put(e.archetype); put(e.scaleXY); put(e.scaleZ); put(e.lodDist); put(e.childLodDist); put(e.flags); put(e.type); put(UInt32(0))
            archetypes.insert(e.archetype)
            types[e.type, default: 0] += 1
        }
        total += ents.count
    }
    try d.write(to: URL(fileURLWithPath: args[4]))
    print(String(format: "%d files, %d entities, %d archetypes in %.1fs", files.count, total, archetypes.count, Date().timeIntervalSince(t0)))
    for (k, v) in types.sorted(by: { $0.value > $1.value }) { print(String(format: "  type %08x: %d", k, v)) }
case "catalog":
    guard args.count == 5 else { fail("usage: rpftool catalog <rpf> <index> <out>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let t0 = Date()
    let cat = Catalog.build(index: idx, file: f) { d, n in
        FileHandle.standardError.write(String(format: "\r%d/%d", d, n).data(using: .utf8)!)
    }
    try cat.write(to: args[4])
    let dicts = Set(cat.entries.filter { $0.base != 0 }.map { $0.resource }).count
    print(String(format: "\n%d drawables (%d unique hashes, %d inside %d dictionaries) in %.1fs", cat.entries.count, cat.byHash.count,
                 cat.entries.filter { $0.base != 0 }.count, dicts, Date().timeIntervalSince(t0)))
case "meshtest":
    guard args.count >= 6 else { fail("usage: rpftool meshtest <rpf> <index> <catalog> <count|name>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    var picks: [CatalogEntry] = []
    if let n = Int(args[5]) {
        var g = SystemRandomNumberGenerator()
        picks = (0..<n).map { _ in cat.entries[Int.random(in: 0..<cat.entries.count, using: &g)] }
    } else if let i = cat.byHash[Hash.joaat(args[5])] {
        picks = [cat.entries[i]]
    }
    let lock = NSLock()
    var ok = 0, failed: [String: Int] = [:], tris = 0, geoms = 0, badGeoms = 0, mismatch = 0
    var samples: [String: [String]] = [:]
    Drawable.debugFailures = { s in
        let k = String(s.prefix(while: { $0 != " " }))
        lock.lock()
        if samples[k, default: []].count < 4 { samples[k, default: []].append(s) }
        samples[k + "#n", default: []].append("")
        lock.unlock()
    }
    let t0 = Date()
    DispatchQueue.concurrentPerform(iterations: picks.count) { i in
        let e = picks[i]
        do {
            let m = try Drawable.load(idx, f, resource: e.resource, base: Int(e.base))
            let mn = m.boundsMin, mx = m.boundsMax
            let tol = simd_length(e.boundsMax - e.boundsMin) * 0.02 + 0.05
            let fits = simd_reduce_max(e.boundsMin - mn) <= tol && simd_reduce_max(mx - e.boundsMax) <= tol
            lock.lock()
            ok += 1; tris += m.indices.count / 3; geoms += m.geometries; badGeoms += m.failedGeometries
            if !fits { mismatch += 1 }
            if picks.count == 1 { print(e.name, m.positions.count, "verts", m.indices.count / 3, "tris", "bounds", mn, mx, "catalog", e.boundsMin, e.boundsMax) }
            lock.unlock()
        } catch {
            lock.lock(); failed["\(error)", default: 0] += 1
            if failed["\(error)"]! <= 3 { print(String(format: "FAIL %@ res 0x%llx base 0x%x: %@", e.name, e.resource, e.base, "\(error)")) }
            lock.unlock()
        }
    }
    print(String(format: "%d ok, %d failed, %d tris, %d/%d geometries failed, %d outside catalog bounds, %.1fs", ok, picks.count - ok, tris, badGeoms, geoms, mismatch, Date().timeIntervalSince(t0)))
    for (k, v) in failed.sorted(by: { $0.value > $1.value }).prefix(6) { print("  \(v)x \(k)") }
    for (k, v) in samples where !k.hasSuffix("#n") {
        print("\(k): \(samples[k + "#n"]?.count ?? 0) geometries")
        for x in v { print("   ", x.prefix(400)) }
    }
case "mapstats":
    guard args.count == 4 else { fail("usage: rpftool mapstats <rpf> <index>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let starts = MapData.prd0Starts(idx)
    let lock = NSLock()
    var totals: [String: (Int, Int, String)] = [:]
    var maps = 0
    func walk(_ p: PRD0, _ s: PRD0Struct, _ base: Int, _ path: String, _ out: inout [String: (Int, String)]) {
        for (i, m) in s.members.enumerated() where m.name != 0x100 {
            let key = path + "/" + String(format: "%08x", m.name)
            if m.type == 0x52 || m.type == 0x5C {
                let elem = i > 0 && s.members[i - 1].name == 0x100 ? s.members[i - 1] : nil
                let et = elem.map { String(format: "%x/%08x", $0.type, $0.ref) } ?? "?"
                if let a = p.array(at: base + m.offset) { out[key] = (a.count, et) }
            } else if m.type == 5, let sub = p.structs[m.ref] {
                walk(p, sub, base + m.offset, key, &out)
            }
        }
    }
    DispatchQueue.concurrentPerform(iterations: starts.count) { i in
        guard let r = try? idx.resource(at: starts[i], from: f, physical: false), let p = try? PRD0(r.virtual),
              let md = p.block(ofType: MapData.mapStruct), let ms = p.structs[MapData.mapStruct] else { return }
        var out: [String: (Int, String)] = [:]
        walk(p, ms, md.offset, "", &out)
        lock.lock()
        maps += 1
        for (k, v) in out {
            let t = totals[k] ?? (0, 0, v.1)
            totals[k] = (t.0 + v.0, t.1 + 1, v.1)
        }
        lock.unlock()
    }
    print("\(maps) maps")
    for (k, v) in totals.sorted(by: { $0.value.0 > $1.value.0 }) {
        print(String(format: "  %-44@ %9d in %5d maps  elem %@", k as NSString, v.0, v.1, v.2 as NSString))
    }
case "prd0stats":
    guard args.count == 4 else { fail("usage: rpftool prd0stats <rpf> <index>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let starts = MapData.prd0Starts(idx)
    let lock = NSLock()
    struct Agg { var files = 0; var instances = 0; var arrays: [UInt32: Int] = [:]; var members: [PRD0Member] = []; var size = 0; var example: UInt64 = 0 }
    var aggs: [UInt32: Agg] = [:]
    DispatchQueue.concurrentPerform(iterations: starts.count) { i in
        guard let r = try? idx.resource(at: starts[i], from: f, physical: false), let p = try? PRD0(r.virtual) else { return }
        var local: [UInt32: Agg] = [:]
        for blk in p.blocks {
            guard let s = p.structs[blk.type], s.size > 0 else { continue }
            var a = local[blk.type] ?? Agg()
            let n = blk.size / s.size
            a.instances += n
            a.members = s.members
            a.size = s.size
            a.example = starts[i]
            for k in 0..<n {
                for m in s.members where m.type == 0x52 || m.type == 0x5C {
                    if let arr = p.array(at: blk.offset + k * s.size + m.offset) { a.arrays[m.name, default: 0] += arr.count }
                }
            }
            local[blk.type] = a
        }
        lock.lock()
        for (k, v) in local {
            var a = aggs[k] ?? Agg()
            a.files += 1
            a.instances += v.instances
            a.members = v.members
            a.size = v.size
            a.example = v.example
            for (mk, mv) in v.arrays { a.arrays[mk, default: 0] += mv }
            aggs[k] = a
        }
        lock.unlock()
    }
    print("\(starts.count) PRD0 resources")
    for (k, a) in aggs.sorted(by: { $0.value.files > $1.value.files }).prefix(Int(ProcessInfo.processInfo.environment["LIMIT"] ?? "60") ?? 60) {
        let ms = a.members.filter { $0.name != 0x100 }.map { m -> String in
            let c = a.arrays[m.name].map { "[\($0)]" } ?? ""
            return String(format: "%08x@%x:%x%@%@", m.name, m.offset, m.type, m.type == 5 ? String(format: "/%08x", m.ref) : "", c)
        }
        print(String(format: "%08x size %d files %d instances %d ex 0x%llx: ", k, a.size, a.files, a.instances, a.example) + ms.joined(separator: " "))
    }
case "prd0fail":
    guard args.count == 4 else { fail("usage: rpftool prd0fail <rpf> <index>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let starts = MapData.prd0Starts(idx)
    let lock = NSLock()
    var kinds: [String: (Int, UInt64)] = [:]
    DispatchQueue.concurrentPerform(iterations: starts.count) { i in
        var k: String
        if let r = try? idx.resource(at: starts[i], from: f, physical: false) {
            let b = r.virtual
            let ver = b.count > 0x14 ? String(format: "%02x", b[0x14]) : "?"
            if let p = try? PRD0(b) {
                let named = p.blocks.filter { p.structs[$0.type] != nil }.count
                k = "ok ver \(ver) structBlocks \(min(named, 3)) blocks \(min(p.blocks.count, 3))"
            } else {
                let w = (0x20..<0x50).map { String(format: "%02x", b.count > $0 ? b[$0] : 0) }.joined()
                k = "fail ver \(ver) " + String(w.prefix(20))
            }
        } else { k = "unreadable" }
        lock.lock()
        kinds[k] = ((kinds[k]?.0 ?? 0) + 1, kinds[k]?.1 ?? starts[i])
        lock.unlock()
    }
    for (k, v) in kinds.sorted(by: { $0.value.0 > $1.value.0 }).prefix(25) { print(String(format: "%8d  ex 0x%llx  %@", v.0, v.1, k as NSString)) }
case "hashrefs":
    guard args.count >= 5 else { fail("usage: rpftool hashrefs <rpf> <index> <hex32>...") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let needles = Set(args[4...].compactMap { UInt32($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: 16) })
    let starts = MapData.prd0Starts(idx)
    let lock = NSLock()
    var groups: [String: (count: Int, example: String)] = [:]
    DispatchQueue.concurrentPerform(iterations: starts.count) { i in
        guard let r = try? idx.resource(at: starts[i], from: f, physical: false), let p = try? PRD0(r.virtual) else { return }
        var local: [String: (Int, String)] = [:]
        for blk in p.blocks {
            let s = p.structs[blk.type]
            let size = s?.size ?? 0
            var o = blk.offset
            let end = min(blk.offset + blk.size, p.b.count)
            while o + 4 <= end {
                if needles.contains(p.u32(o)) {
                    let rel = o - blk.offset
                    let inst = size > 0 ? rel / size : 0
                    let within = size > 0 ? rel % size : rel
                    let m = s?.members.first { $0.offset == within && $0.name != 0x100 }
                    let key = String(format: "struct %08x size %d member %@ @0x%x", blk.type, size, m.map { String(format: "%08x type %x", $0.name, $0.type) } ?? "?", within)
                    if local[key] == nil {
                        var ex = String(format: "res 0x%llx ", starts[i])
                        if let s = s, size > 0 {
                            let base = blk.offset + inst * size
                            ex += s.members.filter { $0.name != 0x100 }.map { mm -> String in
                                let v = base + mm.offset + 4 <= p.b.count ? p.u32(base + mm.offset) : 0
                                return String(format: "%08x@%x:%x=%08x", mm.name, mm.offset, mm.type, v)
                            }.joined(separator: " ")
                        }
                        local[key] = (0, ex)
                    }
                    local[key]!.0 += 1
                }
                o += 4
            }
        }
        lock.lock()
        for (k, v) in local { groups[k] = ((groups[k]?.count ?? 0) + v.0, groups[k]?.example ?? v.1) }
        lock.unlock()
    }
    for (k, v) in groups.sorted(by: { $0.value.count > $1.value.count }).prefix(30) {
        print("\(v.count)x \(k)\n    \(v.example)")
    }
case "navdiag":
    guard args.count >= 4, let px = Float(args[2]), let py = Float(args[3]) else { fail("usage: rpftool navdiag <x> <y> [reach]") }
    let reach = args.count > 4 ? Float(args[4]) ?? 150 : 150
    let home = NSHomeDirectory()
    let navFile = try MappedFile(path: "\(home)/testing/navmeshes.rpf")
    let navIndex = try ArchiveIndex.read(from: "\(home)/testing/6stars-data/navmeshes.idx")
    let refs = try NavMesh.readIndex(from: "\(home)/testing/6stars-data/navtiles.bin")
    let lf = try MappedFile(path: "\(home)/testing/levels.rpf")
    let li = try ArchiveIndex.read(from: "\(home)/testing/6stars-data/levels.idx")
    guard let hf = HeightField.load(index: li, file: lf) else { fail("no heightfield") }
    print("heightfield cell \(hf.cell) m, \(hf.width)x\(hf.height)")
    var areas = Set<UInt32>()
    var yy = py - reach
    while yy <= py + reach + NavMesh.tileSize {
        var xx = px - reach
        while xx <= px + reach + NavMesh.tileSize {
            if let a = NavMesh.area(at: SIMD2(min(xx, px + reach), min(yy, py + reach))) { areas.insert(a) }
            xx += NavMesh.tileSize
        }
        yy += NavMesh.tileSize
    }
    let names = ["ground", "pavement", "road", "water"]
    let edges: [Float] = [-30, -6, -2, 2, 6, 12, 30]
    func bucket(_ d: Float) -> Int { edges.firstIndex { d < $0 } ?? edges.count }
    var total = [Int](repeating: 0, count: 4), removed = [Int](repeating: 0, count: 4), noGround = [Int](repeating: 0, count: 4)
    var hist = [[Int]](repeating: [Int](repeating: 0, count: edges.count + 1), count: 4)
    var remRoof = 0, remStreet = 0, tiny = [Int](repeating: 0, count: 4)
    var overlapRoad = 0
    for r in refs where areas.contains(r.area) {
        guard let res = try? navIndex.resource(at: r.offset, from: navFile, physical: false),
              let m = try? NavMesh.decode(res, area: r.area, ocean: r.isOcean) else { print("area \(r.area) decode failed"); continue }
        print("area \(r.area) flags \(r.contentFlags) ocean \(r.isOcean) tris \(m.surfaces.count)")
        for t in m.surfaces.indices {
            let a = m.positions[3 * t], b = m.positions[3 * t + 1], c = m.positions[3 * t + 2]
            let cen = (a + b + c) / 3 + m.origin
            guard simd_distance(cen, SIMD2(px, py)) <= reach else { continue }
            let s = Int(m.surfaces[t].rawValue)
            total[s] += 1
            let e1 = b - a, e2 = c - a
            if abs(e1.x * e2.y - e1.y * e2.x) * 0.5 < 1 { tiny[s] += 1 }
            guard let g = hf.groundHeight(at: cen) else { noGround[s] += 1; continue }
            let d = m.heights[t] - g
            hist[s][bucket(d)] += 1
            if s != 2 && d > 6 {
                removed[s] += 1
                if let top = hf.surfaceHeight(at: cen), abs(top - m.heights[t]) < 4 { remRoof += 1 } else { remStreet += 1 }
            }
            if s == 2 && d > 6 { overlapRoad += 1 }
        }
    }
    print("height above heightfield ground buckets: <-30 | -30..-6 | -6..-2 | -2..2 | 2..6 | 6..12 | 12..30 | >30")
    for s in 0..<4 where total[s] > 0 {
        print("\(names[s]): \(total[s]) tris, \(tiny[s]) under 1 m², \(noGround[s]) without ground, removed \(removed[s])  \(hist[s])")
    }
    print("removed tris near heightfield top surface (real roofs): \(remRoof), elsewhere: \(remStreet); road tris > 6 m above ground kept: \(overlapRoad)")
    var cells: [String] = []
    for dy in stride(from: -2, through: 2, by: 1) {
        var row: [String] = []
        for dx in stride(from: -2, through: 2, by: 1) {
            let q = SIMD2(px + Float(dx) * hf.cell, py + Float(dy) * hf.cell)
            row.append(String(format: "%6.1f/%6.1f", hf.groundHeight(at: q) ?? .nan, hf.surfaceHeight(at: q) ?? .nan))
        }
        cells.append(row.joined(separator: " "))
    }
    print("ground/surface around point:")
    cells.forEach { print("  " + $0) }
case "navraster":
    guard args.count >= 6, let px = Float(args[2]), let py = Float(args[3]), let reach = Float(args[4]) else { fail("usage: rpftool navraster <x> <y> <reach> <out.ppm> [debug]") }
    let debug = args.count > 6
    let heightMode = args.count > 6 && args[6] == "height"
    let bitMode = args.count > 8 && args[6] == "bit" ? (Int(args[7]) ?? 0, Int(args[8]) ?? 0) : nil
    let home = NSHomeDirectory()
    let navFile = try MappedFile(path: "\(home)/testing/navmeshes.rpf")
    let navIndex = try ArchiveIndex.read(from: "\(home)/testing/6stars-data/navmeshes.idx")
    let refs = try NavMesh.readIndex(from: "\(home)/testing/6stars-data/navtiles.bin")
    let lf = try MappedFile(path: "\(home)/testing/levels.rpf")
    let li = try ArchiveIndex.read(from: "\(home)/testing/6stars-data/levels.idx")
    guard let hf = HeightField.load(index: li, file: lf) else { fail("no heightfield") }
    let res: Float = 0.5
    let n = Int(2 * reach / res)
    var img = [UInt8](repeating: 30, count: n * n * 3)
    var areas = Set<UInt32>()
    var yy = py - reach
    while yy <= py + reach + NavMesh.tileSize {
        var xx = px - reach
        while xx <= px + reach + NavMesh.tileSize {
            if let a = NavMesh.area(at: SIMD2(min(xx, px + reach), min(yy, py + reach))) { areas.insert(a) }
            xx += NavMesh.tileSize
        }
        yy += NavMesh.tileSize
    }
    let colours: [[UInt8]] = [[89, 94, 97], [128, 133, 135], [204, 207, 209], [61, 87, 110]]
    func fill(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ col: [UInt8]) {
        func pix(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2((p.x - (px - reach)) / res, (py + reach - p.y) / res) }
        let A = pix(a), B = pix(b), C = pix(c)
        let x0 = max(0, Int(min(A.x, B.x, C.x))), x1 = min(n - 1, Int(max(A.x, B.x, C.x)))
        let y0 = max(0, Int(min(A.y, B.y, C.y))), y1 = min(n - 1, Int(max(A.y, B.y, C.y)))
        guard x0 <= x1, y0 <= y1 else { return }
        let area = (B.x - A.x) * (C.y - A.y) - (B.y - A.y) * (C.x - A.x)
        guard abs(area) > 1e-6 else { return }
        for y in y0...y1 {
            for x in x0...x1 {
                let P = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                let w0 = (B.x - P.x) * (C.y - P.y) - (B.y - P.y) * (C.x - P.x)
                let w1 = (C.x - P.x) * (A.y - P.y) - (C.y - P.y) * (A.x - P.x)
                let w2 = (A.x - P.x) * (B.y - P.y) - (A.y - P.y) * (B.x - P.x)
                if (w0 >= 0 && w1 >= 0 && w2 >= 0) || (w0 <= 0 && w1 <= 0 && w2 <= 0) {
                    let o = (y * n + x) * 3
                    img[o] = col[0]; img[o + 1] = col[1]; img[o + 2] = col[2]
                }
            }
        }
    }
    var zBase: Float = .greatestFiniteMagnitude
    for r in refs where areas.contains(r.area) {
        guard let rs = try? navIndex.resource(at: r.offset, from: navFile, physical: false),
              let m = try? NavMesh.decode(rs, area: r.area, ocean: r.isOcean) else { continue }
        for t in m.surfaces.indices where m.surfaces[t] == .road { zBase = min(zBase, m.heights[t]) }
    }
    if heightMode {
        for y in 0..<n {
            for x in 0..<n {
                let q = SIMD2(px - reach + (Float(x) + 0.5) * res, py + reach - (Float(y) + 0.5) * res)
                let top = hf.surfaceHeight(at: q) ?? zBase
                let k = UInt8(max(0, min(1, (top - zBase) / 30)) * 120)
                let o = (y * n + x) * 3
                img[o] = k; img[o + 1] = k; img[o + 2] = k
            }
        }
    }
    print("lowest road z \(zBase)")
    var meshes: [(NavTileMesh, [NavLevel])] = []
    var levelTime: Double = 0
    for r in refs where areas.contains(r.area) {
        guard let rs = try? navIndex.resource(at: r.offset, from: navFile, physical: false),
              let m = try? NavMesh.decode(rs, area: r.area, ocean: r.isOcean, keepWords: bitMode != nil) else { continue }
        let t0 = Date()
        let lv = NavMesh.levels(m)
        levelTime += Date().timeIntervalSince(t0)
        meshes.append((m, lv))
    }
    print(String(format: "levels for %d tiles: %.1f ms", meshes.count, levelTime * 1000))
    for pass in [NavLevel.hidden, .street, .raised, .overpass] {
        for (m, lv) in meshes {
        for t in m.surfaces.indices where lv[t] == pass {
            let a = m.positions[3 * t] + m.origin, b = m.positions[3 * t + 1] + m.origin, c = m.positions[3 * t + 2] + m.origin
            let s = m.surfaces[t]
            var col = colours[Int(s.rawValue)]
            if lv[t] == .hidden {
                if !debug { continue }
                col = [170, 40, 40]
            }
            if lv[t] == .overpass { col = debug ? [60, 160, 230] : colours[2] }
            if lv[t] == .raised, debug { col = [230, 170, 50] }
            if let (w, b) = bitMode {
                col = colours[Int(s.rawValue)]
                if lv[t] == .hidden { continue }
                if s == .ground, m.words[t][w] & (1 << UInt32(b)) != 0 { col = [110, 150, 90] }
            }
            if heightMode {
                let k = max(0, min(1, (m.heights[t] - zBase) / 30))
                col = [UInt8(40 + 215 * k), UInt8(200 - 160 * abs(k - 0.5) * 2), UInt8(255 - 215 * k)]
                if s == .road { col = [255, 255, 255] }
            }
            fill(a, b, c, col)
        }
        }
    }
    var out = Data("P6\n\(n) \(n)\n255\n".utf8)
    out.append(contentsOf: img)
    try out.write(to: URL(fileURLWithPath: args[5]))
    print("wrote \(args[5]) \(n)x\(n)")
case "rbfgrep":
    guard args.count >= 3 else { fail("usage: rpftool rbfgrep <needle> [node]") }
    let home = NSHomeDirectory()
    let df = try MappedFile(path: "\(home)/testing/data.rpf")
    let di = try ArchiveIndex.read(from: "\(home)/testing/6stars-data/data.idx")
    let needle = Array(args[2].utf8)
    func joined(_ i: Int) -> [UInt8]? {
        let entries = di.entries
        guard var bytes = try? di.load(entries[i], from: df) else { return nil }
        var k = i + 1, last = bytes.count
        while last == 0x10000, k < entries.count, entries[k].kind == .zlib, let more = try? di.load(entries[k], from: df) {
            bytes += more
            last = more.count
            k += 1
        }
        return bytes
    }
    func has(_ b: [UInt8]) -> Bool {
        guard needle.count <= b.count else { return false }
        for i in 0...(b.count - needle.count) where b[i] == needle[0] && Array(b[i..<(i + needle.count)]) == needle { return true }
        return false
    }
    func describe(_ v: RBFValue?) -> String {
        switch v {
        case .int(let x)?: return "\(x)"
        case .bool(let x)?: return "\(x)"
        case .double(let x)?: return String(format: "%g", x)
        case .vector(let x)?: return String(format: "(%g, %g, %g)", x.x, x.y, x.z)
        case .string(let x)?: return x
        case nil: return ""
        }
    }
    func dump(_ n: RBFNode, _ depth: Int) {
        guard depth < 14 else { return }
        let attrs = n.attributes.map { "\($0.key)=\(describe($0.value))" }.sorted().joined(separator: " ")
        let val = n.text ?? describe(n.value)
        print(String(repeating: "  ", count: depth) + n.name + (attrs.isEmpty ? "" : " [\(attrs)]") + (val.isEmpty ? "" : " = \(val)"))
        n.children.forEach { dump($0, depth + 1) }
    }
    for (i, e) in di.entries.enumerated() where e.kind == .zlib && e.magic == "RBF0" {
        guard let b = joined(i), has(b), let r = try? RBF.parse(b) else { continue }
        print(String(format: "entry %d offset 0x%llx root %@ name %@ size %d", i, e.offset, r.name, r.string("Name") ?? "-", b.count))
        if args.count > 3, let node = r.find(name: args[3]) { dump(node, 1) }
    }
case "navbits":
    guard args.count >= 4, let px = Float(args[2]), let py = Float(args[3]) else { fail("usage: rpftool navbits <x> <y> [reach]") }
    let reach = args.count > 4 ? Float(args[4]) ?? 150 : 150
    let home = NSHomeDirectory()
    let navFile = try MappedFile(path: "\(home)/testing/navmeshes.rpf")
    let navIndex = try ArchiveIndex.read(from: "\(home)/testing/6stars-data/navmeshes.idx")
    let refs = try NavMesh.readIndex(from: "\(home)/testing/6stars-data/navtiles.bin")
    let lf = try MappedFile(path: "\(home)/testing/levels.rpf")
    let li = try ArchiveIndex.read(from: "\(home)/testing/6stars-data/levels.idx")
    guard let hf = HeightField.load(index: li, file: lf) else { fail("no heightfield") }
    var counts = [[[Int]]](repeating: [[Int]](repeating: [Int](repeating: 0, count: 32), count: 11), count: 2)
    var totals = [0, 0]
    var heightsSeen: [Int: Int] = [:]
    for r in refs where !r.isOcean {
        let o = NavMesh.origin(area: r.area)
        guard o.x + NavMesh.tileSize >= px - reach, o.x <= px + reach, o.y + NavMesh.tileSize >= py - reach, o.y <= py + reach,
              let rs = try? navIndex.resource(at: r.offset, from: navFile, physical: false),
              let m = try? NavMesh.decode(rs, area: r.area, ocean: false, keepWords: true) else { continue }
        for t in m.surfaces.indices {
            let cen = (m.positions[3 * t] + m.positions[3 * t + 1] + m.positions[3 * t + 2]) / 3 + m.origin
            guard simd_distance(cen, SIMD2(px, py)) <= reach else { continue }
            let bed = hf.groundHeight(at: cen) ?? -100
            let group: Int
            if bed < -4 && abs(m.heights[t]) < 1.5 { group = 0 } else if bed > -1 && m.heights[t] > 1.5 { group = 1 } else { continue }
            if group == 0 { heightsSeen[Int(m.heights[t].rounded()), default: 0] += 1 }
            totals[group] += 1
            for w in 0..<11 { for b in 0..<32 where m.words[t][w] & (1 << UInt32(b)) != 0 { counts[group][w][b] += 1 } }
        }
    }
    print("water-surface tris \(totals[0]) (z histogram \(heightsSeen.sorted { $0.key < $1.key })), land tris \(totals[1])")
    for w in 0..<11 {
        for b in 0..<32 {
            let fw = totals[0] > 0 ? Double(counts[0][w][b]) / Double(totals[0]) : 0
            let fl = totals[1] > 0 ? Double(counts[1][w][b]) / Double(totals[1]) : 0
            if abs(fw - fl) > 0.5 { print(String(format: "word %d (+%d) bit %2d  water %.2f  land %.2f", w, 4 * w, b, fw, fl)) }
        }
    }
case "batchnames":
    let home = NSHomeDirectory()
    let wd = try WorldData.read(from: "\(home)/testing/6stars-data/world-v6.bin")
    let cat = try Catalog.read(from: "\(home)/testing/6stars-data/catalog.bin")
    var counts: [UInt32: Int] = [:]
    for e in wd.entities where e.hasBasis && e.archetype != 0 { counts[e.archetype, default: 0] += 1 }
    let filter = args.count > 2 ? args[2].lowercased() : ""
    var shown = 0
    for (h, n) in counts.sorted(by: { $0.value > $1.value }) {
        let name = cat.byHash[h].map { cat.entries[$0].name } ?? String(format: "%08x", h)
        guard filter.isEmpty || name.lowercased().contains(filter) else { continue }
        print(String(format: "%9d  %@", n, name))
        shown += 1
        if shown >= 60 { break }
    }
    print("\(counts.count) batch archetypes, \(counts.values.reduce(0, +)) instances")
case "navveg":
    guard args.count >= 4, let px = Float(args[2]), let py = Float(args[3]) else { fail("usage: rpftool navveg <x> <y> [reach]") }
    let reach = args.count > 4 ? Float(args[4]) ?? 300 : 300
    let home = NSHomeDirectory()
    let wd = try WorldData.read(from: "\(home)/testing/6stars-data/world-v6.bin")
    let cat = try Catalog.read(from: "\(home)/testing/6stars-data/catalog.bin")
    let cell: Float = 2.5
    var veg = Set<Int64>()
    func key(_ x: Float, _ y: Float) -> Int64 { Int64(floor(x / cell)) << 32 | Int64(UInt32(bitPattern: Int32(floor(y / cell)))) }
    var vegNames: [UInt32: Bool] = [:]
    for e in wd.entities where e.hasBasis && e.archetype != 0 && abs(e.position.x - px) < reach + 30 && abs(e.position.y - py) < reach + 30 {
        let isVeg = vegNames[e.archetype] ?? {
            let n = cat.byHash[e.archetype].map { cat.entries[$0].name.lowercased() } ?? ""
            let v = (n.hasPrefix("veg_tree") || n.hasPrefix("veg_bush") || n.hasPrefix("veg_palm") || n.hasPrefix("veg_grass")) && !n.contains("imposter")
            vegNames[e.archetype] = v
            return v
        }()
        if isVeg { veg.insert(key(e.position.x, e.position.y)) }
    }
    func near(_ p: SIMD2<Float>, _ r: Int) -> Bool {
        let cx = Int64(floor(p.x / cell)), cy = Int64(floor(p.y / cell))
        for dy in -r...r { for dx in -r...r where veg.contains((cx + Int64(dx)) << 32 | Int64(UInt32(bitPattern: Int32(cy + Int64(dy))))) { return true } }
        return false
    }
    let navFile = try MappedFile(path: "\(home)/testing/navmeshes.rpf")
    let navIndex = try ArchiveIndex.read(from: "\(home)/testing/6stars-data/navmeshes.idx")
    let refs = try NavMesh.readIndex(from: "\(home)/testing/6stars-data/navtiles.bin")
    var counts = [[[Int]]](repeating: [[Int]](repeating: [Int](repeating: 0, count: 32), count: 11), count: 2)
    var totals = [0, 0]
    for r in refs where !r.isOcean {
        let o = NavMesh.origin(area: r.area)
        guard o.x + NavMesh.tileSize >= px - reach, o.x <= px + reach, o.y + NavMesh.tileSize >= py - reach, o.y <= py + reach,
              let rs = try? navIndex.resource(at: r.offset, from: navFile, physical: false),
              let m = try? NavMesh.decode(rs, area: r.area, ocean: false, keepWords: true) else { continue }
        for t in m.surfaces.indices where m.surfaces[t] == .ground {
            let cen = (m.positions[3 * t] + m.positions[3 * t + 1] + m.positions[3 * t + 2]) / 3 + m.origin
            let group: Int
            if near(cen, 0) { group = 0 } else if !near(cen, 8) { group = 1 } else { continue }
            totals[group] += 1
            for w in 0..<11 { for b in 0..<32 where m.words[t][w] & (1 << UInt32(b)) != 0 { counts[group][w][b] += 1 } }
        }
    }
    print("veg cells \(veg.count), ground tris under vegetation \(totals[0]), far from vegetation \(totals[1])")
    for w in 5..<11 {
        for b in 0..<32 {
            let fa = totals[0] > 0 ? Double(counts[0][w][b]) / Double(totals[0]) : 0
            let fb = totals[1] > 0 ? Double(counts[1][w][b]) / Double(totals[1]) : 0
            if abs(fa - fb) > 0.2 { print(String(format: "word %d (+%d) bit %2d  vegetated %.2f  bare %.2f", w, 4 * w, b, fa, fb)) }
        }
    }
case "findtex":
    guard args.count >= 3 else { fail("usage: rpftool findtex <name>") }
    let home = NSHomeDirectory()
    let texFile = try MappedFile(path: "\(home)/testing/textures.rpf")
    let texIndex = try ArchiveIndex.read(from: "\(home)/testing/6stars-data/textures.idx")
    let want = Hash.joaat(args[2])
    for off in texIndex.resourceStarts {
        guard let seg = try? texIndex.virtualSegment(at: off, from: texFile), let ha = Resource.vptr(seg.data, 0x20), seg.data.count > 0x2A else { continue }
        let n = Int(UInt16(seg.data[0x28]) | UInt16(seg.data[0x29]) << 8)
        guard n > 0, ha + 4 * n <= seg.data.count else { continue }
        let has = seg.data.withUnsafeBytes { p in (0..<n).contains { p.loadUnaligned(fromByteOffset: ha + 4 * $0, as: UInt32.self) == want } }
        if has { print(String(format: "txd at 0x%llx with %d textures", off, n)) }
    }
case "lutscan":
    let home = NSHomeDirectory()
    let db = TextureDB(roots: ["\(home)/testing/data/ttdb", "\(home)/testing/pack"], aliasArchive: ("\(home)/testing/textures.rpf", "\(home)/testing/6stars-data/textures.idx"))
    var hits: [String] = []
    for (fi, tf) in db.files.enumerated() {
        for i in 0..<tf.count {
            let inf = tf.info(i)
            let strip = (inf.width == inf.height * inf.height && inf.height >= 16 && inf.height <= 64) || (inf.height == inf.width * inf.width && inf.width >= 16 && inf.width <= 64)
            let tiled = inf.width == inf.height && (inf.width == 512 || inf.width == 256 || inf.width == 4096) && !inf.blockCompressed
            if strip || tiled {
                hits.append(String(format: "file %d tex %016llx %dx%d dxgi %d flags %04x %@", fi, tf.hashes[i], inf.width, inf.height, inf.format, inf.flags, tf.rawDescriptor(i)))
            }
        }
    }
    print("\(hits.count) candidates")
    for h in hits.prefix(200) { print(h) }
case "vegdump":
    guard args.count >= 5 else { fail("usage: rpftool vegdump <rpf> <index> <archname> [max]") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let want = Hash.joaat(args[4])
    let maxOut = args.count > 5 ? Int(args[5]) ?? 2 : 2
    let starts = MapData.prd0Starts(idx)
    let lock = NSLock()
    var hits: [(UInt64, String)] = []
    DispatchQueue.concurrentPerform(iterations: starts.count) { i in
        lock.lock(); let done = hits.count >= maxOut; lock.unlock()
        if done { return }
        guard let r = try? idx.resource(at: starts[i], from: f, physical: true), let p = try? PRD0(r.virtual) else { return }
        guard p.block(ofType: MapData.mapStruct) != nil else { return }
        var found: (Int, Int)? = nil
        for (bi, blk) in p.blocks.enumerated() where blk.size > 0 {
            var o = blk.offset
            while o + 4 <= blk.offset + blk.size {
                if p.u32(o) == want { found = (bi, o - blk.offset); break }
                o += 4
            }
            if found != nil { break }
        }
        guard let (fb, fo) = found else { return }
        var out = String(format: "== res %llx: hash in block %d (type %08x size %d) at +0x%x\n", starts[i], fb + 1, p.blocks[fb].type, p.blocks[fb].size, fo)
        for (k, st) in p.structs.sorted(by: { $0.key < $1.key }) {
            out += String(format: "struct %08x size %d: ", k, st.size) + st.members.map { String(format: "%08x@%x:%02x(%08x)", $0.name, $0.offset, $0.type, $0.ref) }.joined(separator: " ") + "\n"
        }
        out += "physical bytes \(r.physical.count)\n"
        if let bl = Resource.vptr(p.b, 0x38) {
            for bi in 0..<p.blocks.count {
                let o = bl + 16 * bi
                let raw = p.u64(o + 8), sz = Int(p.u32(o + 4))
                out += String(format: "block %d type %08x size %d raw %016llx\n", bi + 1, p.u32(o), sz, raw)
                if let pp = Resource.pptr(p.b, o + 8), sz > 0, pp + sz <= r.physical.count {
                    var q = pp
                    while q < min(pp + sz, pp + 0x200) {
                        out += String(format: "  p%05x:", q - pp) + stride(from: q, to: min(q + 32, pp + sz), by: 4).map { k in String(format: " %08x", r.physical.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: k, as: UInt32.self) }) }.joined() + "\n"
                        q += 32
                    }
                }
            }
        }
        let blk = p.blocks[fb]
        let from = max(blk.offset, blk.offset + fo - 0x100), to = min(blk.offset + blk.size, blk.offset + fo + 0x300)
        var o = from
        while o < to {
            out += String(format: "%06x:", o - blk.offset) + stride(from: o, to: min(o + 32, to), by: 4).map { String(format: " %08x", p.u32($0)) }.joined() + "\n"
            o += 32
        }
        lock.lock(); if hits.count < maxOut { hits.append((starts[i], out)) }; lock.unlock()
    }
    for h in hits { print(h.1) }
case "structdump":
    guard args.count == 6, let want = UInt32(args[4].hasPrefix("0x") ? String(args[4].dropFirst(2)) : args[4], radix: 16) else {
        fail("usage: rpftool structdump <rpf> <index> <structhex> <out.tsv>")
    }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let starts = MapData.prd0Starts(idx)
    let lock = NSLock()
    var rows: [String] = []
    var header = ""
    DispatchQueue.concurrentPerform(iterations: starts.count) { i in
        guard let r = try? idx.resource(at: starts[i], from: f, physical: false), let p = try? PRD0(r.virtual), let s = p.structs[want], s.size > 0 else { return }
        let ms = s.members.filter { $0.name != 0x100 }
        var local: [String] = []
        for blk in p.blocks where blk.type == want {
            for k in 0..<(blk.size / s.size) {
                let base = blk.offset + k * s.size
                guard base + s.size <= p.b.count else { break }
                local.append(String(format: "%llx", starts[i]) + "\t" + ms.map { String(format: "%08x", p.u32(base + $0.offset)) }.joined(separator: "\t"))
            }
        }
        lock.lock()
        if header.isEmpty { header = "res\t" + ms.map { String(format: "%08x@%x:%x", $0.name, $0.offset, $0.type) }.joined(separator: "\t") }
        rows += local
        lock.unlock()
    }
    try ([header] + rows).joined(separator: "\n").write(toFile: args[5], atomically: true, encoding: .utf8)
    print("\(rows.count) instances")
case "names":
    guard args.count == 5 else { fail("usage: rpftool names <rpf> <index> <out.tsv>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let starts = idx.resourceStarts
    let lock = NSLock()
    var kinds: [String: (Int, String)] = [:]
    var rows: [String] = []
    func ident(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x2D }
    DispatchQueue.concurrentPerform(iterations: starts.count) { i in
        guard let seg = try? idx.virtualSegment(at: starts[i], from: f) else { return }
        var found: [(String, String, Int)] = []
        seg.data.withUnsafeBytes { p in
            var o = 2
            while o + 4 < p.count {
                if p[o] == 0x2E, p[o + 1] == 0x23, p[o + 4] == 0, p[o + 2] >= 0x61, p[o + 2] <= 0x7A, p[o + 3] >= 0x61, p[o + 3] <= 0x7A {
                    var s = o
                    while s > 0, o - s < 120, ident(p[s - 1]) { s -= 1 }
                    if s < o {
                        let name = String(decoding: UnsafeRawBufferPointer(rebasing: p[s..<o]), as: UTF8.self)
                        let kind = String(decoding: UnsafeRawBufferPointer(rebasing: p[(o + 2)..<(o + 4)]), as: UTF8.self)
                        found.append((kind, name, s))
                    }
                    o += 5
                    continue
                }
                o += 1
            }
        }
        guard !found.isEmpty else { return }
        lock.lock()
        for k in Set(found.map { $0.0 }) {
            let ex = found.first { $0.0 == k }!
            kinds[k] = ((kinds[k]?.0 ?? 0) + 1, kinds[k]?.1 ?? String(format: "res 0x%llx %@ @0x%x", starts[i], ex.1, ex.2))
        }
        for x in found { rows.append(String(format: "%llx\t%@\t%@\t%x\t%08x", starts[i], x.0, x.1, x.2, Hash.joaat(x.1))) }
        lock.unlock()
    }
    try rows.joined(separator: "\n").write(toFile: args[4], atomically: true, encoding: .utf8)
    for (k, v) in kinds.sorted(by: { $0.value.0 > $1.value.0 }) { print("\(k): \(v.0) resources, e.g. \(v.1)") }
case "res":
    guard args.count == 6, let off = parseOffset(args[4]) else { fail("usage: rpftool res <rpf> <index> <offset> <outprefix>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let r = try idx.resource(at: off, from: f, physical: true)
    try Data(r.virtual).write(to: URL(fileURLWithPath: args[5] + ".v"))
    try Data(r.physical).write(to: URL(fileURLWithPath: args[5] + ".p"))
    print(String(format: "virtual 0x%x physical 0x%x", r.virtual.count, r.physical.count))
case "slotstats":
    guard args.count == 6, let n = Int(args[5]) else { fail("usage: rpftool slotstats <rpf> <index> <catalog> <count>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    var g = SystemRandomNumberGenerator()
    let picks = (0..<n).map { _ in cat.entries[Int.random(in: 0..<cat.entries.count, using: &g)] }
    let lock = NSLock()
    var counts: [String: Int] = [:]
    var combos: [String: Int] = [:]
    DispatchQueue.concurrentPerform(iterations: picks.count) { i in
        let e = picks[i]
        guard let r = try? idx.resource(at: e.resource, from: f, physical: true) else { return }
        let layouts = Drawable.slotSurvey(r, at: Int(e.base))
        lock.lock()
        for l in layouts {
            var key: [String] = []
            for (s, w) in l.enumerated() where w != 0 {
                counts[String(format: "slot %2d fmt %02x", s, w & 0xFF), default: 0] += 1
                key.append(String(format: "%d:%02x", s, w & 0xFF))
            }
            combos[key.joined(separator: " "), default: 0] += 1
        }
        lock.unlock()
    }
    for (k, v) in counts.sorted(by: { $0.key < $1.key }) { print(k, v) }
    print("layouts:")
    for (k, v) in combos.sorted(by: { $0.value > $1.value }).prefix(25) { print(String(format: "%7d  ", v) + k) }
case "texparams":
    guard args.count == 6, let n = Int(args[5]) else { fail("usage: rpftool texparams <rpf> <index> <catalog> <count>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    let home = NSHomeDirectory()
    let db = TextureDB(roots: ["\(home)/testing/data/ttdb", "\(home)/testing/pack"], aliasArchive: ("\(home)/testing/textures.rpf", "\(home)/testing/6stars-data/textures.idx"))
    print("\(db.files.count) texture files, \(db.count) textures")
    var g = SystemRandomNumberGenerator()
    let picks = (0..<n).map { _ in cat.entries[Int.random(in: 0..<cat.entries.count, using: &g)] }
    let lock = NSLock()
    struct P { var count = 0; var found = 0; var formats: [Int: Int] = [:]; var slots: [Int: Int] = [:] }
    var params: [UInt32: P] = [:]
    var shaderNames: [UInt32: Int] = [:]
    var refs = 0, found = 0, missingExamples: [String] = []
    DispatchQueue.concurrentPerform(iterations: picks.count) { i in
        let e = picks[i]
        guard let m = try? Drawable.load(idx, f, resource: e.resource, base: Int(e.base)) else { return }
        lock.lock()
        for sh in m.shaders {
            shaderNames[sh.name, default: 0] += 1
            for (k, t) in sh.textures.enumerated() {
                var p = params[t.param] ?? P()
                p.count += 1
                p.slots[k, default: 0] += 1
                refs += 1
                if let (tf, ti) = db.find(t.hash) {
                    p.found += 1
                    found += 1
                    p.formats[tf.info(ti).format, default: 0] += 1
                } else if missingExamples.count < 12 {
                    missingExamples.append(String(format: "%@ shader %08x param %08x tex %016llx", e.name, sh.name, t.param, t.hash))
                }
                params[t.param] = p
            }
        }
        lock.unlock()
    }
    print("texture refs \(refs), found \(found)")
    for (k, p) in params.sorted(by: { $0.value.count > $1.value.count }).prefix(30) {
        let fm = p.formats.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key):\($0.value)" }.joined(separator: " ")
        let sl = p.slots.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key):\($0.value)" }.joined(separator: " ")
        print(String(format: "param %08x  %7d refs  %7d found  slots %@  formats %@", k, p.count, p.found, sl, fm))
    }
    print("shaders: \(shaderNames.count) distinct; top:", shaderNames.sorted { $0.value > $1.value }.prefix(8).map { String(format: "%08x:%d", $0.key, $0.value) }.joined(separator: " "))
    for x in missingExamples { print("missing:", x) }
case "shaderdump":
    guard args.count == 7, let n = Int(args[5]) else { fail("usage: rpftool shaderdump <rpf> <index> <catalog> <count> <out.tsv>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    let home = NSHomeDirectory()
    let db = TextureDB(roots: ["\(home)/testing/data/ttdb", "\(home)/testing/pack"], aliasArchive: ("\(home)/testing/textures.rpf", "\(home)/testing/6stars-data/textures.idx"))
    var g = SystemRandomNumberGenerator()
    let picks = n >= cat.entries.count ? cat.entries : (0..<n).map { _ in cat.entries[Int.random(in: 0..<cat.entries.count, using: &g)] }
    let lock = NSLock()
    struct S { var count = 0; var params: [UInt32] = []; var examples: [String] = []; var found = 0; var refs = 0; var albedoFound = 0; var parts = 0 }
    var shaders: [UInt32: S] = [:]
    DispatchQueue.concurrentPerform(iterations: picks.count) { i in
        let e = picks[i]
        guard let m = try? Drawable.load(idx, f, resource: e.resource, base: Int(e.base)) else { return }
        lock.lock()
        for (si, sh) in m.shaders.enumerated() {
            var s = shaders[sh.name] ?? S()
            s.count += 1
            s.parts += m.parts.filter { $0.shader == si }.count
            if s.params.isEmpty { s.params = sh.textures.map { $0.param } }
            if s.examples.count < 4 { s.examples.append(e.name) }
            for t in sh.textures {
                s.refs += 1
                if db.find(t.hash) != nil { s.found += 1; if t.param == 0xC8E8C282 { s.albedoFound += 1 } }
            }
            shaders[sh.name] = s
        }
        lock.unlock()
    }
    var lines: [String] = []
    for (k, s) in shaders.sorted(by: { $0.value.parts > $1.value.parts }) {
        lines.append(String(format: "%08x\t%d\t%d\t%d\t%d\t%d\t", k, s.count, s.parts, s.refs, s.found, s.albedoFound) + s.params.map { String(format: "%08x", $0) }.joined(separator: ",") + "\t" + s.examples.joined(separator: ","))
    }
    try lines.joined(separator: "\n").write(toFile: args[6], atomically: true, encoding: .utf8)
    print("\(shaders.count) shaders")
case "drawtex":
    guard args.count == 6 else { fail("usage: rpftool drawtex <rpf> <index> <catalog> <name>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    let home = NSHomeDirectory()
    let db = TextureDB(roots: ["\(home)/testing/data/ttdb", "\(home)/testing/pack"], aliasArchive: ("\(home)/testing/textures.rpf", "\(home)/testing/6stars-data/textures.idx"))
    guard let ci = cat.byHash[Hash.joaat(args[5])] else { fail("not in catalog") }
    let e = cat.entries[ci]
    let r = try idx.resource(at: e.resource, from: f, physical: true)
    let m = try Drawable.decode(r, at: Int(e.base))
    print("\(e.name): \(m.positions.count) verts, \(m.parts.count) parts, lod \(m.lod)")
    for (si, sh) in m.shaders.enumerated() {
        print(String(format: "shader %d %08x", si, sh.name))
        for (k, t) in sh.textures.enumerated() {
            var d = "missing"
            if let (tf, ti) = db.find(t.hash) { let inf = tf.info(ti); d = "\(inf.width)x\(inf.height) dxgi \(inf.format)" }
            print(String(format: "   %2d param %08x tex %016llx  ", k, t.param, t.hash) + d)
        }
    }
    let layouts = Drawable.slotSurvey(r, at: Int(e.base))
    for (pi, p) in m.parts.enumerated().prefix(6) {
        let l = pi < layouts.count ? layouts[pi].enumerated().filter { $0.element != 0 }.map { String(format: "%d:%02x", $0.offset, $0.element & 0xFF) }.joined(separator: " ") : ""
        print("part \(pi) shader \(p.shader) tris \(p.indexCount / 3) layout \(l)")
        for slot in [1, 12, 13] {
            let vals = Drawable.rawSlot(r, at: Int(e.base), geometry: pi, slot: slot, count: 4000)
            guard !vals.isEmpty else { continue }
            var mn = [UInt32](repeating: 255, count: 4), mx = [UInt32](repeating: 0, count: 4), sum = [Double](repeating: 0, count: 4)
            for v in vals { for c in 0..<4 { let x = (v >> (8 * UInt32(c))) & 0xFF; mn[c] = min(mn[c], x); mx[c] = max(mx[c], x); sum[c] += Double(x) } }
            print("   slot \(slot) rgba min \(mn) max \(mx) mean \(sum.map { Int($0 / Double(vals.count)) })")
            print("      first:", vals.prefix(12).map { String(format: "%08x", $0) }.joined(separator: " "))
            let sums = vals.map { v in (0..<4).reduce(0) { $0 + Int((v >> (8 * UInt32($1))) & 0xFF) } }
            print("      rgba sums min \(sums.min()!) max \(sums.max()!)  rgb sums max \(vals.map { v in (0..<3).reduce(0) { $0 + Int((v >> (8 * UInt32($1))) & 0xFF) } }.max()!)")
        }
    }
case "texhas":
    let home = NSHomeDirectory()
    let db = TextureDB(roots: ["\(home)/testing/data/ttdb", "\(home)/testing/pack"], aliasArchive: ("\(home)/testing/textures.rpf", "\(home)/testing/6stars-data/textures.idx"))
    var hits = 0
    for a in args[2...] {
        guard let h = UInt64(a, radix: 16) else { continue }
        if db.find(h) != nil { print("found", a); hits += 1 }
    }
    print("\(hits) of \(args.count - 2) candidate hashes present")
case "ttdbcheck":
    let home = NSHomeDirectory()
    let db = TextureDB(roots: ["\(home)/testing/data/ttdb", "\(home)/testing/pack"], aliasArchive: ("\(home)/testing/textures.rpf", "\(home)/testing/6stars-data/textures.idx"))
    let decode = args.count > 2 && args[2] == "decode"
    var match = 0, mismatch: [String: Int] = [:], inside = 0, examples: [String] = []
    let lock = NSLock()
    var full = 0, partial = 0, none = 0, unsupported: [Int: Int] = [:]
    for f in db.files {
        for i in 0..<f.count {
            let inf = f.info(i)
            if inf.elementBytes == nil { unsupported[inf.format, default: 0] += 1; continue }
            let (lt, ct) = f.check(i)
            if let ct = ct {
                if lt == ct { match += 1 } else {
                    mismatch["dxgi \(inf.format) split \(inf.split)", default: 0] += 1
                    if examples.count < 30 && (inf.blockCompressed || examples.count < 3) { examples.append(String(format: "%@ #%d %dx%d dxgi %d split %d flags %04x mips %d layout 0x%x chunks 0x%x raw %@", (f.path as NSString).lastPathComponent, i, inf.width, inf.height, inf.format, inf.split, inf.flags, inf.mipCount, lt, ct, f.rawDescriptor(i))) }
                }
            } else { inside += 1 }
        }
        if decode {
            DispatchQueue.concurrentPerform(iterations: f.count) { i in
                let (l, t) = f.decodable(i)
                lock.lock()
                if l == 0 { none += 1 } else if l == t { full += 1 } else { partial += 1 }
                lock.unlock()
            }
        }
    }
    print("layout total matches chunks: \(match), mismatches: \(mismatch.values.reduce(0, +)), starts inside a chunk: \(inside)")
    for (k, v) in mismatch.sorted(by: { $0.value > $1.value }).prefix(10) { print("  \(v)x \(k)") }
    for e in examples { print("  " + e) }
    print("unsupported formats:", unsupported.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
    if decode { print("decode: \(full) complete, \(partial) missing their largest mips (unknown codec), \(none) nothing decodable") }
case "pagehdr":
    guard args.count >= 6 else { fail("usage: rpftool pagehdr <rpf> <index> <catalog> <count> [uvfmt]") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    let want = Int(args[5]) ?? 10
    let fmtWant = args.count > 6 ? UInt32(args[6], radix: 16)! : 0x28
    var shown = 0
    var rng = SystemRandomNumberGenerator()
    let named = Int(args[5]) == nil ? cat.byHash[Hash.joaat(args[5])] : nil
    while shown < want {
        let e = cat.entries[named ?? Int.random(in: 0..<cat.entries.count, using: &rng)]
        guard let r = try? idx.resource(at: e.resource, from: f, physical: true) else { continue }
        if named != nil { shown = want }
        for h in Drawable.pageHeaders(r, at: Int(e.base)) where named != nil || h.slots[3] & 0xFF == fmtWant {
            print(e.name, "slots", h.slots.enumerated().filter { $0.element != 0 }.map { String(format: "%d:%x/%02x", $0.offset, $0.element >> 8, $0.element & 0xFF) }.joined(separator: " "))
            print("   hdr u32", h.header.map { String(format: "%08x", $0) }.joined(separator: " "))
            print("   hdr f32", h.header.map { String(format: "%.4g", Float(bitPattern: $0)) }.joined(separator: " "))
            let us = h.uvRaw.map { Float($0 & 0xFFFF) / 65535 }, vs = h.uvRaw.map { Float($0 >> 16) / 65535 }
            print(String(format: "   uv raw u %.3f..%.3f v %.3f..%.3f", us.min() ?? 0, us.max() ?? 0, vs.min() ?? 0, vs.max() ?? 0))
            shown += 1
            break
        }
    }
case "vtxtest":
    guard args.count >= 6 else { fail("usage: rpftool vtxtest <rpf> <index> <catalog> <count>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    let want = Int(args[5]) ?? 100
    var range: [UInt32: Int] = [:], fmts: [String: Int] = [:]
    func sx(_ v: UInt32, _ bits: Int) -> Float { let m = UInt32(1) << UInt32(bits - 1); let x = Int32(bitPattern: (v & ((m << 1) - 1)) ^ m) - Int32(m); return max(-1, Float(x) / Float(m - 1)) }
    func oct(_ a: Float, _ b: Float) -> SIMD3<Float> {
        var n = SIMD3(a, b, 1 - abs(a) - abs(b))
        if n.z < 0 { n = SIMD3((1 - abs(b)) * (a >= 0 ? 1 : -1), (1 - abs(a)) * (b >= 0 ? 1 : -1), n.z) }
        return simd_normalize(n)
    }
    let cands: [(String, (UInt32) -> SIMD3<Float>)] = [
        ("snorm10", { v in SIMD3(sx(v, 10), sx(v >> 10, 10), sx(v >> 20, 10)) }),
        ("unorm10", { v in SIMD3(Float(v & 1023), Float((v >> 10) & 1023), Float((v >> 20) & 1023)) / 511.5 - 1 }),
        ("snorm8", { v in SIMD3(sx(v, 8), sx(v >> 8, 8), sx(v >> 16, 8)) }),
        ("unorm8", { v in SIMD3(Float(v & 255), Float((v >> 8) & 255), Float((v >> 16) & 255)) / 127.5 - 1 }),
        ("oct_s16", { v in oct(sx(v, 16), sx(v >> 16, 16)) }),
        ("oct_u16", { v in oct(Float(v & 0xFFFF) / 32767.5 - 1, Float(v >> 16) / 32767.5 - 1) }),
        ("snorm11_11_10", { v in SIMD3(sx(v, 11), sx(v >> 11, 11), sx(v >> 22, 10)) }),
        ("unorm11_11_10", { v in SIMD3(Float(v & 2047) / 1023.5 - 1, Float((v >> 11) & 2047) / 1023.5 - 1, Float(v >> 22) / 511.5 - 1) }),
    ]
    var score: [String: [String: (Double, Int)]] = [:]
    var done = 0
    var rng = SystemRandomNumberGenerator()
    while done < want {
        let e = cat.entries[Int.random(in: 0..<cat.entries.count, using: &rng)]
        guard let r = try? idx.resource(at: e.resource, from: f, physical: true), let m = try? Drawable.decode(r, at: Int(e.base)), m.failedGeometries == 0 else { continue }
        done += 1
        let hdrs = Drawable.pageHeaders(r, at: Int(e.base))
        for (k, part) in m.parts.enumerated() where k < hdrs.count {
            range[hdrs[k].header[15], default: 0] += 1
            let lo = Int(m.indices[part.indexStart..<part.indexStart + part.indexCount].min()!)
            for slot in [2, 11] {
                let fmt = hdrs[k].slots[slot] & 0xFF
                guard fmt != 0 else { continue }
                fmts["slot\(slot):\(String(fmt, radix: 16))", default: 0] += 1
                guard fmt >> 4 == 2 else { continue }
                let raw = Drawable.rawSlot(r, at: Int(e.base), geometry: k, slot: slot, count: 100000)
                for (name, fn) in cands {
                    var s = 0.0, n = 0
                    for (i, w) in raw.enumerated() where lo + i < m.normals.count {
                        let c = fn(w)
                        let l = simd_length(c)
                        guard l > 0.01 else { continue }
                        s += Double(abs(simd_dot(c / l, m.normals[lo + i])))
                        n += 1
                    }
                    let key = "slot\(slot) fmt \(String(fmt, radix: 16))"
                    let old = score[key]?[name] ?? (0, 0)
                    score[key, default: [:]][name] = (old.0 + s, old.1 + n)
                }
            }
        }
    }
    print("uv range word:", range.sorted { $0.value > $1.value }.prefix(8).map { String(format: "%08x(%g)=%d", $0.key, Float(bitPattern: $0.key), $0.value) })
    print("formats:", fmts.sorted { $0.value > $1.value })
    for (k, v) in score.sorted(by: { $0.key < $1.key }) {
        print(k, v.sorted { $0.value.0 / Double(max($0.value.1, 1)) > $1.value.0 / Double(max($1.value.1, 1)) }.map { String(format: "%@ %.3f", $0.key, $0.value.0 / Double(max($0.value.1, 1))) }.joined(separator: "  "))
    }
case "flatnorm":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    let want = Int(args[5]) ?? 20
    var shown = 0
    var rng = SystemRandomNumberGenerator()
    while shown < want {
        let e = cat.entries[Int.random(in: 0..<cat.entries.count, using: &rng)]
        guard let r = try? idx.resource(at: e.resource, from: f, physical: true), let m = try? Drawable.decode(r, at: Int(e.base)), m.failedGeometries == 0 else { continue }
        let hdrs = Drawable.pageHeaders(r, at: Int(e.base))
        for (k, part) in m.parts.enumerated() where k < hdrs.count {
            let ids = m.indices[part.indexStart..<part.indexStart + part.indexCount]
            let lo = Int(ids.min()!), hi = Int(ids.max()!)
            guard hi - lo >= 3, hi - lo < 400 else { continue }
            let n0 = m.normals[lo]
            guard (lo...hi).allSatisfy({ simd_dot(m.normals[$0], n0) > 0.999 }) else { continue }
            for slot in [2, 11] {
                let fmt = hdrs[k].slots[slot] & 0xFF
                guard fmt != 0 else { continue }
                let raw = Drawable.rawSlot(r, at: Int(e.base), geometry: k, slot: slot, count: 6)
                print(String(format: "%@ slot %d fmt %02x n (%.3f %.3f %.3f) k=%d raw ", e.name, slot, fmt, n0.x, n0.y, n0.z, Int32(bitPattern: hdrs[k].header[11])) + raw.map { String(format: "%08x", $0) }.joined(separator: " "))
            }
            shown += 1
            break
        }
    }
case "normpairs":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    let want = Int(args[5]) ?? 200
    var out = Data()
    var done = 0
    var rng = SystemRandomNumberGenerator()
    while done < want {
        let e = cat.entries[Int.random(in: 0..<cat.entries.count, using: &rng)]
        guard let r = try? idx.resource(at: e.resource, from: f, physical: true), let m = try? Drawable.decode(r, at: Int(e.base)), m.failedGeometries == 0 else { continue }
        done += 1
        let hdrs = Drawable.pageHeaders(r, at: Int(e.base))
        for (k, part) in m.parts.enumerated() where k < hdrs.count {
            let ids = m.indices[part.indexStart..<part.indexStart + part.indexCount]
            let lo = Int(ids.min()!)
            let fmt2 = hdrs[k].slots[2] & 0xFF, fmt11 = hdrs[k].slots[11] & 0xFF
            guard fmt2 == 0x21 else { continue }
            let raw = Drawable.rawSlot(r, at: Int(e.base), geometry: k, slot: 2, count: 100000)
            let tan = fmt11 == 0x27 ? Drawable.rawSlot(r, at: Int(e.base), geometry: k, slot: 11, count: 100000) : []
            let kk = Int32(bitPattern: hdrs[k].header[11])
            for (i, w) in raw.enumerated() where lo + i < m.normals.count {
                let n = m.normals[lo + i]
                withUnsafeBytes(of: w) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: i < tan.count ? tan[i] : 0) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: kk) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: n.x) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: n.y) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: n.z) { out.append(contentsOf: $0) }
            }
        }
    }
    try out.write(to: URL(fileURLWithPath: args[6]))
    print("wrote \(out.count / 24) pairs")
case "vcstats":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    let want = Int(args[5]) ?? 500
    var names: [UInt32: String] = [:]
    if let t = try? String(contentsOfFile: args[6], encoding: .utf8) {
        for l in t.split(separator: "\n") { let c = l.split(separator: "\t"); if c.count >= 3, let h = UInt32(c[0], radix: 16) { names[h] = String(c[2]) } }
    }
    struct Acc { var n = 0; var parts = 0; var sum = [Double](repeating: 0, count: 4); var mn = [Int](repeating: 255, count: 4); var mx = [Int](repeating: 0, count: 4); var rgb255 = 0; var rgba255 = 0; var a255 = 0 }
    var acc: [String: Acc] = [:]
    var layouts: [UInt32: [String: Int]] = [:]
    var done = 0
    var rng = SystemRandomNumberGenerator()
    while done < want {
        let e = cat.entries[Int.random(in: 0..<cat.entries.count, using: &rng)]
        guard let r = try? idx.resource(at: e.resource, from: f, physical: true), let m = try? Drawable.decode(r, at: Int(e.base)), m.failedGeometries == 0 else { continue }
        done += 1
        let hdrs = Drawable.pageHeaders(r, at: Int(e.base))
        for (k, part) in m.parts.enumerated() where k < hdrs.count && part.shader < m.shaders.count {
            let sh = m.shaders[part.shader].name
            let lay = hdrs[k].slots.enumerated().filter { $0.element != 0 }.map { String(format: "%d:%02x", $0.offset, $0.element & 0xFF) }.joined(separator: " ")
            layouts[sh, default: [:]][lay, default: 0] += 1
            for slot in [1, 12, 13] where hdrs[k].slots[slot] & 0xFF == 0x26 {
                let raw = Drawable.rawSlot(r, at: Int(e.base), geometry: k, slot: slot, count: 100000)
                let key = String(format: "%08x slot %2d", sh, slot)
                var a = acc[key] ?? Acc()
                a.parts += 1
                for v in raw {
                    let c = (0..<4).map { Int((v >> (8 * UInt32($0))) & 0xFF) }
                    for i in 0..<4 { a.sum[i] += Double(c[i]); a.mn[i] = min(a.mn[i], c[i]); a.mx[i] = max(a.mx[i], c[i]) }
                    if abs(c[0] + c[1] + c[2] - 255) <= 2 { a.rgb255 += 1 }
                    if abs(c[0] + c[1] + c[2] + c[3] - 255) <= 2 { a.rgba255 += 1 }
                    if c[3] == 255 { a.a255 += 1 }
                    a.n += 1
                }
                acc[key] = a
            }
        }
    }
    for (k, a) in acc.sorted(by: { $0.value.parts > $1.value.parts }) where a.parts >= 5 {
        let h = UInt32(k.prefix(8), radix: 16)!
        print(String(format: "%@ %@ parts %d verts %d mean %@ min %@ max %@ rgb=255 %.2f rgba=255 %.2f a=255 %.2f", names[h] ?? "?", k, a.parts, a.n,
                     a.sum.map { String(Int($0 / Double(max(a.n, 1)))) }.joined(separator: ","), a.mn.map(String.init).joined(separator: ","), a.mx.map(String.init).joined(separator: ","),
                     Double(a.rgb255) / Double(max(a.n, 1)), Double(a.rgba255) / Double(max(a.n, 1)), Double(a.a255) / Double(max(a.n, 1))))
    }
    print("---- layouts")
    for (sh, l) in layouts.sorted(by: { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }).prefix(40) {
        print(String(format: "%08x %@", sh, names[sh] ?? "?"), l.sorted { $0.value > $1.value }.prefix(3).map { "\($0.value)x [\($0.key)]" }.joined(separator: "  "))
    }
case "vcdump":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    let want = Int(args[5]) ?? 500
    var out = Data()
    var done = 0
    var rng = SystemRandomNumberGenerator()
    while done < want {
        let e = cat.entries[Int.random(in: 0..<cat.entries.count, using: &rng)]
        guard let r = try? idx.resource(at: e.resource, from: f, physical: true), let m = try? Drawable.decode(r, at: Int(e.base)), m.failedGeometries == 0 else { continue }
        done += 1
        let hdrs = Drawable.pageHeaders(r, at: Int(e.base))
        for (k, part) in m.parts.enumerated() where k < hdrs.count && part.shader < m.shaders.count {
            let sh = m.shaders[part.shader].name
            var cols: [[UInt32]] = []
            for slot in [1, 12, 13] {
                cols.append(hdrs[k].slots[slot] & 0xFF == 0x26 ? Drawable.rawSlot(r, at: Int(e.base), geometry: k, slot: slot, count: 100000) : [])
            }
            let n = cols.map { $0.count }.max() ?? 0
            for i in 0..<n {
                withUnsafeBytes(of: sh) { out.append(contentsOf: $0) }
                for c in cols { withUnsafeBytes(of: i < c.count ? c[i] : UInt32(0)) { out.append(contentsOf: $0) } }
            }
        }
    }
    try out.write(to: URL(fileURLWithPath: args[6]))
case "layerdump":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    let want = Int(args[5]) ?? 500
    let shaderSet = Set(args[7].split(separator: ",").compactMap { UInt32($0, radix: 16) })
    let params = args[8].split(separator: ",").compactMap { UInt32($0, radix: 16) }
    var out = Data()
    var done = 0, tried = 0
    var rng = SystemRandomNumberGenerator()
    while done < want && tried < want * 400 {
        tried += 1
        let e = cat.entries[Int.random(in: 0..<cat.entries.count, using: &rng)]
        guard let r = try? idx.resource(at: e.resource, from: f, physical: true), let m = try? Drawable.decode(r, at: Int(e.base)), m.failedGeometries == 0 else { continue }
        let used = Set(m.parts.compactMap { $0.shader < m.shaders.count && shaderSet.contains(m.shaders[$0.shader].name) ? $0.shader : nil })
        guard used.count >= 2 else { continue }
        done += 1
        let hdrs = Drawable.pageHeaders(r, at: Int(e.base))
        for (k, part) in m.parts.enumerated() where k < hdrs.count && used.contains(part.shader) {
            let sh = m.shaders[part.shader]
            let texs = params.map { p in sh.textures.first(where: { $0.param == p })?.hash ?? 0 }
            let ids = m.indices[part.indexStart..<part.indexStart + part.indexCount]
            let lo = Int(ids.min()!), hi = Int(ids.max()!)
            let c1 = hdrs[k].slots[1] & 0xFF == 0x26 ? Drawable.rawSlot(r, at: Int(e.base), geometry: k, slot: 1, count: 100000) : []
            let c12 = hdrs[k].slots[12] & 0xFF == 0x26 ? Drawable.rawSlot(r, at: Int(e.base), geometry: k, slot: 12, count: 100000) : []
            let c13 = hdrs[k].slots[13] & 0xFF == 0x26 ? Drawable.rawSlot(r, at: Int(e.base), geometry: k, slot: 13, count: 100000) : []
            for v in lo...hi {
                let i = v - lo
                let p = m.positions[v]
                withUnsafeBytes(of: UInt32(done)) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: UInt32(k)) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: p.x) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: p.y) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: p.z) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: i < c1.count ? c1[i] : 0) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: i < c12.count ? c12[i] : 0) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: i < c13.count ? c13[i] : 0) { out.append(contentsOf: $0) }
                for t in 0..<4 { withUnsafeBytes(of: t < texs.count ? texs[t] : 0) { out.append(contentsOf: $0) } }
            }
        }
    }
    try out.write(to: URL(fileURLWithPath: args[6]))
    print("drawables \(done) of \(tried) tried, \(out.count / 64) vertices")
case "findshader":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    let want = UInt32(args[5], radix: 16)!
    let n = args.count > 6 ? Int(args[6])! : 5
    var found = 0
    for k in 0..<cat.entries.count where found < n {
        let e = cat.entries[(k * 104729) % cat.entries.count]
        guard let r = try? idx.resource(at: e.resource, from: f, physical: false) else { continue }
        let sh = Drawable.shaderNames(r.virtual, at: Int(e.base))
        if sh.contains(want) { print(e.name); found += 1 }
    }
case "ttdbdups":
    let home = NSHomeDirectory()
    let db = TextureDB(roots: ["\(home)/testing/data/ttdb", "\(home)/testing/pack"], aliasArchive: ("\(home)/testing/textures.rpf", "\(home)/testing/6stars-data/textures.idx"))
    var all: [UInt64: [(Int, Int)]] = [:]
    for (fi, f) in db.files.enumerated() { for (ti, h) in f.hashes.enumerated() { all[h, default: []].append((fi, ti)) } }
    let dups = all.filter { $0.value.count > 1 }
    print("unique \(all.count), with duplicates \(dups.count)")
    var rescued = 0, both = 0, examples = 0
    for (h, list) in dups {
        let (f0, t0) = list[0]
        let d0 = db.files[f0].decodable(t0)
        if d0.levels == d0.total { continue }
        for (fi, ti) in list.dropFirst() {
            let d = db.files[fi].decodable(ti)
            if d.levels > d0.levels {
                rescued += 1
                if examples < 10 {
                    examples += 1
                    print(String(format: "%016llx", h), (db.files[f0].path as NSString).lastPathComponent, d0, "->", (db.files[fi].path as NSString).lastPathComponent, d, db.files[f0].info(t0).format, db.files[fi].info(ti).format)
                }
                break
            }
        }
        both += 1
    }
    print("duplicates where first copy incomplete: \(both), better copy elsewhere: \(rescued)")
case "mapinfo":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let wanted = Set(args[4].split(separator: ",").map { Hash.joaat(String($0)) })
    let starts = MapData.prd0Starts(idx)
    let lock = NSLock()
    var out: [String] = []
    DispatchQueue.concurrentPerform(iterations: starts.count) { i in
        guard let r = try? idx.resource(at: starts[i], from: f, physical: false), let p = try? PRD0(r.virtual) else { return }
        guard let mb = p.block(ofType: MapData.mapStruct), let ms = p.structs[MapData.mapStruct] else { return }
        for blk in p.blocks {
            guard let st = p.structs[blk.type], st.size == 144, let (am, _) = st.member(0xA023_A02C) else { continue }
            let n = blk.size / st.size
            for k in 0..<n {
                let o = blk.offset + k * st.size
                guard wanted.contains(p.u32(o + am.offset)) else { continue }
                var lines = [String(format: "res %011llx entity %d/%d arch %08x", starts[i], k, n, p.u32(o + am.offset))]
                lines.append("   ent 0x50..0x84: " + stride(from: 0x50, to: 0x84, by: 2).map { String(format: "%04x", p.u16(o + $0)) }.joined(separator: " "))
                var mline = "   map:"
                for m in ms.members {
                    let v = mb.offset + m.offset
                    mline += String(format: " %08x@%x:%02x=%08x", m.name, m.offset, m.type, v + 4 <= p.b.count ? p.u32(v) : 0)
                }
                lines.append(mline)
                lock.lock(); out.append(lines.joined(separator: "\n")); lock.unlock()
            }
        }
    }
    for o in out.sorted() { print(o) }
case "mapheaders":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let starts = MapData.prd0Starts(idx)
    let lock = NSLock()
    var out: [String] = []
    DispatchQueue.concurrentPerform(iterations: starts.count) { i in
        guard let r = try? idx.resource(at: starts[i], from: f, physical: false), let p = try? PRD0(r.virtual) else { return }
        guard let mb = p.block(ofType: MapData.mapStruct), let ms = p.structs[MapData.mapStruct] else { return }
        var cols = [String(format: "%011llx", starts[i])]
        for m in ms.members where m.name != 0x100 && (m.type == 0x4A || m.type == 0x4F || m.type == 0x15) {
            let v = mb.offset + m.offset
            guard v + 8 <= p.b.count else { continue }
            cols.append(String(format: m.type == 0x4F ? "%08x=%016llx" : "%08x=%08x", m.name, m.type == 0x4F ? p.u64(v) : UInt64(p.u32(v))))
        }
        var lv = [Int](repeating: 0, count: 8), n = 0
        for blk in p.blocks {
            guard let s = p.structs[blk.type], s.size == 144 else { continue }
            for k in 0..<blk.size / 144 { lv[Int(min(p.u8(blk.offset + k * 144 + 0x7E), 7))] += 1; n += 1 }
        }
        cols.append("n=\(n) lv=" + lv.map(String.init).joined(separator: ","))
        lock.lock(); out.append(cols.joined(separator: "\t")); lock.unlock()
    }
    try out.sorted().joined(separator: "\n").write(toFile: args[4], atomically: true, encoding: .utf8)
    print("\(out.count) maps")
case "unlisted":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    var names: [UInt32: String] = [:]
    for e in cat.entries { names[e.hash] = e.name }
    let starts = MapData.prd0Starts(idx)
    var shown = 0
    for st in starts {
        guard shown < 6, let r = try? idx.resource(at: st, from: f, physical: false), let p = try? PRD0(r.virtual),
              let mb = p.block(ofType: MapData.mapStruct), let ms = p.structs[MapData.mapStruct], let (em, _) = ms.member(0xCCAB_9307) else { continue }
        var listed = Set<Int>()
        if let (ao, n) = p.array(at: mb.offset + em.offset) {
            for k in 0..<n {
                let v = p.u64(ao + 8 * k)
                let blk = Int(v & 0xFFFFF)
                if blk >= 1 && blk <= p.blocks.count { listed.insert(p.blocks[blk - 1].offset + Int(v >> 20)) }
            }
        }
        var unl: [Int] = []
        var types: [String] = []
        for blk in p.blocks {
            guard let s = p.structs[blk.type], s.size >= 0x80, s.member(0x77DD_4010) != nil, s.member(0xA023_A02C) != nil else { continue }
            types.append(String(format: "%08x x%d", blk.type, blk.size / s.size))
            for i in 0..<blk.size / s.size where !listed.contains(blk.offset + i * s.size) { unl.append(blk.offset + i * s.size) }
        }
        guard !unl.isEmpty else { continue }
        shown += 1
        print(String(format: "map %011llx name %08x listed %d unlisted %d blocks %@", st, p.u32(mb.offset + 8), listed.count, unl.count, types.joined(separator: ", ")))
        var refs: [Int: [String]] = [:]
        let targets = Set(unl)
        for o in stride(from: 0, to: p.b.count - 8, by: 8) {
            let v = p.u64(o)
            let blk = Int(v & 0xFFFFF)
            guard blk >= 1, blk <= p.blocks.count, v >> 52 == 0 else { continue }
            let t = p.blocks[blk - 1].offset + Int(v >> 20)
            if targets.contains(t) {
                let owner = p.blocks.first { o >= $0.offset && o < $0.offset + $0.size }
                refs[t, default: []].append(String(format: "%x in %08x+%x", o, owner?.type ?? 0, o - (owner?.offset ?? 0)))
            }
        }
        for o in unl.prefix(5) {
            let a = p.u32(o + 0x60)
            let s = p.structs[p.blocks.first { o >= $0.offset && o < $0.offset + $0.size }!.type]!
            let am = s.member(0xA023_A02C)!.0.offset, pm = s.member(0x0116_6164)!.0.offset
            print(String(format: "   %@ pos %.1f %.1f %.1f lvl %d refs %@", names[p.u32(o + am)] ?? String(format: "%08x", p.u32(o + am)), p.f32(o + pm), p.f32(o + pm + 4), p.f32(o + pm + 8), s.size == 144 ? Int(p.u8(o + 0x7E)) : -1, (refs[o] ?? []).joined(separator: "; ")), a)
        }
        let blkRefs = Set(refs.values.flatMap { $0 }.map { String($0.split(separator: " ")[2]) })
        print("   referencing blocks: \(blkRefs.sorted().prefix(8)) unreferenced \(unl.filter { refs[$0] == nil }.count)")
    }
case "triat":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    guard let ci = cat.byHash[Hash.joaat(args[5])], let x = Float(args[6]), let y = Float(args[7]) else { fail("usage: rpftool triat <rpf> <index> <catalog> <name> <x> <y>") }
    let e = cat.entries[ci]
    if ProcessInfo.processInfo.environment["MESHLETS"] != nil { Drawable.meshletDump = { print($0) } }
    let wantLod = Int(ProcessInfo.processInfo.environment["LOD"] ?? "0") ?? 0
    let m = try Drawable.load(idx, f, resource: e.resource, base: Int(e.base), lod: wantLod)
    print("\(args[5]): lod \(m.lod) present \(m.lodPresent) dist \(m.lodDistances) \(m.positions.count) verts, \(m.parts.count) parts, failed geometries \(m.failedGeometries)/\(m.geometries)")
    if Drawable.meshletDump != nil { print("meshlet stats: tris \(Drawable.meshletStats[0]) local-oob \(Drawable.meshletStats[1]) vert-oob \(Drawable.meshletStats[2]) degenerate \(Drawable.meshletStats[3]) meshlets \(Drawable.meshletStats[4]) reversed \(Drawable.meshletStats[5])") }
    let pt = SIMD2(x, y)
    func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
    for (pi, part) in m.parts.enumerated() {
        var hits: [String] = []
        var t = part.indexStart
        while t + 2 < part.indexStart + part.indexCount {
            let a = m.positions[Int(m.indices[t])], b = m.positions[Int(m.indices[t + 1])], c = m.positions[Int(m.indices[t + 2])]
            let A = SIMD2(a.x, a.y), B = SIMD2(b.x, b.y), C = SIMD2(c.x, c.y)
            let d1 = cross(B - A, pt - A), d2 = cross(C - B, pt - B), d3 = cross(A - C, pt - C)
            let area = cross(B - A, C - A)
            if (d1 >= 0 && d2 >= 0 && d3 >= 0) || (d1 <= 0 && d2 <= 0 && d3 <= 0), abs(area) > 1e-6 {
                let n = simd_normalize(simd_cross(b - a, c - a))
                hits.append(String(format: "z %.2f winding %@ nz %.2f", (a.z + b.z + c.z) / 3, area > 0 ? "ccw" : "cw", n.z))
            }
            t += 3
        }
        guard !hits.isEmpty else { continue }
        let sh = part.shader < m.shaders.count ? m.shaders[part.shader] : nil
        print(String(format: "part %d shader %d %08x tris %d: ", pi, part.shader, sh?.name ?? 0, part.indexCount / 3) + hits.prefix(3).joined(separator: "; "))
        if let sh = sh { print("   textures: " + sh.textures.map { String(format: "%08x=%016llx", $0.param, $0.hash) }.joined(separator: " ")) }
    }
case "near":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    var names: [UInt32: String] = [:]
    for path in args[4].split(separator: ",") {
        if let c = try? Catalog.read(from: String(path)) { for e in c.entries { names[e.hash] = e.name } }
    }
    guard let x = Float(args[5]), let y = Float(args[6]), let r = Float(args[7]) else { fail("usage: rpftool near <rpf> <index> <catalogs> <x> <y> <r>") }
    let w = WorldData.load(sources: [(idx, f)])
    print("\(w.maps.count) maps, \(w.entities.count) entities, \(w.archetypes.count) archetypes")
    for e in w.entities where simd_distance(SIMD2(e.position.x, e.position.y), SIMD2(x, y)) < r {
        let m = w.maps[Int(e.map)]
        print(String(format: "  %@ pos %.1f %.1f %.1f lvl %d map %08x flags %x", names[e.archetype] ?? String(format: "%08x", e.archetype), e.position.x, e.position.y, e.position.z, e.lodLevel, m.name, m.flags))
    }
case "posscan":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    guard let x = Float(args[4]), let y = Float(args[5]), let r = Float(args[6]) else { fail("usage: rpftool posscan <rpf> <index> <x> <y> <r>") }
    let starts = MapData.prd0Starts(idx)
    let lock = NSLock()
    var out: [String] = []
    DispatchQueue.concurrentPerform(iterations: starts.count) { i in
        guard let res = try? idx.resource(at: starts[i], from: f, physical: false), let p = try? PRD0(res.virtual) else { return }
        let isMap = p.block(ofType: MapData.mapStruct) != nil
        for blk in p.blocks where blk.size > 0 {
            guard let s = p.structs[blk.type], s.size > 0 else { continue }
            for m in s.members where m.type == 0x32 || m.type == 0x33 {
                for k in 0..<blk.size / s.size {
                    let o = blk.offset + k * s.size + m.offset
                    guard o + 12 <= p.b.count else { break }
                    let px = p.f32(o), py = p.f32(o + 4)
                    if abs(px - x) < r && abs(py - y) < r && simd_distance(SIMD2(px, py), SIMD2(x, y)) < r {
                        let arch = s.member(0xA023_A02C).map { String(format: " arch %08x", p.u32(blk.offset + k * s.size + $0.0.offset)) } ?? ""
                        lock.lock()
                        out.append(String(format: "%011llx %@ struct %08x size %d member %08x pos %.1f %.1f %.1f%@", starts[i], isMap ? "map" : "other", blk.type, s.size, m.name, px, py, p.f32(o + 8), arch))
                        lock.unlock()
                    }
                }
            }
        }
    }
    let types = Dictionary(grouping: out) { $0.split(separator: " ")[3] + " " + $0.split(separator: " ")[7] }
    for (k, v) in types.sorted(by: { $0.value.count > $1.value.count }) { print("\(v.count)x struct \(k): e.g. \(v[0])") }
case "parts":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    guard let ci = cat.byHash[Hash.joaat(args[5])] else { fail("unknown drawable") }
    let e = cat.entries[ci]
    let m = try Drawable.load(idx, f, resource: e.resource, base: Int(e.base), lod: Int(ProcessInfo.processInfo.environment["LOD"] ?? "0") ?? 0)
    print("\(args[5]): lod \(m.lod) present \(m.lodPresent) \(m.positions.count) verts, \(m.parts.count) parts, catalog center \(e.center) radius \(e.radius)")
    for (pi, part) in m.parts.enumerated() {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        var up = 0, down = 0, side = 0
        var t = part.indexStart
        while t + 2 < part.indexStart + part.indexCount {
            let a = m.positions[Int(m.indices[t])], b = m.positions[Int(m.indices[t + 1])], c = m.positions[Int(m.indices[t + 2])]
            lo = simd_min(lo, simd_min(a, simd_min(b, c))); hi = simd_max(hi, simd_max(a, simd_max(b, c)))
            let n = simd_cross(b - a, c - a)
            let l = simd_length(n)
            if l > 0 { let z = n.z / l; if z < -0.5 { up += 1 } else if z > 0.5 { down += 1 } else { side += 1 } }
            t += 3
        }
        let sh = part.shader < m.shaders.count ? m.shaders[part.shader].name : 0
        print(String(format: "part %2d shader %08x tris %5d facing up %d down %d side %d bounds (%.1f %.1f %.1f)..(%.1f %.1f %.1f)", pi, sh, part.indexCount / 3, up, down, side, lo.x, lo.y, lo.z, hi.x, hi.y, hi.z))
    }
case "shadernames":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    for name in args[5...] {
        guard let ci = cat.byHash[Hash.joaat(name)], let m = try? Drawable.load(idx, f, resource: cat.entries[ci].resource, base: Int(cat.entries[ci].base)) else { print(name, "not loaded"); continue }
        print(name, m.shaders.map { String(format: "%08x", $0.name) }.joined(separator: " "), "tris", m.indices.count / 3)
    }
case "lods":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    for name in args[5...] {
        guard let ci = cat.byHash[Hash.joaat(name)], let m = try? Drawable.load(idx, f, resource: cat.entries[ci].resource, base: Int(cat.entries[ci].base)) else { print(name, "not loaded"); continue }
        print(name, m.lodPresent, m.lodDistances, "tris", m.indices.count / 3)
    }
case "lodsurvey":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    var hist: [String: Int] = [:]
    var shown = 0
    for ci in stride(from: 0, to: cat.entries.count, by: max(1, cat.entries.count / 3000)) {
        guard let m = try? Drawable.load(idx, f, resource: cat.entries[ci].resource, base: Int(cat.entries[ci].base)), m.lodPresent.count == 4 else { continue }
        let pat = m.lodPresent.map { $0 ? "1" : "0" }.joined()
        let z = m.lodDistances[0] == 0 ? "z" : (m.lodDistances[0] >= 9998 ? "max" : "n")
        hist[pat + " d0:" + z, default: 0] += 1
        if pat == "1111" && shown < 25 { shown += 1; print(m.lodDistances.map { String(format: "%.1f", $0) }.joined(separator: " "), "r", String(format: "%.1f", simd_length(m.boundsMax - m.boundsMin) / 2), "tris", m.indices.count / 3) }
    }
    for (k, v) in hist.sorted(by: { $0.value > $1.value }) { print(k, v) }
case "windcheck":
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let cat = try Catalog.read(from: args[4])
    for name in args[5...] {
        guard let ci = cat.byHash[Hash.joaat(name)], let m = try? Drawable.load(idx, f, resource: cat.entries[ci].resource, base: Int(cat.entries[ci].base)) else { continue }
        var agree = 0, total = 0
        var t = 0
        while t + 2 < m.indices.count {
            let a = Int(m.indices[t]), b = Int(m.indices[t + 1]), c = Int(m.indices[t + 2])
            t += 3
            guard a < m.normals.count, b < m.normals.count, c < m.normals.count else { continue }
            let g = simd_cross(m.positions[b] - m.positions[a], m.positions[c] - m.positions[a])
            guard simd_length(g) > 1e-9 else { continue }
            let vn = m.normals[a] + m.normals[b] + m.normals[c]
            total += 1
            if simd_dot(g, vn) > 0 { agree += 1 }
        }
        print(String(format: "%@: %d tris, %.1f%% ccw-front agree with vertex normals", name, total, total > 0 ? 100 * Double(agree) / Double(total) : 0))
    }
case "bundle":
    guard args.count == 6 else { fail("usage: rpftool bundle <rpf> <index> <magic> <out>") }
    let f = try MappedFile(path: args[2])
    let idx = try ArchiveIndex.read(from: args[3])
    let picked = idx.entries.filter { $0.kind == .zlib && $0.magic == args[4] }
    let fh = FileManager.default.createFile(atPath: args[5], contents: nil) ? FileHandle(forWritingAtPath: args[5])! : nil
    guard let out = fh else { fail("cannot write \(args[5])") }
    for e in picked {
        let bytes = try idx.load(e, from: f)
        var hdr = Data()
        withUnsafeBytes(of: e.offset.littleEndian) { hdr.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { hdr.append(contentsOf: $0) }
        out.write(hdr)
        out.write(Data(bytes))
    }
    out.closeFile()
    print("bundled \(picked.count) entries")
default:
    fail(usage)
}
