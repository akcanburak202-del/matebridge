// Copied from host-mac/Sources/MateBridgeCore/Video/AnnexB.swift (T-230: probes copy, never import, product code).

public enum AnnexB {
    public static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Converts length-prefixed NAL units (HVCC/AVCC sample data) to Annex-B. Returns nil if malformed.
    public static func convert(lengthPrefixed data: [UInt8], lengthSize: Int = 4) -> [UInt8]? {
        guard (1...4).contains(lengthSize) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(data.count + 16)
        var i = 0
        while i < data.count {
            guard i + lengthSize <= data.count else { return nil }
            var len = 0
            for _ in 0..<lengthSize { len = (len << 8) | Int(data[i]); i += 1 }
            guard len > 0, i + len <= data.count else { return nil }
            out += startCode
            out += data[i..<(i + len)]
            i += len
        }
        return out
    }

    /// Concatenates parameter sets (HEVC: VPS, SPS, PPS) with start codes.
    public static func parameterSets(_ sets: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for s in sets { out += startCode; out += s }
        return out
    }

    /// Splits an Annex-B stream into NAL units (without start codes).
    public static func nalUnits(_ data: [UInt8]) -> [[UInt8]] {
        var starts: [(payload: Int, code: Int)] = []
        var i = 0
        while i + 3 <= data.count {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                starts.append((i + 3, i)); i += 3
            } else { i += 1 }
        }
        var result: [[UInt8]] = []
        for (n, s) in starts.enumerated() {
            // The 4-byte start code's leading zero belongs to the next start code, not this NAL.
            let end = n + 1 < starts.count ? starts[n + 1].code : data.count
            var e = end
            if n + 1 < starts.count, e > s.payload, data[e - 1] == 0 { e -= 1 }
            result.append(Array(data[s.payload..<e]))
        }
        return result
    }

    /// HEVC NAL unit type (bits 1...6 of the first header byte).
    public static func hevcNALType(_ nal: [UInt8]) -> Int? {
        nal.first.map { Int(($0 >> 1) & 0x3F) }
    }
}
