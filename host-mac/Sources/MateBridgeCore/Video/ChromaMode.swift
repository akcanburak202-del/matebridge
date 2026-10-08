import Foundation

/// T-235 developer knob `MATEBRIDGE_CHROMA` (decision 0026 class, research `docs/research/2026-10-05-yuv444.md` §3b,
/// card A): how the host turns captured RGB into the encoder's chroma format.
///
/// - `420` (default): today's path, bit for bit. ScreenCaptureKit delivers full-range 4:2:0 (`420f`) and VideoToolbox
///   encodes it as is.
/// - `sharp_nearest`: ScreenCaptureKit delivers `BGRA`. A Metal pass produces `420f` with 2x2 box chroma and a
///   per-pixel luma adjustment (`SharpYUV`) that assumes the decoder upsamples chroma by nearest neighbour.
/// - `packed444`: decision 0034, see below.
///
/// T-302 removed `444` (the undocumented `HEVC_Main444_AutoLevel` probe, no output on the tablet) and
/// `sharp_bilinear` (decision 0033 chose nearest).
public enum ChromaMode: String, Equatable, Sendable, CaseIterable {
    case yuv420 = "420"
    case sharpNearest = "sharp_nearest"
    /// Decision 0034 (T-258): packed full colour. `BGRA` capture, a Metal pass packs the AVC444v2 main and auxiliary
    /// `420f` pictures, a second VideoToolbox session encodes the auxiliary one. Only with the session's consent
    /// (`VideoSettings.packedChroma`); otherwise `sharp_nearest` runs.
    case packed444

    /// The decoder upsampling the luma adjustment assumes; nil when the mode has no Metal pass.
    public var sharpUpsample: SharpYUV.Upsample? {
        switch self {
        case .sharpNearest: return .nearest
        case .yuv420, .packed444: return nil
        }
    }

    /// What ScreenCaptureKit must deliver for this mode.
    public var captureFormat: ChromaCaptureFormat {
        self == .yuv420 ? .yuv420FullRange : .bgra
    }

    /// The `chroma_format_idc` the SPS should carry (always 4:2:0: the packed full colour rides two 4:2:0 pictures).
    public var expectedChromaFormatIdc: Int { 1 }
}

/// ScreenCaptureKit pixel format (the host maps it to the CoreVideo constant).
public enum ChromaCaptureFormat: Equatable, Sendable {
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (`420f`): today's capture format.
    case yuv420FullRange
    /// `kCVPixelFormatType_32BGRA`.
    case bgra
}

/// The parsed `MATEBRIDGE_CHROMA` value.
public struct ChromaKnob: Equatable, Sendable {
    public static let envKey = "MATEBRIDGE_CHROMA"

    public let requested: ChromaMode
    /// The variable is present and not empty (also when invalid). It then wins over the tablet's `STREAM_PREFS.chroma`
    /// (T-240, `ChromaPolicy`). The `encoder_config` `chroma=` field appears only then; `chroma_stats` also while the
    /// sharp path runs (`ChromaDecision.statsEnabled`).
    public let isSet: Bool
    /// Set to something other than a known value (treated as `420`; includes the removed `444` and `sharp_bilinear`).
    public let invalid: Bool

    public init(requested: ChromaMode, isSet: Bool, invalid: Bool) {
        self.requested = requested
        self.isSet = isSet
        self.invalid = invalid
    }

    public static let unset = ChromaKnob(requested: .yuv420, isSet: false, invalid: false)

    /// Trimmed, case-insensitive; nil or empty is `unset`, an unknown value is `420` marked `invalid`.
    public static func parse(_ raw: String?) -> ChromaKnob {
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if t.isEmpty { return .unset }
        guard let mode = ChromaMode(rawValue: t) else { return ChromaKnob(requested: .yuv420, isSet: true, invalid: true) }
        return ChromaKnob(requested: mode, isSet: true, invalid: false)
    }

    public static func parse(env: [String: String]) -> ChromaKnob { parse(env[envKey]) }
}

/// Why the requested mode was not applied (the host uses `420` instead).
public enum ChromaFallbackReason: String, Equatable, Sendable {
    /// The Metal pass could not be set up (no device, or the kernel did not compile).
    case metalUnavailable = "metal_unavailable"
    /// T-237: the stream is HDR10 (decision 0032). HDR wins: x420 PQ capture and HEVC Main10, the knob is ignored.
    case hdr
    /// T-258: `packed444` requested (knob) but the session did not grant it (no bit11, no `chroma = 2` in this session,
    /// stream mode outside Günlük 60, or a runtime fallback): the sharp path runs instead.
    case fullChromaDenied = "full_chroma_denied"
    /// T-258: `packed444` was granted for the session but fell back at runtime (`ev=chroma_fallback`): normal 4:2:0.
    case fullChromaFallback = "full_chroma_fallback"
}

/// Where the requested chroma mode came from (`ev=chroma_config source=`, T-240).
public enum ChromaSource: String, Equatable, Sendable {
    /// `MATEBRIDGE_CHROMA` is set (developer knob, wins over the tablet; an invalid value counts as set: `420`).
    case env
    /// The tablet's `STREAM_PREFS.chroma = 1` (decision 0033): `sharp_nearest`.
    case prefs
    /// Neither: today's `420` path.
    case `default`
}

/// The requested and the applied chroma mode of one encoder session.
public struct ChromaDecision: Equatable, Sendable {
    public let knob: ChromaKnob
    public let source: ChromaSource
    public let requested: ChromaMode
    public let applied: ChromaMode
    public let reason: ChromaFallbackReason?

    public init(knob: ChromaKnob, source: ChromaSource, requested: ChromaMode, applied: ChromaMode,
                reason: ChromaFallbackReason?) {
        self.knob = knob
        self.source = source
        self.requested = requested
        self.applied = applied
        self.reason = reason
    }

    /// A knob-only decision (no tablet preference): source `env` when the knob is set, `default` otherwise.
    public init(knob: ChromaKnob, applied: ChromaMode, reason: ChromaFallbackReason?) {
        self.init(knob: knob, source: knob.isSet ? .env : .default, requested: knob.requested, applied: applied,
                  reason: reason)
    }

    /// The same request falling back to `420` for `reason`.
    public func fallingBack(_ reason: ChromaFallbackReason) -> ChromaDecision {
        ChromaDecision(knob: knob, source: source, requested: requested, applied: .yuv420, reason: reason)
    }

    /// Whether `video ev=chroma_stats` is written: while the developer knob is set (T-235, any value, so `420` gives
    /// a baseline) or the sharp path runs. `ev=chroma_config` is written for every session (T-240).
    public var statsEnabled: Bool { knob.isSet || applied.sharpUpsample != nil || applied == .packed444 }
}

public enum ChromaPolicy {
    /// The tablet's choice maps to T-235's best-rated mode (decision 0033).
    public static let sharpPreferenceMode = ChromaMode.sharpNearest

    /// The mode to apply before any session exists. Input priority (T-240): `MATEBRIDGE_CHROMA` (set, also invalid) >
    /// `preference` (`STREAM_PREFS.chroma = 1` -> `sharp_nearest`) > `420`. The sharp mode and `420` work with every
    /// codec (their encoder input stays `420f`). An
    /// HDR10 stream (T-237, decision 0032) ignores every request: applied `420` (the 10-bit PQ 4:2:0 path), logged
    /// with `reason=hdr` unless nothing was requested. Without a preference SDR resolves exactly as in T-235.
    public static func resolve(knob: ChromaKnob, preference: ChromaPreference = .normal, dynamicRange: DynamicRange = .sdr,
                               packedChroma: Bool = false, packedFellBack: Bool = false) -> ChromaDecision {
        let source: ChromaSource = knob.isSet ? .env : (preference == .normal ? .default : .prefs)
        let requested: ChromaMode = switch source {
        case .env: knob.requested
        case .prefs: preference == .full ? .packed444 : sharpPreferenceMode
        case .default: .yuv420
        }
        func decision(_ applied: ChromaMode, _ reason: ChromaFallbackReason?) -> ChromaDecision {
            ChromaDecision(knob: knob, source: source, requested: requested, applied: applied, reason: reason)
        }
        if dynamicRange == .hdr10 { return decision(.yuv420, source == .default ? nil : .hdr) }
        // T-258: packed full colour only with the session's consent (`VideoSettings.packedChroma`); else sharp.
        if requested == .packed444, packedFellBack { return decision(.yuv420, .fullChromaFallback) }
        if requested == .packed444 {
            return packedChroma ? decision(.packed444, nil) : decision(sharpPreferenceMode, .fullChromaDenied)
        }
        return decision(requested, nil)
    }
}

/// What the encoder's SPS says about chroma, for `ev=chroma_config` (nil fields: not parsed).
public struct ChromaBitstreamInfo: Equatable, Sendable {
    public var chromaFormatIdc: Int?
    public var profileIdc: Int?
    public var vuiFullRange: Bool?
    /// `chroma_sample_loc_type_top_field` when the VUI carries `chroma_loc_info`; nil when absent.
    public var chromaSampleLocTop: Int?
    /// The SPS was parsed (so a nil `chromaSampleLocTop` means "absent", not "unknown").
    public var parsed: Bool

    public init(chromaFormatIdc: Int? = nil, profileIdc: Int? = nil, vuiFullRange: Bool? = nil,
                chromaSampleLocTop: Int? = nil, parsed: Bool = false) {
        self.chromaFormatIdc = chromaFormatIdc
        self.profileIdc = profileIdc
        self.vuiFullRange = vuiFullRange
        self.chromaSampleLocTop = chromaSampleLocTop
        self.parsed = parsed
    }
}

/// `encoder ev=chroma_config` (T-235, T-240): one line per parameter-set announcement of every session.
public enum ChromaConfigLog {
    public static let event = "chroma_config"

    /// `requested=<m> applied=<m> [reason=<r>|invalid_value] source=env|prefs|default chroma_format_idc=<n|unknown>
    /// profile_idc=<n|unknown> vui_full_range=<0|1|unknown> chroma_loc=<n|unset|unknown> [mismatch=1]`. `W` when the
    /// request was not applied, the knob was invalid, or the SPS chroma format differs from the applied mode's (e.g.
    /// VideoToolbox silently encoding 4:2:0); `I` otherwise.
    public static func line(_ d: ChromaDecision, _ info: ChromaBitstreamInfo,
                            view: String? = nil) -> (level: LogLevel, fields: String) {
        var f = "requested=\(d.requested.rawValue) applied=\(d.applied.rawValue)"
        if let r = d.reason {
            f += " reason=\(r.rawValue)"
        } else if d.knob.invalid {
            f += " reason=invalid_value"
        }
        f += " source=\(d.source.rawValue)"
        f += " chroma_format_idc=\(info.chromaFormatIdc.map(String.init) ?? "unknown")"
        f += " profile_idc=\(info.profileIdc.map(String.init) ?? "unknown")"
        f += " vui_full_range=\(info.vuiFullRange.map { $0 ? "1" : "0" } ?? "unknown")"
        let loc = info.chromaSampleLocTop.map(String.init) ?? (info.parsed ? "unset" : "unknown")
        f += " chroma_loc=\(loc)"
        // T-258: `layout=packed444` (and which of the two streams this SPS belongs to).
        if d.applied == .packed444 { f += " layout=packed444 view=\(view ?? "main")" }
        let mismatch = info.chromaFormatIdc.map { $0 != d.applied.expectedChromaFormatIdc } ?? false
        if mismatch { f += " mismatch=1" }
        let warn = d.reason != nil || d.knob.invalid || mismatch
        return (warn ? .warning : .info, f)
    }
}

/// `video ev=chroma_stats` (T-235): a 10 s window of the chroma path's timings while `ChromaDecision.statsEnabled`
/// (`MATEBRIDGE_CHROMA` set, or the sharp path chosen by the tablet).
/// Samples are bounded (`maxSamples` per series; later samples in a window are counted, not kept).
public struct ChromaStatsWindow: Sendable {
    public static let windowUs: UInt64 = 10_000_000
    public static let maxSamples = 4096

    public let mode: ChromaMode
    private var startUs: UInt64
    private var conversionWallUs: [UInt64] = []
    private var conversionGpuUs: [UInt64] = []
    private var captureToEncodeUs: [UInt64] = []
    private var encoded = 0
    private var conversions = 0
    private var conversionFailures = 0

    public init(mode: ChromaMode, startUs: UInt64) {
        self.mode = mode
        self.startUs = startUs
    }

    /// One Metal pass: wall time (submit to completion, on the encoder's owner queue) and GPU execution time.
    public mutating func recordConversion(wallUs: UInt64, gpuUs: UInt64) {
        conversions += 1
        if conversionWallUs.count < Self.maxSamples { conversionWallUs.append(wallUs) }
        if conversionGpuUs.count < Self.maxSamples { conversionGpuUs.append(gpuUs) }
    }

    /// The Metal pass could not run (pool exhausted, GPU error): the frame went to VideoToolbox as `BGRA`.
    public mutating func recordConversionFailure() { conversionFailures += 1 }

    /// One encoder output: ScreenCaptureKit callback to encoder output.
    public mutating func recordEncoded(captureToEncodeUs us: UInt64) {
        encoded += 1
        if captureToEncodeUs.count < Self.maxSamples { captureToEncodeUs.append(us) }
    }

    /// The line's fields once `windowUs` has passed since the window started (then a new window starts at `nowUs`);
    /// nil before that.
    /// `mode=<m> frames=<n> conv_ms_p50_95=<a>/<b>|- gpu_ms_p50_95=<a>/<b>|- cap_enc_ms_p50_95=<a>/<b>|- conv=<n>
    /// conv_fail=<n>`; a `-` series had no samples (no Metal pass in `420`).
    public mutating func take(nowUs: UInt64) -> String? {
        guard nowUs >= startUs, nowUs - startUs >= Self.windowUs else { return nil }
        let f = "mode=\(mode.rawValue) frames=\(encoded) conv_ms_p50_95=\(Self.pair(conversionWallUs)) "
            + "gpu_ms_p50_95=\(Self.pair(conversionGpuUs)) cap_enc_ms_p50_95=\(Self.pair(captureToEncodeUs)) "
            + "conv=\(conversions) conv_fail=\(conversionFailures)"
        self = ChromaStatsWindow(mode: mode, startUs: nowUs)
        return f
    }

    static func pair(_ s: [UInt64]) -> String {
        guard !s.isEmpty else { return "-" }
        return ms(CadenceWindow.percentile(s, 50)) + "/" + ms(CadenceWindow.percentile(s, 95))
    }

    static func ms(_ us: UInt64) -> String { String(format: "%.2f", Double(us) / 1000) }
}

extension ChromaBitstreamInfo {
    /// The chroma fields of a session's parameter sets (without start codes): HEVC from the SPS (profile, chroma
    /// format, VUI range and chroma location), H.264 profile and chroma format only.
    public static func parse(parameterSets sets: [[UInt8]], codec: Codec) -> ChromaBitstreamInfo {
        for nal in sets {
            switch codec {
            case .hevc:
                if let s = HEVCSPS.summary(sps: nal) {
                    return ChromaBitstreamInfo(chromaFormatIdc: s.chromaFormatIdc, profileIdc: s.generalProfileIdc,
                                               vuiFullRange: s.vuiColor?.fullRange,
                                               chromaSampleLocTop: s.chromaSampleLocTop, parsed: true)
                }
            case .h264:
                if let p = H264SPS.profileIdc(nal) {
                    return ChromaBitstreamInfo(chromaFormatIdc: H264SPS.chromaFormatIdc(nal), profileIdc: Int(p))
                }
            }
        }
        return ChromaBitstreamInfo()
    }
}

extension H264SPS {
    /// Profiles whose SPS carries `chroma_format_idc` (H.264 7.3.2.1.1); the others are 4:2:0.
    static let chromaFormatProfiles: Set<UInt8> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]

    /// chroma_format_idc of an SPS NAL unit (with its 1-byte header, without start code); nil if unreadable.
    public static func chromaFormatIdc(_ nal: [UInt8]) -> Int? {
        guard isSPS(nal), nal.count > 4 else { return nil }
        let d = HEVCSPS.unescape(Array(nal[1...]))
        guard d.count > 3 else { return nil }
        guard chromaFormatProfiles.contains(d[0]) else { return 1 }
        var r = HEVCSPS.BitReader(Array(d[3...]))
        guard (try? r.ue()) != nil, let chroma = try? r.ue() else { return nil }  // seq_parameter_set_id, chroma
        return chroma
    }
}
