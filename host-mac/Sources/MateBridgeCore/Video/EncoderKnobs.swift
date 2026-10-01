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

/// Idle quality refresh (T-086): on a static screen ScreenCaptureKit delivers nothing, so the last (often blurry,
/// motion-time) P frame stays on the tablet. After `delayMs` without a real capture the last buffer is re-encoded
/// `count` times (one frame interval apart), or once as a forced keyframe when `keyframe` is set.
public struct IdleRefreshConfig: Equatable, Sendable {
    public static let defaultCount = 3
    public static let countRange: ClosedRange<Int> = 1...30
    public static let delayRange: ClosedRange<Int> = 1...10_000

    /// 0 = off.
    public var delayMs: Int = 0
    public var count: Int = IdleRefreshConfig.defaultCount
    public var keyframe = false

    public init(delayMs: Int = 0, count: Int = IdleRefreshConfig.defaultCount, keyframe: Bool = false) {
        self.delayMs = delayMs
        self.count = count
        self.keyframe = keyframe
    }

    public var isEnabled: Bool { delayMs > 0 }

    /// `MATEBRIDGE_IDLE_REFRESH_MS` (1...10 000, anything else is off), `MATEBRIDGE_IDLE_REFRESH_COUNT` (1...30,
    /// default 3), `MATEBRIDGE_IDLE_REFRESH_KEY=1` (keyframe variant).
    public static func parse(_ env: [String: String]) -> IdleRefreshConfig {
        var c = IdleRefreshConfig()
        if let v = EncoderKnobs.int(env["MATEBRIDGE_IDLE_REFRESH_MS"]), delayRange.contains(v) { c.delayMs = v }
        if let v = EncoderKnobs.int(env["MATEBRIDGE_IDLE_REFRESH_COUNT"]), countRange.contains(v) { c.count = v }
        c.keyframe = env["MATEBRIDGE_IDLE_REFRESH_KEY"]?.trimmingCharacters(in: .whitespaces) == "1"
        return c
    }

    /// Log value: `off`, `300ms*3` or `300ms*key`.
    public var logValue: String {
        guard isEnabled else { return "off" }
        return keyframe ? "\(delayMs)ms*key" : "\(delayMs)ms*\(count)"
    }
}

/// Encoder-level experiment knobs (T-086). Every default is the behaviour before T-086.
public struct EncoderKnobs: Equatable, Sendable {
    /// `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality`.
    public var prioritizeSpeed = true
    /// `kVTCompressionPropertyKey_Quality` (0...1). When set, `AverageBitRate` is not set (the `DataRateLimits`
    /// cap stays).
    public var quality: Double?
    public var h264Profile = H264Profile.high
    public var idleRefresh = IdleRefreshConfig()

    public init() {}

    /// `MATEBRIDGE_PRIO_SPEED=0|1` (anything else: 1), `MATEBRIDGE_QUALITY=0.0..1.0` (anything else: unset),
    /// `MATEBRIDGE_H264_PROFILE`, `MATEBRIDGE_IDLE_REFRESH_*`.
    public static func parse(_ env: [String: String]) -> EncoderKnobs {
        var k = EncoderKnobs()
        k.prioritizeSpeed = env["MATEBRIDGE_PRIO_SPEED"]?.trimmingCharacters(in: .whitespaces) != "0"
        k.quality = parseQuality(env["MATEBRIDGE_QUALITY"])
        k.h264Profile = H264Profile.parse(env["MATEBRIDGE_H264_PROFILE"])
        k.idleRefresh = IdleRefreshConfig.parse(env)
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

    /// Fields for the `ev=encoder_config` line logged when the encoder is created.
    public var logFields: String {
        "prio_speed=\(prioritizeSpeed ? 1 : 0) quality=\(quality.map { String(format: "%.2f", $0) } ?? "unset") "
            + "idle_refresh=\(idleRefresh.logValue)"
    }
}

extension VideoSettings {
    /// `MATEBRIDGE_CODEC`: "h264" or "hevc" (case-insensitive); anything else (or nil) is HEVC.
    public static func parseCodec(_ text: String?) -> Codec {
        text?.trimmingCharacters(in: .whitespaces).lowercased() == "h264" ? .h264 : .hevc
    }

    /// Where the bitrate comes from: `env` (`MATEBRIDGE_BITRATE_KBPS`, wins over the mode default) or `prefs` (the
    /// default for the stream mode, `defaultBitrateKbps`).
    public var bitrateSource: String { bitrateOverrideKbps != nil ? "env" : "prefs" }
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

/// Capture timestamp for a real capture when re-submissions of the last buffer (keyframe on a static screen, idle
/// refresh) are stamped with the current time (T-086).
public enum ResubmitStamp {
    /// A capture taken just before a re-submission but delivered after it carries newer content than the
    /// re-submitted buffer, yet its timestamp is older, so the pacer would drop it. Such a capture is moved to just
    /// after `floorUs`. A capture that is not newer than the previous real capture (raw timestamp `lastRealUs`) keeps
    /// its timestamp (the pacer drops it as stale, as before).
    /// - Parameter floorUs: the largest stamp handed out so far (re-submissions and adjusted real captures).
    public static func realCapture(_ captureUs: UInt64, lastRealUs: UInt64?, floorUs: UInt64?) -> UInt64 {
        guard let f = floorUs, captureUs <= f else { return captureUs }
        if let l = lastRealUs, captureUs <= l { return captureUs }
        return f &+ 1
    }

    /// Tracks the inputs of `realCapture` (owned by the encoder, under its lock).
    public struct Tracker: Sendable {
        public private(set) var lastRealUs: UInt64?
        public private(set) var floorUs: UInt64?

        public init() {}

        /// A real capture arrived: returns the stamp it is submitted with.
        public mutating func real(_ captureUs: UInt64) -> UInt64 {
            let stamp = ResubmitStamp.realCapture(captureUs, lastRealUs: lastRealUs, floorUs: floorUs)
            lastRealUs = max(lastRealUs ?? 0, captureUs)
            floorUs = max(floorUs ?? 0, stamp)
            return stamp
        }

        /// A re-submission stamped `nowUs`.
        public mutating func resubmitted(_ nowUs: UInt64) { floorUs = max(floorUs ?? 0, nowUs) }
    }
}
