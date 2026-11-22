import CZlib
import Foundation

public enum Inflate {
    @inline(__always) public static func isZlibHeader(_ a: UInt8, _ b: UInt8) -> Bool {
        a == 0x78 && (UInt16(a) << 8 | UInt16(b)) % 31 == 0 && (b & 0x20) == 0
    }

    public struct Result {
        public var consumed: Int
        public var produced: Int
        public var head: [UInt8]
    }

    public static func measure(_ src: UnsafeRawPointer, _ srcLen: Int, headSize: Int, scratch: inout [UInt8]) -> Result? {
        var z = z_stream()
        guard inflateInit_(&z, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&z) }
        z.next_in = UnsafeMutablePointer(mutating: src.assumingMemoryBound(to: UInt8.self))
        z.avail_in = UInt32(min(srcLen, Int(UInt32.max)))
        var head: [UInt8] = []
        while true {
            let st: Int32 = scratch.withUnsafeMutableBytes { out in
                z.next_out = out.baseAddress!.assumingMemoryBound(to: UInt8.self)
                z.avail_out = UInt32(out.count)
                let st = inflate(&z, Z_NO_FLUSH)
                let n = out.count - Int(z.avail_out)
                if head.count < headSize && n > 0 {
                    head.append(contentsOf: UnsafeRawBufferPointer(rebasing: out[0..<min(n, headSize - head.count)]))
                }
                return st
            }
            if st == Z_STREAM_END { return Result(consumed: Int(z.total_in), produced: Int(z.total_out), head: head) }
            if st != Z_OK { return nil }
        }
    }

    public static func full(_ src: UnsafeRawPointer, _ srcLen: Int, expected: Int = 0, limit: Int = .max) throws -> (data: [UInt8], consumed: Int) {
        var z = z_stream()
        guard inflateInit_(&z, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw RPFError.format("zlib init failed") }
        defer { inflateEnd(&z) }
        var out = [UInt8](repeating: 0, count: max(expected, 1 << 16))
        var produced = 0
        z.next_in = UnsafeMutablePointer(mutating: src.assumingMemoryBound(to: UInt8.self))
        z.avail_in = UInt32(min(srcLen, Int(UInt32.max)))
        while true {
            if produced == out.count { out.append(contentsOf: repeatElement(0, count: out.count)) }
            let st: Int32 = out.withUnsafeMutableBytes { o in
                z.next_out = o.baseAddress!.assumingMemoryBound(to: UInt8.self) + produced
                z.avail_out = UInt32(o.count - produced)
                let st = inflate(&z, Z_NO_FLUSH)
                produced = o.count - Int(z.avail_out)
                return st
            }
            if st == Z_STREAM_END || produced >= limit { break }
            if st != Z_OK && !(st == Z_BUF_ERROR && z.avail_out == 0) { throw RPFError.format("corrupt zlib stream (\(st))") }
        }
        out.removeSubrange(produced...)
        return (out, Int(z.total_in))
    }
}
