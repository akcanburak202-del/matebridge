/// Accumulates encoder output statistics for the `--dump-video` tool and logs.
public struct VideoStats: Sendable {
    public private(set) var frames = 0
    public private(set) var keyframes = 0
    public private(set) var bytes = 0
    public private(set) var maxFrameBytes = 0
    private var encodeTimeTotalUs: UInt64 = 0
    public private(set) var maxEncodeTimeUs: UInt64 = 0

    public init() {}

    /// Codec-config frames count as bytes but not as picture frames.
    public mutating func record(_ frame: EncodedVideoFrame, encodeTimeUs: UInt64) {
        bytes += frame.data.count
        guard !frame.isCodecConfig else { return }
        frames += 1
        if frame.isKeyframe { keyframes += 1 }
        maxFrameBytes = max(maxFrameBytes, frame.data.count)
        encodeTimeTotalUs += encodeTimeUs
        maxEncodeTimeUs = max(maxEncodeTimeUs, encodeTimeUs)
    }

    public var averageFrameBytes: Double { frames == 0 ? 0 : Double(bytes) / Double(frames) }
    public var averageEncodeTimeUs: Double { frames == 0 ? 0 : Double(encodeTimeTotalUs) / Double(frames) }

    public func bitrateKbps(overSeconds s: Double) -> Double { s > 0 ? Double(bytes) * 8 / 1000 / s : 0 }
}
