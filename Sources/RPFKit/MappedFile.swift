import Foundation

public enum RPFError: Error, CustomStringConvertible {
    case io(String)
    case format(String)

    public var description: String {
        switch self {
        case .io(let s): return "io: \(s)"
        case .format(let s): return "format: \(s)"
        }
    }
}

public final class MappedFile: @unchecked Sendable {
    public let path: String
    public let size: Int
    public let base: UnsafeRawPointer
    private let fd: Int32

    public init(path: String) throws {
        self.path = path
        fd = open(path, O_RDONLY)
        if fd < 0 { throw RPFError.io("cannot open \(path)") }
        var st = stat()
        if fstat(fd, &st) != 0 { close(fd); throw RPFError.io("cannot stat \(path)") }
        size = Int(st.st_size)
        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else {
            close(fd)
            throw RPFError.io("cannot map \(path)")
        }
        base = UnsafeRawPointer(p)
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), size)
        close(fd)
    }

    public func advise(sequential: Bool) {
        madvise(UnsafeMutableRawPointer(mutating: base), size, sequential ? MADV_SEQUENTIAL : MADV_RANDOM)
    }

    @inline(__always) public func u8(_ o: Int) -> UInt8 { base.load(fromByteOffset: o, as: UInt8.self) }
    @inline(__always) public func u16(_ o: Int) -> UInt16 { base.loadUnaligned(fromByteOffset: o, as: UInt16.self) }
    @inline(__always) public func u32(_ o: Int) -> UInt32 { base.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
    @inline(__always) public func u64(_ o: Int) -> UInt64 { base.loadUnaligned(fromByteOffset: o, as: UInt64.self) }

    public func bytes(_ o: Int, _ n: Int) -> [UInt8] {
        let n = max(0, min(n, size - o))
        return Array(UnsafeRawBufferPointer(start: base + o, count: n))
    }

    public func isZero(_ o: Int, _ n: Int) -> Bool {
        var i = 0
        while i + 8 <= n {
            if base.loadUnaligned(fromByteOffset: o + i, as: UInt64.self) != 0 { return false }
            i += 8
        }
        while i < n {
            if base.load(fromByteOffset: o + i, as: UInt8.self) != 0 { return false }
            i += 1
        }
        return true
    }
}
