/// Minimal HEVC SPS reader: extracts the VUI signal-type fields so the tools can verify what the
/// encoder actually wrote (decoders follow the bitstream, not container hints).
public struct HEVCVUIColor: Equatable, Sendable {
    public var fullRange: Bool
    /// H.273 codes; 2 (unspecified) when `colour_description_present_flag` is 0.
    public var colourPrimaries: UInt8
    public var transferCharacteristics: UInt8
    public var matrixCoefficients: UInt8
    public var colourDescriptionPresent: Bool
}

public enum HEVCSPS {
    /// Parses VUI colour info from an SPS NAL unit (with its 2-byte header, without start code).
    /// Returns nil if this is not an SPS, has no VUI signal-type info, or parsing fails.
    public static func vuiColor(sps nal: [UInt8]) -> HEVCVUIColor? {
        guard AnnexB.hevcNALType(nal) == 33, nal.count > 3 else { return nil }
        var r = BitReader(unescape(Array(nal[2...])))
        return try? parse(&r)
    }

    /// Removes emulation-prevention bytes (00 00 03 -> 00 00).
    static func unescape(_ d: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(d.count)
        var zeros = 0
        for b in d {
            if zeros >= 2, b == 3 { zeros = 0; continue }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }

    struct Fail: Error {}

    struct BitReader {
        let d: [UInt8]
        var pos = 0
        init(_ d: [UInt8]) { self.d = d }
        mutating func bit() throws -> Int {
            guard pos < d.count * 8 else { throw Fail() }
            let v = Int(d[pos >> 3] >> (7 - UInt8(pos & 7))) & 1
            pos += 1
            return v
        }
        mutating func bits(_ n: Int) throws -> Int {
            var v = 0
            for _ in 0..<n { v = (v << 1) | (try bit()) }
            return v
        }
        mutating func skip(_ n: Int) throws { for _ in 0..<n { _ = try bit() } }
        mutating func ue() throws -> Int {
            var zeros = 0
            while try bit() == 0 { zeros += 1; if zeros > 31 { throw Fail() } }
            return (1 << zeros) - 1 + (try bits(zeros))
        }
        mutating func se() throws -> Int {
            let k = try ue()
            return k & 1 == 1 ? (k + 1) / 2 : -(k / 2)
        }
    }

    private static func profileTierLevel(_ r: inout BitReader, maxSubLayersMinus1: Int) throws {
        try r.skip(96)  // general profile 88 bits (2+1+5, 32 compat flags, 48 flag/reserved bits) + level_idc 8
        var profilePresent: [Bool] = [], levelPresent: [Bool] = []
        for _ in 0..<maxSubLayersMinus1 {
            profilePresent.append(try r.bit() == 1)
            levelPresent.append(try r.bit() == 1)
        }
        if maxSubLayersMinus1 > 0 { try r.skip(2 * (8 - maxSubLayersMinus1)) }
        for i in 0..<maxSubLayersMinus1 {
            if profilePresent[i] { try r.skip(88) }
            if levelPresent[i] { try r.skip(8) }
        }
    }

    private static func scalingListData(_ r: inout BitReader) throws {
        for sizeId in 0..<4 {
            var matrixId = 0
            while matrixId < 6 {
                if try r.bit() == 0 {
                    _ = try r.ue()
                } else {
                    let coefNum = min(64, 1 << (4 + (sizeId << 1)))
                    if sizeId > 1 { _ = try r.se() }
                    for _ in 0..<coefNum { _ = try r.se() }
                }
                matrixId += sizeId == 3 ? 3 : 1
            }
        }
    }

    private struct RPS { var s0: [Int] = []; var s1: [Int] = [] }

    private static func stRefPicSet(_ r: inout BitReader, idx: Int, sets: [RPS]) throws -> RPS {
        var inter = false
        if idx != 0 { inter = try r.bit() == 1 }
        var out = RPS()
        if inter {
            let sign = try r.bit()
            let absDelta = try r.ue() + 1
            let deltaRps = (1 - 2 * sign) * absDelta
            let ref = sets[idx - 1]  // in an SPS delta_idx is always 1
            let n = ref.s0.count + ref.s1.count
            var used = [Bool](repeating: false, count: n + 1)
            var useDelta = [Bool](repeating: true, count: n + 1)
            for j in 0...n {
                used[j] = try r.bit() == 1
                if !used[j] { useDelta[j] = try r.bit() == 1 }
            }
            let nNeg = ref.s0.count, nPos = ref.s1.count
            // Equations 7-61 / 7-62.
            for j in stride(from: nPos - 1, through: 0, by: -1) {
                let d = ref.s1[j] + deltaRps
                if d < 0, useDelta[nNeg + j] { out.s0.append(d) }
            }
            if deltaRps < 0, useDelta[n] { out.s0.append(deltaRps) }
            for j in 0..<nNeg {
                let d = ref.s0[j] + deltaRps
                if d < 0, useDelta[j] { out.s0.append(d) }
            }
            for j in stride(from: nNeg - 1, through: 0, by: -1) {
                let d = ref.s0[j] + deltaRps
                if d > 0, useDelta[j] { out.s1.append(d) }
            }
            if deltaRps > 0, useDelta[n] { out.s1.append(deltaRps) }
            for j in 0..<nPos {
                let d = ref.s1[j] + deltaRps
                if d > 0, useDelta[nNeg + j] { out.s1.append(d) }
            }
        } else {
            let nNeg = try r.ue(), nPos = try r.ue()
            guard nNeg <= 16, nPos <= 16 else { throw Fail() }
            var poc = 0
            for _ in 0..<nNeg { poc -= try r.ue() + 1; out.s0.append(poc); try r.skip(1) }
            poc = 0
            for _ in 0..<nPos { poc += try r.ue() + 1; out.s1.append(poc); try r.skip(1) }
        }
        return out
    }

    private static func parse(_ r: inout BitReader) throws -> HEVCVUIColor? {
        try r.skip(4)  // vps id
        let maxSub = try r.bits(3)
        try r.skip(1)
        try profileTierLevel(&r, maxSubLayersMinus1: maxSub)
        _ = try r.ue()  // sps id
        let chroma = try r.ue()
        if chroma == 3 { try r.skip(1) }
        _ = try r.ue(); _ = try r.ue()  // width, height
        if try r.bit() == 1 { for _ in 0..<4 { _ = try r.ue() } }  // conformance window
        _ = try r.ue(); _ = try r.ue()  // bit depths
        let log2MaxPocLsb = try r.ue() + 4
        let subLayerOrdering = try r.bit() == 1
        for _ in (subLayerOrdering ? 0 : maxSub)...maxSub { _ = try r.ue(); _ = try r.ue(); _ = try r.ue() }
        for _ in 0..<6 { _ = try r.ue() }  // cb/tb sizes and hierarchy depths
        if try r.bit() == 1, try r.bit() == 1 { try scalingListData(&r) }
        try r.skip(2)  // amp, sao
        if try r.bit() == 1 {  // pcm
            try r.skip(8); _ = try r.ue(); _ = try r.ue(); try r.skip(1)
        }
        let numSets = try r.ue()
        guard numSets <= 64 else { throw Fail() }
        var sets: [RPS] = []
        for i in 0..<numSets { sets.append(try stRefPicSet(&r, idx: i, sets: sets)) }
        if try r.bit() == 1 {  // long-term ref pics
            let n = try r.ue()
            guard n <= 32 else { throw Fail() }
            for _ in 0..<n { try r.skip(log2MaxPocLsb + 1) }
        }
        try r.skip(2)  // temporal mvp, strong intra smoothing
        guard try r.bit() == 1 else { return nil }  // vui_parameters_present_flag
        if try r.bit() == 1 {  // aspect ratio
            if try r.bits(8) == 255 { try r.skip(32) }
        }
        if try r.bit() == 1 { try r.skip(1) }  // overscan
        if try r.bit() == 1 {  // video_signal_type_present_flag
            try r.skip(3)  // video_format
            let full = try r.bit() == 1
            if try r.bit() == 1 {
                return HEVCVUIColor(fullRange: full, colourPrimaries: UInt8(try r.bits(8)),
                                    transferCharacteristics: UInt8(try r.bits(8)),
                                    matrixCoefficients: UInt8(try r.bits(8)), colourDescriptionPresent: true)
            }
            return HEVCVUIColor(fullRange: full, colourPrimaries: 2, transferCharacteristics: 2,
                                matrixCoefficients: 2, colourDescriptionPresent: false)
        }
        return nil
    }
}
