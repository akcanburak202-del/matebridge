import Foundation

/// HDR10 stream (decision 0032, PROTOCOL.md 0x03/0x05 host rules). Pure: no clock, no I/O.
///
/// The tablet asks with `STREAM_PREFS.dynamic_range = 1`. The host applies it when the stream codec is HEVC and the
/// HDR path has not failed in this process (`HDRFallback`); then the virtual display gets transfer function 1
/// (`VirtualDisplay`), ScreenCaptureKit captures 10-bit BT.2100 PQ, VideoToolbox encodes HEVC Main10 PQ with HDR10
/// static metadata, and `STREAM_CONFIG` carries 9/16/9/limited. Any ring that fails falls back to SDR.
public enum HDRPolicy {
    public enum Decision: Equatable, Sendable {
        /// SDR was asked for (or nothing).
        case sdr
        case hdr10
        /// HDR10 was asked for but is not applied.
        case fallback(HDRFallbackReason)

        /// The dynamic range the settings get.
        public var applied: DynamicRange { self == .hdr10 ? .hdr10 : .sdr }

        /// Why a request was not applied (nil for `.sdr` and `.hdr10`).
        public var reason: HDRFallbackReason? {
            if case .fallback(let r) = self { return r }
            return nil
        }
    }

    /// The decision for a request before any ring is tried: H.264 (`MATEBRIDGE_CODEC=h264`) has no Main10 PQ path
    /// here; `allowed` is false after a runtime HDR failure in this process.
    public static func decide(requested: DynamicRange, codec: Codec, allowed: Bool) -> Decision {
        guard requested == .hdr10 else { return .sdr }
        guard codec == .hevc else { return .fallback(.codecNotHEVC) }
        guard allowed else { return .fallback(.disabled) }
        return .hdr10
    }

    /// Encoder properties (the names `HEVCEncoder` logs in `encoder_set[…]`) whose refusal in an HDR10 session makes
    /// the stream fall back to SDR: without them the bitstream is not the HDR10 that `STREAM_CONFIG` announces.
    public static let encoderCriticalProperties = [
        "ProfileLevel", "ColorPrimaries", "TransferFunction", "YCbCrMatrix",
        "MasteringDisplayColorVolume", "ContentLightLevelInfo", "HDRMetadataInsertionMode",
    ]

    /// The first refused critical property among the encoder's `Name=<OSStatus>` failures, or nil.
    public static func refusedEncoderProperty(_ failures: [String]) -> String? {
        failures.first { f in encoderCriticalProperties.contains { f.hasPrefix($0 + "=") } }
    }
}

/// Why an HDR10 request runs as SDR (`ev=hdr_fallback reason=`, `ev=hdr_config reason=`).
public enum HDRFallbackReason: String, Equatable, Sendable {
    /// Policy: the stream codec is not HEVC (`MATEBRIDGE_CODEC=h264`).
    case codecNotHEVC = "codec_not_hevc"
    /// Policy: an earlier HDR failure switched HDR off for the rest of the process.
    case disabled
    /// Runtime: the virtual display could not be created with transfer function 1 (selector missing, nil mode, or
    /// `applySettings:` rejected it; detail = `VirtualDisplayTransfer.FallbackReason`).
    case displayRejected = "display_rejected"
    /// Runtime: ScreenCaptureKit did not start the HDR capture (not a missing display or display sleep).
    case captureFailed = "capture_failed"
    /// Runtime: VideoToolbox refused a Main10 / PQ / HDR metadata property (detail = `Name=<OSStatus>`).
    case encoderRejected = "encoder_rejected"

    /// A failure of a ring at pipeline start (as opposed to a policy decision).
    public var isRuntime: Bool { self == .displayRejected || self == .captureFailed || self == .encoderRejected }
}

/// One fallback to SDR when an HDR10 pipeline cannot be set up (`ev=hdr_fallback`). Like the game display fallback
/// (`GameDisplayFallback`, T-214) it is process-wide: a display, capture or encoder that refuses HDR once would refuse
/// it again, and a per-session retry would loop through display recreations on every reconnect.
public struct HDRFallback: Equatable, Sendable {
    public private(set) var failure: HDRFallbackReason?

    public init() {}

    /// HDR10 may be derived (`VideoSettings.applying(_:allowHDR:)`).
    public var allowsHDR: Bool { failure == nil }

    /// A pipeline failed to start. Returns true when the caller must re-apply the prefs without HDR: the pipeline ran
    /// HDR10 and the failure is one of the HDR rings (`reason` non-nil, runtime). The fallback settings are SDR,
    /// which never falls back again, so there is exactly one attempt.
    public mutating func startFailed(settings: VideoSettings, reason: HDRFallbackReason?) -> Bool {
        guard settings.dynamicRange == .hdr10, let reason, reason.isRuntime else { return false }
        failure = reason
        return true
    }

    /// Settings derived earlier (a session start waiting in the mailbox) re-checked against the current state: HDR10
    /// derived before HDR was switched off becomes SDR, with the same `prefs` re-applied without it. nil =
    /// `settings` are still valid.
    public func revalidated(_ settings: VideoSettings, base: VideoSettings, prefs: StreamPrefs?,
                            defaultRefreshHz: Int, allowGameDisplay: Bool) -> VideoSettings? {
        guard settings.dynamicRange == .hdr10, !allowsHDR else { return nil }
        guard let prefs else { return base }
        return base.applying(prefs, defaultRefreshHz: defaultRefreshHz, allowGameDisplay: allowGameDisplay,
                             allowHDR: false)
    }
}

/// HDR10 static metadata the encoder writes as SEI (`kVTCompressionPropertyKey_MasteringDisplayColorVolume`,
/// `…ContentLightLevelInfo`, `HDRMetadataInsertionMode = Auto`). Adapted from the T-226 probe
/// (`probes/hdr-probe`, `HDR10Static`), whose clip the tablet showed as HDR.
public struct HDR10Metadata: Equatable, Sendable {
    /// CIE 1931 xy chromaticity.
    public struct XY: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
    }

    public var red: XY
    public var green: XY
    public var blue: XY
    public var white: XY
    /// cd/m².
    public var maxMasteringNits: Double
    /// cd/m².
    public var minMasteringNits: Double
    public var maxCLL: UInt16
    public var maxFALL: UInt16

    public init(red: XY, green: XY, blue: XY, white: XY, maxMasteringNits: Double, minMasteringNits: Double,
                maxCLL: UInt16, maxFALL: UInt16) {
        self.red = red
        self.green = green
        self.blue = blue
        self.white = white
        self.maxMasteringNits = maxMasteringNits
        self.minMasteringNits = minMasteringNits
        self.maxCLL = maxCLL
        self.maxFALL = maxFALL
    }

    /// What the host sends (T-237 plan): Display P3 (D65) mastering display, 1000 / 0.0001 nits; MaxCLL 1000,
    /// MaxFALL 400. The Mac's HDR virtual display has ~5x EDR headroom over an SDR white of ~140-203 nits (peak
    /// ~700-1000 nits) in the P3 gamut; real-time content has no measured light level, so the mastering peak is the
    /// safe upper bound for MaxCLL and 400 a common frame average for games. The tablet (500 nits) tone-maps against
    /// these values; they may be tuned after the device test.
    public static let host = HDR10Metadata(
        red: XY(0.680, 0.320), green: XY(0.265, 0.690), blue: XY(0.150, 0.060), white: XY(0.3127, 0.3290),
        maxMasteringNits: 1000, minMasteringNits: 0.0001, maxCLL: 1000, maxFALL: 400)

    private static func chroma(_ v: Double) -> UInt16 { UInt16((v / 0.00002).rounded()) }

    /// HEVC SEI `mastering_display_colour_volume` payload: 24 bytes big-endian, primaries in G, B, R order, then the
    /// white point (0.00002 units), then max and min luminance (0.0001 cd/m² units).
    public var mdcvSEI: [UInt8] {
        var d: [UInt8] = []
        func u16(_ v: UInt16) { d += [UInt8(v >> 8), UInt8(v & 0xff)] }
        func u32(_ v: UInt32) { for s: UInt32 in [24, 16, 8, 0] { d.append(UInt8((v >> s) & 0xff)) } }
        for p in [green, blue, red] {
            u16(Self.chroma(p.x))
            u16(Self.chroma(p.y))
        }
        u16(Self.chroma(white.x))
        u16(Self.chroma(white.y))
        u32(UInt32((maxMasteringNits * 10_000).rounded()))
        u32(UInt32((minMasteringNits * 10_000).rounded()))
        return d
    }

    /// HEVC SEI `content_light_level_info` payload: MaxCLL, MaxFALL as big-endian u16.
    public var cllSEI: [UInt8] {
        [UInt8(maxCLL >> 8), UInt8(maxCLL & 0xff), UInt8(maxFALL >> 8), UInt8(maxFALL & 0xff)]
    }
}

/// Session colour tags per dynamic range (T-113 retag; the raw CoreVideo string values). SDR is today's
/// `ITU_R_709_2` / `IEC_sRGB` / `ITU_R_709_2`; HDR10 is `ITU_R_2020` / `SMPTE_ST_2084_PQ` / `ITU_R_2020`, which is
/// also what ScreenCaptureKit's BT.2100 PQ capture carries.
public enum SessionColorTags {
    public static let sdr = ColorTags(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2")
    public static let hdr10 = ColorTags(primaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", matrix: "ITU_R_2020")

    public static func tags(for range: DynamicRange) -> ColorTags { range == .hdr10 ? hdr10 : sdr }
}

/// `ev=hdr_config` / `ev=hdr_fallback` fields (docs/LOGGING.md).
public enum HDRLog {
    /// `requested=<0|1> applied=<0|1> [reason=<r>] primaries=<n> transfer=<n> matrix=<n> full_range=<0|1>
    /// display_transfer=<n> encoded=<w>x<h> fps=<n>`: one line per configured pipeline. `requested` is the tablet's
    /// normalized `dynamic_range`, `applied` the settings' (= what `STREAM_CONFIG` reports), `reason` why a request
    /// runs as SDR, `display_transfer` the virtual display's requested transfer function.
    public static func configFields(requested: DynamicRange, settings: VideoSettings,
                                    reason: HDRFallbackReason?) -> String {
        let c = settings.streamConfig(configID: 0)
        var f = "requested=\(requested.rawValue) applied=\(settings.dynamicRange.rawValue)"
        if let reason, requested == .hdr10, settings.dynamicRange == .sdr { f += " reason=\(reason.rawValue)" }
        f += " primaries=\(c.colorPrimaries) transfer=\(c.transfer) matrix=\(c.matrix) full_range=\(c.fullRange ? 1 : 0)"
        f += " display_transfer=\(settings.displayTransfer.requested)"
        f += " encoded=\(settings.encodedWidthPx)x\(settings.encodedHeightPx) fps=\(settings.fps)"
        return f
    }

    /// `reason=<r> [detail=<token>] config_id=<n> display=<mode> encoded=<w>x<h>`: the HDR path failed and the prefs
    /// were re-applied as SDR under a new `config_id`. `detail` is made log-safe (no spaces, `=` or `;`, ≤ 64 chars).
    public static func fallbackFields(reason: HDRFallbackReason, detail: String?, configID: UInt16,
                                      settings: VideoSettings) -> String {
        var f = "reason=\(reason.rawValue)"
        if let detail, !detail.isEmpty { f += " detail=\(StreamProfileLog.value(detail))" }
        f += " config_id=\(configID) display=\(settings.displayModeText)"
        f += " encoded=\(settings.encodedWidthPx)x\(settings.encodedHeightPx)"
        return f
    }
}
