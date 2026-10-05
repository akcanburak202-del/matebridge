import Foundation

/// HEVC Annex-B helpers: VideoToolbox emits length-prefixed NAL units (HVCC); the clip files use start codes.
public enum AnnexB {
    public static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Converts length-prefixed NAL units (`lengthSize` bytes, big endian) to start-code form.
    /// Returns nil if a length runs past the end of the buffer.
    public static func fromLengthPrefixed(_ data: [UInt8], lengthSize: Int = 4) -> [UInt8]? {
        guard (1...4).contains(lengthSize) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(data.count + 16)
        var i = 0
        while i < data.count {
            guard i + lengthSize <= data.count else { return nil }
            var len = 0
            for k in 0..<lengthSize { len = (len << 8) | Int(data[i + k]) }
            i += lengthSize
            guard len > 0, i + len <= data.count else { return nil }
            out += startCode
            out += data[i..<(i + len)]
            i += len
        }
        return out
    }

    /// Prepends start codes to raw NAL units (e.g. VPS/SPS/PPS from the format description).
    public static func join(_ nals: [[UInt8]]) -> [UInt8] {
        nals.reduce(into: [UInt8]()) { $0 += startCode; $0 += $1 }
    }

    /// Splits an Annex-B stream (3- or 4-byte start codes) into NAL unit payloads (without start codes).
    public static func splitNALs(_ data: [UInt8]) -> [ArraySlice<UInt8>] {
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        let n = data.count
        while i + 2 < n {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                let code = (i > 0 && data[i - 1] == 0) ? i - 1 : i
                starts.append((code, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var nals: [ArraySlice<UInt8>] = []
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].code : n
            if end > s.payload { nals.append(data[s.payload..<end]) }
        }
        return nals
    }

    /// `nal_unit_type` of an HEVC NAL unit (first byte, bits 1...6).
    public static func nalType(_ nal: ArraySlice<UInt8>) -> Int {
        guard let b = nal.first else { return -1 }
        return Int((b >> 1) & 0x3F)
    }

    /// VCL NAL (types 0...31) whose `first_slice_segment_in_pic_flag` (first bit after the 2-byte header) is set.
    public static func isFirstSliceOfPicture(_ nal: ArraySlice<UInt8>) -> Bool {
        guard nal.count >= 3 else { return false }
        let t = nalType(nal)
        guard t < 32 else { return false }
        return nal[nal.startIndex + 2] & 0x80 != 0
    }

    /// Number of coded pictures (access units) in an Annex-B stream.
    public static func pictureCount(_ data: [UInt8]) -> Int {
        splitNALs(data).filter(isFirstSliceOfPicture).count
    }

    /// IRAP pictures (types 16...23) among the first slices.
    public static func irapCount(_ data: [UInt8]) -> Int {
        splitNALs(data).filter { isFirstSliceOfPicture($0) && (16...23).contains(nalType($0)) }.count
    }
}
