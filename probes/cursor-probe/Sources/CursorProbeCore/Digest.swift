/// FNV-1a 64-bit over raw bytes. Not cryptographic; only used to tell cursor images apart in a probe log.
public enum Digest {
    public static func fnv1a64(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    /// Word-at-a-time variant for pixel buffers (8x fewer multiplies; a 280x400 RGBA cursor is 448 KB).
    /// Same family as FNV-1a but NOT byte-compatible with it. Deterministic for the same bytes and length.
    public static func wordHash64(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ UInt64(bytes.count)
        let words = bytes.count / 8
        for i in 0..<words {
            h = (h ^ bytes.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) &* 0x0000_0100_0000_01b3
            h ^= h >> 29
        }
        for i in (words * 8)..<bytes.count {
            h = (h ^ UInt64(bytes[i])) &* 0x0000_0100_0000_01b3
        }
        return h
    }

    public static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        bytes.withUnsafeBytes { fnv1a64($0) }
    }

    /// 16 lowercase hex digits, the id printed in logs and used in dump file names.
    public static func hex(_ value: UInt64) -> String {
        let s = String(value, radix: 16)
        return String(repeating: "0", count: 16 - s.count) + s
    }
}
