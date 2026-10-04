import Foundation

/// Tunable video parameters and the `STREAM_CONFIG` derived from them.
public struct VideoSettings: Equatable, Sendable {
    /// Virtual display size in pixels (the encoded size is `encodedWidthPx` x `encodedHeightPx`): the native display
    /// (HELLO size, HiDPI) or a 1x game display (decision 0029, `displayHiDPI == false`).
    public var widthPx: Int
    public var heightPx: Int
    /// Encoded size as a fraction of the display size, in permille (500...1000; `STREAM_PREFS`, T-049). Always 1000
    /// on a game display (the requested size is the encoded size).
    public var scalePermille: Int = 1000
    /// Logical size in points (HiDPI: half of the pixel size; 1x game display: equal to it).
    public var widthPt: Int
    public var heightPt: Int
    public var fps: Int
    public var bitrateKbps: Int
    public var codec: Codec
    /// Refresh rate of the virtual display (60, 120 or 144). Not part of `STREAM_CONFIG`: the stream stays at `fps`.
    public var displayRefreshHz: Int = 60
    /// `MATEBRIDGE_BITRATE_KBPS` (T-086): when set it wins over the stream-mode default of `applying(_:)`.
    public var bitrateOverrideKbps: Int?
    /// Which knob set `bitrateOverrideKbps` (T-088); nil with an override means `env`.
    public var bitrateOverrideSource: BitrateSource?
    /// The tablet's chosen bitrate (`STREAM_PREFS.bitrate_kbps`, clamped; decision 0013, T-106). nil = the mode
    /// default. Always nil while `bitrateOverrideKbps` is set: the user's choice is not in effect then, so a change
    /// of it alone is no change of the settings.
    public var userBitrateKbps: Int?
    /// 1x game display only (decision 0029): the native HiDPI display it stands in for. nil = this is the native
    /// display, whose own size is the native size. Set by `applying(_:)`; the single source of `displayHiDPI`.
    public internal(set) var replacedNative: NativeDisplaySize?

    /// The native display (HELLO size, HiDPI 2x) a 1x game display replaces.
    public struct NativeDisplaySize: Equatable, Sendable {
        public var widthPx: Int
        public var heightPx: Int
        public var widthPt: Int
        public var heightPt: Int
    }

    /// The virtual display is HiDPI (2x, the native display). false = a 1x game display (decision 0029).
    public var displayHiDPI: Bool { replacedNative == nil }
    /// The tablet's native pixel size (HELLO): the same for the native display and for a game display replacing it.
    public var nativeWidthPx: Int { replacedNative?.widthPx ?? widthPx }
    public var nativeHeightPx: Int { replacedNative?.heightPx ?? heightPx }

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
    /// environment. With no variables set, `self` is unchanged apart from `displayRefreshHz` staying at its default. `MATEBRIDGE_FPS` overrides the
    /// tablet-derived fps only when present and valid; `MATEBRIDGE_FPS=120` without `MATEBRIDGE_REFRESH` also puts the
    /// virtual display at 120 Hz.
    public func applyingExperimentKnobs(_ env: [String: String]) -> VideoSettings {
        var s = self
        if env["MATEBRIDGE_FPS"] != nil { s.fps = Self.parseFps(env["MATEBRIDGE_FPS"]) }
        if let b = Self.parseBitrateKbps(env["MATEBRIDGE_BITRATE_KBPS"]) {
            s.bitrateKbps = b
            s.bitrateOverrideKbps = b
            s.bitrateOverrideSource = .env
        }
        s.codec = Self.parseCodec(env["MATEBRIDGE_CODEC"])
        s.displayRefreshHz = env["MATEBRIDGE_REFRESH"] != nil
            ? Self.parseRefreshHz(env["MATEBRIDGE_REFRESH"]) : (s.fps == 120 ? 120 : 60)
        return s
    }

    /// Same virtual display size, point size and HiDPI (refresh rate, fps, scale and bitrate may differ).
    public func sameDisplay(as other: VideoSettings) -> Bool {
        widthPx == other.widthPx && heightPx == other.heightPx && widthPt == other.widthPt && heightPt == other.heightPt
            && displayHiDPI == other.displayHiDPI
    }

    /// Same native (HELLO) size: the native display and a game display of the same tablet are one display identity
    /// for `DisplayLease`; only their mode differs (decision 0029).
    public func sameNative(as other: VideoSettings) -> Bool {
        nativeWidthPx == other.nativeWidthPx && nativeHeightPx == other.nativeHeightPx
    }

    /// Display mode for the logs: `2800x1840@2x` (native, HiDPI) or `1848x1214@1x` (game display).
    public var displayModeText: String { displayMode.text }

    /// The mode the virtual display must have for these settings (`DisplayReuse`).
    public var displayMode: DisplayMode {
        DisplayMode(widthPx: widthPx, heightPx: heightPx, hidpi: displayHiDPI, refreshHz: displayRefreshHz)
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
