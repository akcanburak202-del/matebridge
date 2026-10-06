import Foundation

extension Codec {
    /// Name used in logs (`codec=h264|hevc`).
    public var logName: String {
        switch self {
        case .h264: return "h264"
        case .hevc: return "hevc"
        }
    }
}

/// Debug bitrate step for the live-bitrate device check (T-177): `MATEBRIDGE_BITRATE_STEP=60000,15000,60000@5s`.
/// Every `periodMs` the encoder's live setter is called with the next value (kbps), cycling through the list, starting
/// one period after the encoder starts. Default off. Closed by T-196 (adopted into the adaptation controller), or
/// removed after the T-127 Wi-Fi re-measurement if no adaptation card needs it (decision 0026 §2).
public struct BitrateStepKnob: Equatable, Sendable {
    public static let periodRangeMs: ClosedRange<Int> = 100...600_000
    public static let maxValues = 16

    public var valuesKbps: [Int]
    public var periodMs: Int

    public init(valuesKbps: [Int], periodMs: Int) {
        self.valuesKbps = valuesKbps
        self.periodMs = periodMs
    }

    /// `<kbps>[,<kbps>...]@<n>s|<n>ms`: 1...16 values, each a whole number in the user bitrate range
    /// (`VideoSettings.userBitrateRangeKbps`), period 100 ms...600 s. Anything else (or nil) is nil: off.
    public static func parse(_ text: String?) -> BitrateStepKnob? {
        guard let t = text?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        let parts = t.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        var values: [Int] = []
        for item in parts[0].split(separator: ",", omittingEmptySubsequences: false) {
            guard let v = Int(item.trimmingCharacters(in: .whitespaces)),
                  VideoSettings.userBitrateRangeKbps.contains(v) else { return nil }
            values.append(v)
        }
        guard (1...maxValues).contains(values.count) else { return nil }
        let p = parts[1].trimmingCharacters(in: .whitespaces)
        let ms: Int?
        if p.hasSuffix("ms") {
            ms = Int(p.dropLast(2))
        } else if p.hasSuffix("s") {
            ms = Int(p.dropLast()).flatMap { $0.multipliedReportingOverflow(by: 1000).overflow ? nil : $0 * 1000 }
        } else {
            ms = nil
        }
        guard let ms, periodRangeMs.contains(ms) else { return nil }
        return BitrateStepKnob(valuesKbps: values, periodMs: ms)
    }

    /// The value for the `n`-th tick (0-based), cycling.
    public func value(atTick n: Int) -> Int { valuesKbps[((n % valuesKbps.count) + valuesKbps.count) % valuesKbps.count] }

    /// Log value: `60000,15000,60000@5000ms`.
    public var logValue: String { valuesKbps.map(String.init).joined(separator: ",") + "@\(periodMs)ms" }
}

/// Encoder-level experiment knobs (T-086). Every default is the behaviour before T-086.
///
/// T-204 (decision 0026) retired `MATEBRIDGE_PRIO_SPEED`, `MATEBRIDGE_H264_PROFILE`, `MATEBRIDGE_IDLE_REFRESH_*` and
/// `MATEBRIDGE_INPUT_RETAG`: speed priority, the H.264 High profile and the input retag are now constants in the
/// encoder, and the idle quality refresh is gone.
public struct EncoderKnobs: Equatable, Sendable {
    /// `kVTCompressionPropertyKey_Quality` (0...1). When set, `AverageBitRate` is not set (the `DataRateLimits`
    /// cap stays).
    public var quality: Double?
    /// Debug bitrate step timer (T-177, `MATEBRIDGE_BITRATE_STEP`); nil = off.
    public var bitrateStep: BitrateStepKnob?
    /// Short `DataRateLimits` window in ms next to the 1 s pair (T-177 diagnostics, `MATEBRIDGE_RATE_WINDOW_MS`);
    /// nil = off (only the 1 s pair). Closed by T-196, or removed after T-127 (decision 0026 §2).
    public var rateWindowMs: Int?
    /// T-235 `MATEBRIDGE_CHROMA` (`ChromaKnob`); unset = today's 4:2:0 path.
    public var chroma: ChromaKnob = .unset

    public static let rateWindowRangeMs: ClosedRange<Int> = 10...999

    public init() {}

    /// `MATEBRIDGE_QUALITY=0.0..1.0` (anything else: unset), `MATEBRIDGE_BITRATE_STEP` (`BitrateStepKnob.parse`),
    /// `MATEBRIDGE_RATE_WINDOW_MS` (10...999, anything else: off), `MATEBRIDGE_CHROMA` (`ChromaKnob.parse`).
    public static func parse(_ env: [String: String]) -> EncoderKnobs {
        var k = EncoderKnobs()
        k.quality = parseQuality(env["MATEBRIDGE_QUALITY"])
        k.bitrateStep = BitrateStepKnob.parse(env["MATEBRIDGE_BITRATE_STEP"])
        if let v = int(env["MATEBRIDGE_RATE_WINDOW_MS"]), rateWindowRangeMs.contains(v) { k.rateWindowMs = v }
        k.chroma = ChromaKnob.parse(env: env)
        return k
    }

    /// 0.0...1.0 (finite); anything else is nil.
    public static func parseQuality(_ text: String?) -> Double? {
        guard let t = text?.trimmingCharacters(in: .whitespaces), let v = Double(t), v.isFinite, (0...1).contains(v) else {
            return nil
        }
        return v
    }

    static func int(_ text: String?) -> Int? {
        text.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Fields for the `ev=encoder_config` line logged when the encoder is created. `prio_speed=1`,
    /// `idle_refresh=off` and `input_retag=1` are constants since T-204 (their knobs were retired), kept so the line
    /// and its parsers stay unchanged (like `video_socket=bsd` after T-186). The T-177 debug knobs add
    /// `bitrate_step=` / `rate_window_ms=` only when set, so the default line is unchanged; so does T-235's `chroma=`
    /// (the requested mode, `invalid` for an unknown value).
    public var logFields: String {
        var f = "prio_speed=1 quality=\(quality.map { String(format: "%.2f", $0) } ?? "unset") "
            + "idle_refresh=off input_retag=1"
        if let s = bitrateStep { f += " bitrate_step=\(s.logValue)" }
        if let w = rateWindowMs { f += " rate_window_ms=\(w)" }
        if chroma.isSet { f += " chroma=\(chroma.invalid ? "invalid" : chroma.requested.rawValue)" }
        return f
    }
}

/// The `ev=profile` line (T-204, decision 0026 §4): one line per stream start that names the configuration a log
/// came from. Pure; the encoder logs it right after `ev=encoder_config`.
///
/// `knobs=` lists the host environment knobs that are set, as `NAME:value` joined by `;` (`-` when none). Only the
/// knobs 0026 keeps (keep / debug-only) are considered: a retired key (`MATEBRIDGE_IDLE_REFRESH_MS`, ...) or any other
/// variable is never listed. The socket knobs are left out: `ev=listening` reports the sockets.
public enum StreamProfileLog {
    /// Host env knobs classed keep or debug-only in decision 0026 (`docs/KNOBS.md` rows 24, 25, 26, 28, 30, 31,
    /// 33, 34, 36-42, 43, 44, 45), in log order.
    public static let knobAllowList: [String] = [
        "MATEBRIDGE_FPS", "MATEBRIDGE_BITRATE_KBPS", "MATEBRIDGE_WIFI_BITRATE_KBPS", "MATEBRIDGE_CODEC",
        "MATEBRIDGE_REFRESH", "MATEBRIDGE_ENCODER", "MATEBRIDGE_QUALITY", "MATEBRIDGE_KEYFRAME_INTERVAL_S",
        "MATEBRIDGE_BITRATE_STEP", "MATEBRIDGE_RATE_WINDOW_MS", "MATEBRIDGE_SERVICE_CLASS",
        "MATEBRIDGE_NOTSENT_LOWAT_KB", "MATEBRIDGE_SENDQ_LOG", "MATEBRIDGE_LAT_TRACE", "MATEBRIDGE_TCP_LOG",
        "MATEBRIDGE_AUDIO", "MATEBRIDGE_DISPLAY_KEEP_S", "MATEBRIDGE_VD_TRANSFER", "MATEBRIDGE_VD_PRIMARIES",
        "MATEBRIDGE_CHROMA",
    ]
    /// A logged knob value is cut to this many characters.
    public static let maxValueLength = 64

    /// The allow-listed knobs present in `env`, with their raw values made log-safe (`value(_:)`).
    public static func knobs(_ env: [String: String]) -> [(name: String, value: String)] {
        knobAllowList.compactMap { name in env[name].map { (name, value($0)) } }
    }

    /// `knobs=` value: `MATEBRIDGE_FPS:120;MATEBRIDGE_BITRATE_KBPS:40000`, or `-`.
    public static func knobsField(_ env: [String: String]) -> String {
        let k = knobs(env)
        return k.isEmpty ? "-" : k.map { "\($0.name):\($0.value)" }.joined(separator: ";")
    }

    /// `fps=… bitrate_kbps=… bitrate_source=… codec=… encoder_profile=… scale_permille=… refresh_hz=… display=… sha=…
    /// knobs=…`. `display=` is the virtual display mode (`2800x1840@2x`, or a game display `1848x1214@1x`, T-214).
    public static func fields(settings: VideoSettings, encoderProfile: EncoderProfile, build: BuildInfo,
                              env: [String: String]) -> String {
        "fps=\(settings.fps) bitrate_kbps=\(settings.bitrateKbps) bitrate_source=\(settings.bitrateSource) "
            + "codec=\(settings.codec.logName) encoder_profile=\(encoderProfile.rawValue) "
            + "scale_permille=\(settings.scalePermille) refresh_hz=\(settings.displayRefreshHz) "
            + "display=\(settings.displayModeText) sha=\(value(build.sha)) knobs=\(knobsField(env))"
    }

    /// One log token: trimmed, cut to `maxValueLength` characters, whitespace and the separators `=` and `;` become
    /// `_`. An empty value is logged as `_`.
    public static func value(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "_" }
        return String(t.prefix(maxValueLength).map { $0.isWhitespace || $0 == "=" || $0 == ";" ? "_" : $0 })
    }
}

extension VideoSettings {
    /// `MATEBRIDGE_CODEC`: "h264" or "hevc" (case-insensitive); anything else (or nil) is HEVC.
    public static func parseCodec(_ text: String?) -> Codec {
        text?.trimmingCharacters(in: .whitespaces).lowercased() == "h264" ? .h264 : .hevc
    }

    /// Where the bitrate comes from: `env` (`MATEBRIDGE_BITRATE_KBPS`, wins over everything), `wifi_env`
    /// (`MATEBRIDGE_WIFI_BITRATE_KBPS` on a Wi-Fi session, T-088), `user` (`STREAM_PREFS.bitrate_kbps`, T-106) or
    /// `prefs` (the default for the stream mode, `defaultBitrateKbps`). An override without a recorded source counts
    /// as `env`.
    public var bitrateSource: String {
        guard bitrateOverrideKbps != nil else {
            return (userBitrateKbps != nil ? BitrateSource.user : BitrateSource.prefs).rawValue
        }
        return (bitrateOverrideSource ?? .env).rawValue
    }
}

/// H.264 SPS header fields (T-086 logging). `nal` is the SPS NAL unit with its 1-byte header, without start code.
public enum H264SPS {
    public static func isSPS(_ nal: [UInt8]) -> Bool { nal.first.map { $0 & 0x1F == 7 } ?? false }

    /// profile_idc (byte 1).
    public static func profileIdc(_ nal: [UInt8]) -> UInt8? {
        isSPS(nal) && nal.count > 3 ? nal[1] : nil
    }

    /// level_idc (byte 3; e.g. 52 = level 5.2). The three bytes after the header never contain an emulation
    /// prevention byte (profile_idc is never 0).
    public static func levelIdc(_ nal: [UInt8]) -> UInt8? {
        isSPS(nal) && nal.count > 3 ? nal[3] : nil
    }
}

extension HEVCSPS {
    /// general_level_idc (30 x level, e.g. 153 = 5.1), from an SPS NAL unit (with header, without start code).
    public static func generalLevelIdc(sps nal: [UInt8]) -> UInt8? {
        guard AnnexB.hevcNALType(nal) == 33, nal.count > 3 else { return nil }
        let d = unescape(Array(nal[2...]))
        // 4 bits vps id + 3 bits max_sub_layers_minus1 + 1 bit nesting, then 88 bits of general profile.
        let index = 1 + 11
        return d.count > index ? d[index] : nil
    }
}

/// Capture timestamp of a re-submission of the last buffer (keyframe on a static screen; T-086).
///
/// ScreenCaptureKit stamps a frame ahead of its delivery (NOTES 2026-10-01: `pts_vs_deliv` = +6.6 ms). The tablet
/// pacer measures lateness as `ready - capture_time`, so a re-submission stamped plain "now" would look one lead
/// late. It is stamped `now + lead` (the lead of the newest real capture) instead, and never at or below a stamp
/// already handed out, so capture times keep increasing.
public enum ResubmitStamp {
    /// `captureUs - deliveredUs` (signed) of a real capture.
    public static func lead(captureUs: UInt64, deliveredUs: UInt64) -> Int64 {
        Int64(clamping: captureUs) &- Int64(clamping: deliveredUs)
    }

    public static func stamp(nowUs: UInt64, leadUs: Int64, lastStampUs: UInt64?) -> UInt64 {
        let shifted = Int64(clamping: nowUs).addingReportingOverflow(leadUs)
        let base = shifted.overflow ? nowUs : UInt64(max(0, shifted.partialValue))
        guard let last = lastStampUs else { return base }
        return max(base, last &+ 1)
    }
}
