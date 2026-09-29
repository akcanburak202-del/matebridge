import Foundation

/// Tunable video parameters and the `STREAM_CONFIG` derived from them.
public struct VideoSettings: Equatable, Sendable {
    public var widthPx: Int
    public var heightPx: Int
    /// Logical size in points (HiDPI: half of the pixel size).
    public var widthPt: Int
    public var heightPt: Int
    public var fps: Int
    public var bitrateKbps: Int
    public var codec: Codec
    /// Refresh rate of the virtual display (60 or 120). Not part of `STREAM_CONFIG`: the stream stays at `fps`.
    public var displayRefreshHz: Int = 60
    /// VideoToolbox `MaxFrameDelayCount`; nil leaves the encoder default (T-017 experiment knob).
    public var maxFrameDelayCount: Int?

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

    public static let colorPrimaries: UInt8 = 1
    public static let transfer: UInt8 = 13
    public static let matrix: UInt8 = 1
    public static let fullRange = true

    public func streamConfig(configID: UInt16) -> StreamConfig {
        StreamConfig(
            configID: configID, codec: codec,
            widthPx: UInt16(clamping: widthPx), heightPx: UInt16(clamping: heightPx),
            widthPt: UInt16(clamping: widthPt), heightPt: UInt16(clamping: heightPt),
            fps: UInt16(clamping: fps), bitrateKbps: UInt32(clamping: bitrateKbps),
            colorPrimaries: VideoSettings.colorPrimaries, transfer: VideoSettings.transfer,
            matrix: VideoSettings.matrix, fullRange: VideoSettings.fullRange)
    }
}
