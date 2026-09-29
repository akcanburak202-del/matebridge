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
