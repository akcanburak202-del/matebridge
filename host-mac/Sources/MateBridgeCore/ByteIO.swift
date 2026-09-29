/// Little-endian appender.
struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) {
        for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) }
    }
    mutating func u64(_ v: UInt64) {
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
    }
    /// Non-finite values are never sent; they are replaced with 0.
    mutating func f32(_ v: Float) { u32((v.isFinite ? v : 0).bitPattern) }
    mutating func raw(_ v: [UInt8]) { bytes.append(contentsOf: v) }

    /// str8: length byte + UTF-8, at most 64 bytes, cut on a character boundary.
    mutating func str8(_ s: String) {
        var out: [UInt8] = []
        for ch in s {
            let enc = Array(String(ch).utf8)
            if out.count + enc.count > ProtocolConstants.maxStringBytes { break }
            out.append(contentsOf: enc)
        }
        u8(UInt8(out.count))
        raw(out)
    }
}

/// Little-endian bounds-checked reader over one payload.
struct ByteReader {
    let bytes: [UInt8]
    let type: UInt8
    private(set) var pos = 0

    init(_ bytes: [UInt8], type: UInt8) {
        self.bytes = bytes
        self.type = type
    }

    var remaining: Int { bytes.count - pos }

    private mutating func take(_ n: Int) throws -> Int {
        guard remaining >= n else { throw ProtocolError.payloadTooShort(type: type) }
        defer { pos += n }
        return pos
    }

    mutating func u8() throws -> UInt8 { bytes[try take(1)] }
    mutating func u16() throws -> UInt16 {
        let p = try take(2)
        return UInt16(bytes[p]) | UInt16(bytes[p + 1]) << 8
    }
    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    mutating func u32() throws -> UInt32 {
        let p = try take(4)
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[p + i]) << (8 * UInt32(i)) }
        return v
    }
    mutating func u64() throws -> UInt64 {
        let p = try take(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[p + i]) << (8 * UInt64(i)) }
        return v
    }
    mutating func f32(_ field: String) throws -> Float {
        let v = Float(bitPattern: try u32())
        guard v.isFinite else { throw ProtocolError.nonFiniteFloat(field) }
        return v
    }
    mutating func raw(_ n: Int) throws -> [UInt8] {
        let p = try take(n)
        return Array(bytes[p..<p + n])
    }
    mutating func skip(_ n: Int) throws { _ = try take(n) }
    mutating func str8() throws -> String {
        let n = Int(try u8())
        guard n <= ProtocolConstants.maxStringBytes else { throw ProtocolError.invalidField("str8 length") }
        return String(decoding: try raw(n), as: UTF8.self)
    }
}
