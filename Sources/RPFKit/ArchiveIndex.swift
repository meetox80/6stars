import Foundation

public enum EntryKind: UInt8, CaseIterable, Sendable {
    case rpf9 = 1
    case zlib = 2
    case rsc8 = 3
    case awc = 4
    case raw = 5

    public var name: String {
        switch self {
        case .rpf9: return "rpf9"
        case .zlib: return "zlib"
        case .rsc8: return "rsc8"
        case .awc: return "awc"
        case .raw: return "raw"
        }
    }
}

public struct Entry: Sendable {
    public static let headSize = 48
    public var offset: UInt64
    public var size: UInt64
    public var unpacked: UInt64
    public var kind: EntryKind
    public var padded: Bool
    public var head: [UInt8]

    public var magic: String {
        guard head.count >= 4 else { return "?" }
        let m = head[0..<4]
        if m.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return String(bytes: m, encoding: .ascii)! }
        return m.map { String(format: "%02x", $0) }.joined()
    }
}

public final class ArchiveIndex {
    public static let block = 0x1000
    static let fileMagic: UInt32 = 0x49585052
    static let version: UInt32 = 3
    static let recordSize = 80

    public let archiveSize: UInt64
    public var entries: [Entry]

    public init(archiveSize: UInt64, entries: [Entry]) {
        self.archiveSize = archiveSize
        self.entries = entries
    }

    static func classify(_ f: MappedFile, _ o: Int, follows: Bool, scratch: inout [UInt8]) -> Entry? {
        let inBlock = o & (block - 1)
        let aligned = inBlock == 0 || inBlock == 0x10
        let padded = o >= 64 && f.isZero(o - 64, 64)
        func entry(_ k: EntryKind, size: Int = 0, unpacked: Int = 0, _ head: [UInt8]) -> Entry {
            Entry(offset: UInt64(o), size: UInt64(size), unpacked: UInt64(unpacked), kind: k, padded: padded, head: head)
        }
        switch f.u32(o) {
        case 0x52504639: return entry(.rpf9, size: Int(f.u32(o + 4)), f.bytes(o, Entry.headSize))
        case 0x54414441 where aligned: return entry(.awc, f.bytes(o, Entry.headSize))
        case 0x38435352 where aligned: return entry(.rsc8, f.bytes(o, Entry.headSize))
        default: break
        }
        if Inflate.isZlibHeader(f.u8(o), f.u8(o + 1)) && (aligned || follows || (o > 0 && f.u8(o - 1) == 0)) {
            if let r = Inflate.measure(f.base + o, min(f.size - o, 1 << 31), headSize: Entry.headSize, scratch: &scratch) {
                return entry(.zlib, size: r.consumed, unpacked: r.produced, r.head)
            }
        }
        if aligned && padded && !f.isZero(o, 16) { return entry(.raw, f.bytes(o, Entry.headSize)) }
        return nil
    }

    public static func scan(_ f: MappedFile, segment: Int = 128 << 20, progress: ((Int, Int) -> Void)? = nil) -> ArchiveIndex {
        let segments = (f.size + segment - 1) / segment
        let slots = UnsafeMutableBufferPointer<[Entry]>.allocate(capacity: segments)
        slots.initialize(repeating: [])
        defer { slots.deallocate() }
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: segments) { i in
            var scratch = [UInt8](repeating: 0, count: 1 << 20)
            var out: [Entry] = []
            var o = i * segment
            let end = min(f.size, o + segment)
            var follows = false
            while o + 16 <= end {
                if let e = classify(f, o, follows: follows, scratch: &scratch) {
                    out.append(e)
                    if e.kind == .zlib || e.kind == .rpf9 {
                        o = (o + max(Int(e.size), 16) + 15) & ~15
                        follows = true
                        continue
                    }
                }
                follows = false
                o += 16
            }
            slots[i] = out
            lock.lock()
            done += 1
            let d = done
            lock.unlock()
            progress?(d, segments)
        }
        var merged: [Entry] = []
        var coveredTo: UInt64 = 0
        var scratch = [UInt8](repeating: 0, count: 1 << 20)
        func chain(before limit: UInt64) {
            while let last = merged.last, last.kind == .zlib || last.kind == .rpf9 {
                let next = (last.offset + max(last.size, 16) + 15) & ~15
                guard next < limit, Int(next) + 16 <= f.size, let x = classify(f, Int(next), follows: true, scratch: &scratch), x.kind == .zlib else { return }
                merged.append(x)
                coveredTo = x.offset + x.size
            }
        }
        for e in slots.joined() {
            if e.offset < coveredTo { continue }
            chain(before: e.offset)
            if e.offset < coveredTo { continue }
            merged.append(e)
            if e.kind == .zlib || e.kind == .rpf9 { coveredTo = e.offset + e.size }
        }
        chain(before: UInt64(f.size))
        return ArchiveIndex(archiveSize: UInt64(f.size), entries: merged)
    }

    public func write(to path: String) throws {
        var d = Data(capacity: 32 + entries.count * Self.recordSize)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(Self.fileMagic)
        put(Self.version)
        put(archiveSize)
        put(UInt64(entries.count))
        put(UInt64(0))
        for e in entries {
            put(e.offset)
            put(e.size)
            put(e.unpacked)
            put(e.kind.rawValue)
            put(UInt8(e.padded ? 1 : 0))
            put(UInt8(e.head.count))
            d.append(contentsOf: [UInt8](repeating: 0, count: 5))
            d.append(contentsOf: e.head)
            d.append(contentsOf: [UInt8](repeating: 0, count: Entry.headSize - e.head.count))
        }
        try d.write(to: URL(fileURLWithPath: path))
    }

    public static func read(from path: String) throws -> ArchiveIndex {
        let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        return try d.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> ArchiveIndex in
            guard p.count >= 32, p.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == fileMagic else {
                throw RPFError.format("not an index file")
            }
            guard p.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == version else {
                throw RPFError.format("index was written by an older version, rescan the archive")
            }
            let size = p.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            let count = Int(p.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
            guard p.count >= 32 + count * recordSize else { throw RPFError.format("index truncated") }
            var entries: [Entry] = []
            entries.reserveCapacity(count)
            for i in 0..<count {
                let r = 32 + i * recordSize
                guard let kind = EntryKind(rawValue: p[r + 24]) else { throw RPFError.format("bad entry kind") }
                let n = Int(p[r + 26])
                entries.append(Entry(offset: p.loadUnaligned(fromByteOffset: r, as: UInt64.self),
                                     size: p.loadUnaligned(fromByteOffset: r + 8, as: UInt64.self),
                                     unpacked: p.loadUnaligned(fromByteOffset: r + 16, as: UInt64.self),
                                     kind: kind,
                                     padded: p[r + 25] != 0,
                                     head: Array(p[(r + 32)..<(r + 32 + n)])))
            }
            return ArchiveIndex(archiveSize: size, entries: entries)
        }
    }

    public func entry(at offset: UInt64) -> Entry? {
        var lo = 0, hi = entries.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if entries[mid].offset == offset { return entries[mid] }
            if entries[mid].offset < offset { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    public func load(_ e: Entry, from f: MappedFile) throws -> [UInt8] {
        switch e.kind {
        case .zlib:
            return try Inflate.full(f.base + Int(e.offset), Int(e.size), expected: Int(e.unpacked)).data
        default:
            let next = entries.first(where: { $0.offset > e.offset })?.offset ?? archiveSize
            return f.bytes(Int(e.offset), Int(next - e.offset))
        }
    }
}
