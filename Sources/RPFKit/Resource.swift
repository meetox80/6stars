import Foundation

public struct Resource: Sendable {
    public var virtual: [UInt8]
    public var physical: [UInt8]

    @inline(__always) public static func vptr(_ b: [UInt8], _ o: Int) -> Int? {
        guard o >= 0, o + 8 <= b.count else { return nil }
        let v = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }
        return (v >> 32) == 0 && (v >> 28) == 5 ? Int(v & 0x0FFF_FFFF) : nil
    }

    @inline(__always) public static func pptr(_ b: [UInt8], _ o: Int) -> Int? {
        guard o >= 0, o + 8 <= b.count else { return nil }
        let v = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }
        return (v >> 32) == 0 && (v >> 28) == 6 ? Int(v & 0x0FFF_FFFF) : nil
    }

    static func pointsInto(_ b: [UInt8], _ range: Range<Int>) -> Bool {
        b.withUnsafeBytes { p in
            var o = 0
            while o + 8 <= p.count {
                let v = p.loadUnaligned(fromByteOffset: o, as: UInt64.self)
                if (v >> 32) == 0 && (v >> 28) == 5 && range.contains(Int(v & 0x0FFF_FFFF)) { return true }
                o += 8
            }
            return false
        }
    }
}

extension ArchiveIndex {
    public func entryIndex(at offset: UInt64) -> Int? {
        var lo = 0, hi = entries.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if entries[mid].offset == offset { return mid }
            if entries[mid].offset < offset { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    public func isResourceStart(_ i: Int) -> Bool {
        let e = entries[i]
        guard e.kind == .zlib, e.head.count >= 16, e.head[0..<8].allSatisfy({ $0 == 0 }) else { return false }
        let v = e.head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
        guard (v >> 32) == 0 && (v >> 28) == 5 else { return false }
        guard i > 0 else { return true }
        let p = entries[i - 1]
        return !(p.kind == .zlib && (p.offset + p.size + 15) & ~15 == e.offset)
    }

    public var resourceStarts: [UInt64] {
        entries.indices.compactMap { isResourceStart($0) ? entries[$0].offset : nil }
    }

    static let chainedStream: UInt64 = 0x800000

    static func isBulk(_ e: Entry) -> Bool { e.unpacked > 0 && e.unpacked % 0x10000 == 0 }

    func streamRun(from start: Int) -> [Int] {
        var run = [start]
        var i = start + 1
        while run.count < 64, i < entries.count {
            let prev = entries[run[run.count - 1]]
            let e = entries[i]
            guard e.kind == .zlib, e.offset == (prev.offset + prev.size + 15) & ~15, !isResourceStart(i) else { break }
            run.append(i)
            i += 1
        }
        return run
    }

    func bulkEnd(_ run: [Int], from k: Int) -> Int {
        var j = k
        while j < run.count, entries[run[j]].unpacked == Self.chainedStream { j += 1 }
        if j < run.count, Self.isBulk(entries[run[j]]), entries[run[j]].unpacked != Self.chainedStream { j += 1 }
        return j
    }

    public func virtualSegment(at offset: UInt64, from f: MappedFile) throws -> (data: [UInt8], physical: [Int]) {
        guard let start = entryIndex(at: offset), entries[start].kind == .zlib else { throw RPFError.format("no zlib stream at 0x\(String(offset, radix: 16))") }
        let run = streamRun(from: start)
        let vb = max(bulkEnd(run, from: 0), 1)
        var data: [UInt8] = []
        for i in run[0..<vb] { data += try load(entries[i], from: f) }
        var vc = vb
        if vb < run.count, !Self.isBulk(entries[run[vb]]), Self.isBulk(entries[run[0]]) {
            let tail = Int(entries[run[vb]].unpacked)
            if vb + 1 < run.count || Resource.pointsInto(data, data.count..<(data.count + tail)) { vc = vb + 1 }
        }
        if vc > vb { data += try load(entries[run[vb]], from: f) }
        var pc = vc
        if vc < run.count {
            pc = bulkEnd(run, from: vc)
            if pc < run.count, !Self.isBulk(entries[run[pc]]) { pc += 1 }
        }
        return (data, Array(run[vc..<pc]))
    }

    public func physicalSegment(_ streams: [Int], from f: MappedFile, upTo need: Int = .max) throws -> [UInt8] {
        var out: [UInt8] = []
        for i in streams where out.count < need {
            let e = entries[i]
            let limit = need == .max ? Int.max : need - out.count
            out += try Inflate.full(f.base + Int(e.offset), Int(e.size), expected: min(Int(e.unpacked), limit), limit: limit).data
        }
        return out
    }

    public func resource(at offset: UInt64, from f: MappedFile, physical: Bool) throws -> Resource {
        let (v, streams) = try virtualSegment(at: offset, from: f)
        return Resource(virtual: v, physical: physical ? try physicalSegment(streams, from: f) : [])
    }
}
