import Foundation

/// Tunable video parameters and the `STREAM_CONFIG` derived from them.
public struct VideoSettings: Equatable, Sendable {
    /// Virtual display size in pixels (the encoded size is `encodedWidthPx` x `encodedHeightPx`).
    public var widthPx: Int
    public var heightPx: Int
    /// Encoded size as a fraction of the display size, in permille (500...1000; `STREAM_PREFS`, T-049).
    public var scalePermille: Int = 1000
    /// Logical size in points (HiDPI: half of the pixel size).
    public var widthPt: Int
    public var heightPt: Int
    public var fps: Int
    public var bitrateKbps: Int
    public var codec: Codec
    /// Refresh rate of the virtual display (60, 120 or 144). Not part of `STREAM_CONFIG`: the stream stays at `fps`.
    public var displayRefreshHz: Int = 60
    /// VideoToolbox `MaxFrameDelayCount`; nil leaves the encoder default (T-017 experiment knob).
    public var maxFrameDelayCount: Int?
    /// `MATEBRIDGE_BITRATE_KBPS` (T-086): when set it wins over the stream-mode default of `applying(_:)`.
    public var bitrateOverrideKbps: Int?

    /// Tablet native panel, 2x HiDPI.
    public static let tabletDefault = VideoSettings(
        widthPx: 2800, heightPx: 1840, widthPt: 1400, heightPt: 920,
        fps: 60, bitrateKbps: 30_000, codec: .hevc)

    public init(widthPx: Int, heightPx: Int, widthPt: Int, heightPt: Int, fps: Int, bitrateKbps: Int,
                codec: Codec = .hevc) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.widthPt = widthPt
        self.heightPt = heightPt
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        self.codec = codec
    }

    // H.273 codes: sRGB primaries = BT.709 primaries; transfer 13 = sRGB; matrix 1 = BT.709; full range.
    /// Accepts "60" or "120"; anything else (or nil) is 60.
    public static func parseRefreshHz(_ text: String?) -> Int {
        guard let text, let v = Int(text.trimmingCharacters(in: .whitespaces)), v == 60 || v == 120 else { return 60 }
        return v
    }

    /// Accepts "0" or "1"; anything else (or nil) leaves the encoder default.
    public static func parseFrameDelay(_ text: String?) -> Int? {
        guard let text, let v = Int(text.trimmingCharacters(in: .whitespaces)), v == 0 || v == 1 else { return nil }
        return v
    }

    /// `MATEBRIDGE_FPS`: "60", "90" or "120"; anything else (or nil) is 60 (T-045).
    public static func parseFps(_ text: String?) -> Int {
        guard let text, let v = Int(text.trimmingCharacters(in: .whitespaces)), [60, 90, 120].contains(v) else { return 60 }
        return v
    }

    /// `MATEBRIDGE_BITRATE_KBPS`: 5 000...150 000; anything else (or nil) is nil (keep the default).
    public static func parseBitrateKbps(_ text: String?) -> Int? {
        guard let text, let v = Int(text.trimmingCharacters(in: .whitespaces)), (5_000...150_000).contains(v) else { return nil }
        return v
    }

    /// Applies the experiment knobs (T-017, T-045, T-086: codec and a bitrate that wins over `STREAM_PREFS`) from an
    /// environment. With no variables set, `self` is unchanged
    /// apart from `displayRefreshHz`/`maxFrameDelayCount` staying at their defaults. `MATEBRIDGE_FPS` overrides the
    /// tablet-derived fps only when present and valid; `MATEBRIDGE_FPS=120` without `MATEBRIDGE_REFRESH` also puts the
    /// virtual display at 120 Hz.
    public func applyingExperimentKnobs(_ env: [String: String]) -> VideoSettings {
        var s = self
        if env["MATEBRIDGE_FPS"] != nil { s.fps = Self.parseFps(env["MATEBRIDGE_FPS"]) }
        if let b = Self.parseBitrateKbps(env["MATEBRIDGE_BITRATE_KBPS"]) {
            s.bitrateKbps = b
            s.bitrateOverrideKbps = b
        }
        s.codec = Self.parseCodec(env["MATEBRIDGE_CODEC"])
        s.displayRefreshHz = env["MATEBRIDGE_REFRESH"] != nil
            ? Self.parseRefreshHz(env["MATEBRIDGE_REFRESH"]) : (s.fps == 120 ? 120 : 60)
        s.maxFrameDelayCount = Self.parseFrameDelay(env["MATEBRIDGE_FRAME_DELAY"])
        return s
    }

    /// Same virtual display size and point size (refresh rate, fps, scale and bitrate may differ).
    public func sameDisplay(as other: VideoSettings) -> Bool {
        widthPx == other.widthPx && heightPx == other.heightPx && widthPt == other.widthPt && heightPt == other.heightPt
    }

    public static let colorPrimaries: UInt8 = 1
    public static let transfer: UInt8 = 13
    public static let matrix: UInt8 = 1
    public static let fullRange = true

    public func streamConfig(configID: UInt16) -> StreamConfig {
        StreamConfig(
            configID: configID, codec: codec,
            widthPx: UInt16(clamping: encodedWidthPx), heightPx: UInt16(clamping: encodedHeightPx),
            widthPt: UInt16(clamping: widthPt), heightPt: UInt16(clamping: heightPt),
            fps: UInt16(clamping: fps), bitrateKbps: UInt32(clamping: bitrateKbps),
            colorPrimaries: VideoSettings.colorPrimaries, transfer: VideoSettings.transfer,
            matrix: VideoSettings.matrix, fullRange: VideoSettings.fullRange)
    }
}
