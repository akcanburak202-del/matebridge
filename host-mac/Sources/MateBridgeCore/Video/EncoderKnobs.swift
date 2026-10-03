import Foundation

/// H.264 profile for `MATEBRIDGE_CODEC=h264` (T-086). The host maps it to a VideoToolbox `ProfileLevel` constant.
public enum H264Profile: String, Equatable, Sendable, CaseIterable {
    /// High, level chosen by the encoder.
    case high
    case main
    /// Constrained Baseline.
    case cbp
    /// High at fixed level 5.2.
    case high52

    /// `MATEBRIDGE_H264_PROFILE`: case-insensitive; anything else (or nil) is `.high`.
    public static func parse(_ text: String?) -> H264Profile {
        guard let t = text?.trimmingCharacters(in: .whitespaces).lowercased(), let p = H264Profile(rawValue: t) else {
            return .high
        }
        return p
    }
}

extension Codec {
    /// Name used in logs (`codec=h264|hevc`).
    public var logName: String {
        switch self {
        case .h264: return "h264"
        case .hevc: return "hevc"
        }
    }
}

/// What an idle refresh re-submits (T-087): the last captured buffer object itself (`same`, the T-086 behaviour), or
/// a content copy in a fresh pool buffer (`copy`). Measured: VideoToolbox encodes both identically (T-087 Handoff).
public enum IdleRefreshBuffer: String, Equatable, Sendable, CaseIterable {
    case same
    case copy

    /// `MATEBRIDGE_IDLE_REFRESH_BUFFER`: case-insensitive; anything else (or nil) is `.same`.
    public static func parse(_ text: String?) -> IdleRefreshBuffer {
        guard let t = text?.trimmingCharacters(in: .whitespaces).lowercased(), let b = IdleRefreshBuffer(rawValue: t)
        else { return .same }
        return b
    }
}

/// Idle quality refresh (T-086): on a static screen ScreenCaptureKit delivers nothing, so the last (often blurry,
/// motion-time) P frame stays on the tablet. After `delayMs` without a real capture the last buffer is re-encoded
/// `count` times (one frame interval apart), or once as a forced keyframe when `keyframe` is set.
///
/// T-087: an identical re-submission only adds detail while the encoder's current QP is lower than the QP the last
/// motion frame got; in a settled session they are equal and VideoToolbox emits all-skip frames. `maxQP` caps the
/// frame QP (`kVTCompressionPropertyKey_MaxAllowedFrameQP`) for the refresh frames only and lifts the cap before the
/// next other frame (`RefreshQPBoost`). VideoToolbox honours that mid-stream change only with the low-latency rate
/// control (`MATEBRIDGE_ENCODER=llrc`); the default `fast` profile accepts the property and ignores it.
public struct IdleRefreshConfig: Equatable, Sendable {
    public static let defaultCount = 3
    public static let countRange: ClosedRange<Int> = 1...30
    public static let delayRange: ClosedRange<Int> = 1...10_000
    /// HEVC and H.264 QP range.
    public static let maxQPRange: ClosedRange<Int> = 1...51

    /// 0 = off.
    public var delayMs: Int = 0
    public var count: Int = IdleRefreshConfig.defaultCount
    public var keyframe = false
    public var buffer = IdleRefreshBuffer.same
    /// QP cap for the refresh frames (nil: none, the T-086 behaviour).
    public var maxQP: Int?

    public init(delayMs: Int = 0, count: Int = IdleRefreshConfig.defaultCount, keyframe: Bool = false,
                buffer: IdleRefreshBuffer = .same, maxQP: Int? = nil) {
        self.delayMs = delayMs
        self.count = count
        self.keyframe = keyframe
        self.buffer = buffer
        self.maxQP = maxQP
    }

    public var isEnabled: Bool { delayMs > 0 }

    /// `MATEBRIDGE_IDLE_REFRESH_MS` (1...10 000, anything else is off), `MATEBRIDGE_IDLE_REFRESH_COUNT` (1...30,
    /// default 3), `MATEBRIDGE_IDLE_REFRESH_KEY=1` (keyframe variant), `MATEBRIDGE_IDLE_REFRESH_BUFFER=same|copy`,
    /// `MATEBRIDGE_IDLE_REFRESH_QP` (1...51, anything else is unset).
    public static func parse(_ env: [String: String]) -> IdleRefreshConfig {
        var c = IdleRefreshConfig()
        if let v = EncoderKnobs.int(env["MATEBRIDGE_IDLE_REFRESH_MS"]), delayRange.contains(v) { c.delayMs = v }
        if let v = EncoderKnobs.int(env["MATEBRIDGE_IDLE_REFRESH_COUNT"]), countRange.contains(v) { c.count = v }
        c.keyframe = env["MATEBRIDGE_IDLE_REFRESH_KEY"]?.trimmingCharacters(in: .whitespaces) == "1"
        c.buffer = IdleRefreshBuffer.parse(env["MATEBRIDGE_IDLE_REFRESH_BUFFER"])
        if let v = EncoderKnobs.int(env["MATEBRIDGE_IDLE_REFRESH_QP"]), maxQPRange.contains(v) { c.maxQP = v }
        return c
    }

    /// Log value: `off`, `300ms*3` or `300ms*key`, plus `+copy` and `+qp12` when those are set.
    public var logValue: String {
        guard isEnabled else { return "off" }
        var v = keyframe ? "\(delayMs)ms*key" : "\(delayMs)ms*\(count)"
        if buffer == .copy { v += "+copy" }
        if let q = maxQP { v += "+qp\(q)" }
        return v
    }
}

/// When to set and lift the refresh-frame QP cap (T-087). Pure; the encoder owns one only when
/// `IdleRefreshConfig.maxQP` is set, and asks it before every frame it submits, under one lock together with the
/// property call, so the last property change always belongs to the last frame decided.
///
/// The cap goes on before the first refresh frame and comes off before the next non-refresh frame (a real capture or
/// a keyframe re-submission), so it never outlives a static stretch by more than that one frame's decision. If
/// VideoToolbox refuses the cap it is disabled for the session.
public struct RefreshQPBoost: Sendable {
    public enum Change: Equatable, Sendable {
        /// Set `MaxAllowedFrameQP` to this value.
        case apply(Int)
        /// Lift the cap again.
        case restore
    }

    public let maxQP: Int
    public private(set) var active = false
    public private(set) var disabled = false

    public init(maxQP: Int) { self.maxQP = maxQP }

    /// The property change needed before submitting a frame (nil: none).
    public mutating func before(refresh: Bool) -> Change? {
        if refresh {
            guard !active, !disabled else { return nil }
            active = true
            return .apply(maxQP)
        }
        guard active else { return nil }
        active = false
        return .restore
    }

    /// VideoToolbox refused `.apply`: the cap is not in place and is not tried again.
    public mutating func applyFailed() {
        active = false
        disabled = true
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

/// Encoder-level experiment knobs (T-086). Every default is the behaviour before T-086, except `retagInput` (T-113).
public struct EncoderKnobs: Equatable, Sendable {
    /// `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality`.
    public var prioritizeSpeed = true
    /// `kVTCompressionPropertyKey_Quality` (0...1). When set, `AverageBitRate` is not set (the `DataRateLimits`
    /// cap stays).
    public var quality: Double?
    public var h264Profile = H264Profile.high
    public var idleRefresh = IdleRefreshConfig()
    /// Rewrite captured buffers' colour tags to the session's so VideoToolbox does not colour-convert them (T-113,
    /// `InputRetag`). On by default; `MATEBRIDGE_INPUT_RETAG=0` restores the old conversion for A/B.
    public var retagInput = true
    /// Debug bitrate step timer (T-177, `MATEBRIDGE_BITRATE_STEP`); nil = off.
    public var bitrateStep: BitrateStepKnob?
    /// Short `DataRateLimits` window in ms next to the 1 s pair (T-177 diagnostics, `MATEBRIDGE_RATE_WINDOW_MS`);
    /// nil = off (only the 1 s pair). Closed by T-196, or removed after T-127 (decision 0026 §2).
    public var rateWindowMs: Int?

    public static let rateWindowRangeMs: ClosedRange<Int> = 10...999

    public init() {}

    /// `MATEBRIDGE_PRIO_SPEED=0|1` (anything else: 1), `MATEBRIDGE_QUALITY=0.0..1.0` (anything else: unset),
    /// `MATEBRIDGE_H264_PROFILE`, `MATEBRIDGE_IDLE_REFRESH_*`, `MATEBRIDGE_INPUT_RETAG=0|1` (anything else: 1),
    /// `MATEBRIDGE_BITRATE_STEP` (`BitrateStepKnob.parse`), `MATEBRIDGE_RATE_WINDOW_MS` (10...999, anything else: off).
    public static func parse(_ env: [String: String]) -> EncoderKnobs {
        var k = EncoderKnobs()
        k.retagInput = InputRetag.isEnabled(env)
        k.prioritizeSpeed = env["MATEBRIDGE_PRIO_SPEED"]?.trimmingCharacters(in: .whitespaces) != "0"
        k.quality = parseQuality(env["MATEBRIDGE_QUALITY"])
        k.h264Profile = H264Profile.parse(env["MATEBRIDGE_H264_PROFILE"])
        k.idleRefresh = IdleRefreshConfig.parse(env)
        k.bitrateStep = BitrateStepKnob.parse(env["MATEBRIDGE_BITRATE_STEP"])
        if let v = int(env["MATEBRIDGE_RATE_WINDOW_MS"]), rateWindowRangeMs.contains(v) { k.rateWindowMs = v }
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

    /// Fields for the `ev=encoder_config` line logged when the encoder is created. The T-177 debug knobs add
    /// `bitrate_step=` / `rate_window_ms=` only when set, so the default line is unchanged.
    public var logFields: String {
        var f = "prio_speed=\(prioritizeSpeed ? 1 : 0) quality=\(quality.map { String(format: "%.2f", $0) } ?? "unset") "
            + "idle_refresh=\(idleRefresh.logValue) input_retag=\(retagInput ? 1 : 0)"
        if let s = bitrateStep { f += " bitrate_step=\(s.logValue)" }
        if let w = rateWindowMs { f += " rate_window_ms=\(w)" }
        return f
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

/// When to re-encode the last captured buffer on a static screen (T-086). Pure: the encoder owns one under its lock,
/// tells it about every real capture and polls it from a timer.
///
/// One static stretch ("episode") gets at most one refresh: `count` resubmits one frame interval apart starting
/// `delayMs` after the last real capture (or one keyframe). A new real capture cancels any remaining resubmits and
/// re-arms the policy. Resubmits are not captures: they never re-arm it.
public struct IdleRefreshPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Re-encode the last captured buffer. `first`: the episode starts now (log it once).
        case resubmit(first: Bool)
        /// Force one keyframe from the last captured buffer (`MATEBRIDGE_IDLE_REFRESH_KEY=1`).
        case keyframe
    }

    public let config: IdleRefreshConfig
    public let intervalUs: UInt64
    private var lastCaptureUs: UInt64?
    private var armed = false
    private var remaining = 0
    private var nextDueUs: UInt64 = 0

    public init(config: IdleRefreshConfig, fps: Int) {
        self.config = config
        intervalUs = 1_000_000 / UInt64(max(1, fps))
    }

    /// A real capture was handed to the encoder.
    public mutating func captured(nowUs: UInt64) {
        lastCaptureUs = nowUs
        armed = true
        remaining = 0
    }

    /// Call from a timer (at least once per frame interval while enabled).
    public mutating func tick(nowUs: UInt64) -> Action {
        guard config.isEnabled, let last = lastCaptureUs else { return .none }
        if remaining > 0 {
            guard nowUs >= nextDueUs else { return .none }
            remaining -= 1
            nextDueUs = nowUs &+ intervalUs
            return .resubmit(first: false)
        }
        guard armed, nowUs >= last &+ UInt64(config.delayMs) * 1000 else { return .none }
        armed = false
        if config.keyframe { return .keyframe }
        remaining = max(1, config.count) - 1
        nextDueUs = nowUs &+ intervalUs
        return .resubmit(first: true)
    }

    /// Forget everything (encoder stopped).
    public mutating func reset() {
        lastCaptureUs = nil
        armed = false
        remaining = 0
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

/// Capture timestamp of a re-submission of the last buffer (keyframe on a static screen, idle refresh; T-086).
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
