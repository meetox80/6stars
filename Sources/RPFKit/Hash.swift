import Foundation

public enum Hash {
    public static func joaat(_ s: String) -> UInt32 {
        var h: UInt32 = 0
        for c in s.lowercased().utf8 {
            h = h &+ UInt32(c)
            h = h &+ (h << 10)
            h ^= h >> 6
        }
        h = h &+ (h << 3)
        h ^= h >> 11
        h = h &+ (h << 15)
        return h
    }
}
