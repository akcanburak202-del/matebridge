import Foundation

/// The few SPS fields the clip check needs: profile, bit depth and the VUI colour description.
public struct HevcSPSInfo: Equatable, Sendable {
    public var profileIdc = 0
    public var chromaFormatIdc = 0
    public var bitDepthLuma = 0
    public var bitDepthChroma = 0
    public var width = 0
    public var height = 0
    /// VUI `video_full_range_flag` / colour description; nil when the VUI does not carry them.
    public var fullRange: Bool?
    public var colourPrimaries: Int?
    public var transfer: Int?
    public var matrix: Int?
}

/// Minimal HEVC SPS parser (H.265 7.3.2.2) up to the VUI colour description. Returns nil when the SPS uses a feature
/// this parser does not follow (explicit scaling list data) or is truncated. Test / verification code, not a general decoder.
public enum HevcSPS {
    /// Strips emulation prevention bytes (`00 00 03` -> `00 00`) from a NAL payload after its 2-byte header.
    public static func rbsp(_ nal: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(nal.count)
        var zeros = 0
        for b in nal.dropFirst(2) {
            if zeros >= 2 && b == 3 { zeros = 0; continue }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }

    struct Bits {
        let d: [UInt8]
        var pos = 0
        var failed = false
        init(_ d: [UInt8]) { self.d = d }
        mutating func u(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                let byte = pos >> 3
                guard byte < d.count else { failed = true; return 0 }
                v = (v << 1) | Int((d[byte] >> (7 - UInt8(pos & 7))) & 1)
                pos += 1
            }
            return v
        }
        mutating func flag() -> Bool { u(1) == 1 }
        mutating func ue() -> Int {
            var zeros = 0
            while !failed, u(1) == 0 { zeros += 1; if zeros > 31 { failed = true; return 0 } }
            return zeros == 0 ? 0 : (1 << zeros) - 1 + u(zeros)
        }
        mutating func skip(_ n: Int) { pos += n; if pos > d.count * 8 { failed = true } }
    }

    /// Parses an SPS NAL unit (payload without start code, including the 2-byte NAL header).
    public static func parse(_ nal: ArraySlice<UInt8>) -> HevcSPSInfo? {
        var r = Bits(rbsp(nal))
        var info = HevcSPSInfo()
        r.skip(4)                                   // sps_video_parameter_set_id
        let maxSubLayersMinus1 = r.u(3)
        r.skip(1)                                   // temporal_id_nesting
        // profile_tier_level
        r.skip(2 + 1)                               // profile_space, tier
        info.profileIdc = r.u(5)
        r.skip(32 + 4 + 43 + 1)                     // compat flags, progressive/interlaced/..., reserved, inbld
        r.skip(8)                                   // general_level_idc
        var subProfile: [Bool] = [], subLevel: [Bool] = []
        for _ in 0..<maxSubLayersMinus1 { subProfile.append(r.flag()); subLevel.append(r.flag()) }
        if maxSubLayersMinus1 > 0 { for _ in maxSubLayersMinus1..<8 { r.skip(2) } }
        for i in 0..<maxSubLayersMinus1 {
            if subProfile[i] { r.skip(88) }
            if subLevel[i] { r.skip(8) }
        }
        _ = r.ue()                                  // sps_seq_parameter_set_id
        info.chromaFormatIdc = r.ue()
        if info.chromaFormatIdc == 3 { r.skip(1) }
        info.width = r.ue()
        info.height = r.ue()
        if r.flag() { for _ in 0..<4 { _ = r.ue() } }   // conformance window
        info.bitDepthLuma = r.ue() + 8
        info.bitDepthChroma = r.ue() + 8
        let pocLsbBits = r.ue() + 4                 // log2_max_pic_order_cnt_lsb
        let orderingInfoPresent = r.flag()
        for _ in (orderingInfoPresent ? 0 : maxSubLayersMinus1)...maxSubLayersMinus1 { for _ in 0..<3 { _ = r.ue() } }
        for _ in 0..<6 { _ = r.ue() }               // cb / tb sizes and transform hierarchy depths
        if r.flag() {                               // scaling_list_enabled_flag (VideoToolbox sets it, default lists)
            if r.flag() { return nil }              // explicit scaling_list_data: not followed
        }
        r.skip(2)                                   // amp, sao
        if r.flag() { r.skip(4 + 4); _ = r.ue(); _ = r.ue(); r.skip(1) }   // pcm
        let numSets = r.ue()
        guard numSets <= 64 else { return nil }
        var numDeltaPocs: [Int] = []
        for idx in 0..<numSets {
            let inter = idx != 0 && r.flag()
            if inter {
                r.skip(1)                           // delta_rps_sign
                _ = r.ue()                          // abs_delta_rps_minus1
                var count = 0
                for _ in 0...numDeltaPocs[idx - 1] {
                    let used = r.flag()
                    let useDelta = used ? true : r.flag()
                    if used || useDelta { count += 1 }
                }
                numDeltaPocs.append(count)
            } else {
                let neg = r.ue(), pos = r.ue()
                guard neg <= 16, pos <= 16 else { return nil }
                for _ in 0..<(neg + pos) { _ = r.ue(); r.skip(1) }
                numDeltaPocs.append(neg + pos)
            }
            if r.failed { return nil }
        }
        if r.flag() {                               // long_term_ref_pics_present_flag
            let n = r.ue()
            guard n <= 32 else { return nil }
            for _ in 0..<n { r.skip(pocLsbBits + 1) }  // lt_ref_pic_poc_lsb_sps, used flag
        }
        r.skip(2)                                   // temporal_mvp, strong_intra_smoothing
        if r.failed { return nil }
        guard r.flag() else { return info }         // vui_parameters_present_flag
        if r.flag() { if r.u(8) == 255 { r.skip(32) } }   // aspect_ratio_info
        if r.flag() { r.skip(1) }                   // overscan
        if r.flag() {                               // video_signal_type_present_flag
            r.skip(3)
            info.fullRange = r.flag()
            if r.flag() {
                info.colourPrimaries = r.u(8)
                info.transfer = r.u(8)
                info.matrix = r.u(8)
            }
        }
        return r.failed ? nil : info
    }

    /// SEI payload types present in prefix SEI NAL units (type 39) of an Annex-B stream, first message of each NAL
    /// (VideoToolbox emits one message per NAL; a combined NAL would show only its first type).
    public static func seiPayloadTypes(_ nals: [ArraySlice<UInt8>]) -> Set<Int> {
        var out: Set<Int> = []
        for n in nals where AnnexB.nalType(n) == 39 {
            let b = Array(n.dropFirst(2))
            var i = 0, t = 0
            while i < b.count, b[i] == 0xFF { t += 255; i += 1 }
            if i < b.count { out.insert(t + Int(b[i])) }
        }
        return out
    }
}
