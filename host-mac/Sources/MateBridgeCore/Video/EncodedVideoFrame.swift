/// One encoder output unit, before it gets a `frame_seq` and becomes a `VIDEO_FRAME`.
/// The session (T-014) assigns `frame_seq` at send time so drops never create gaps.
public struct EncodedVideoFrame: Equatable, Sendable {
    public var flags: VideoFrameFlags
    /// Host monotonic microseconds of the captured screen frame (0 for CODEC_CONFIG).
    public var captureTimeUs: UInt64
    /// Annex-B NAL units.
    public var data: [UInt8]

    public init(flags: VideoFrameFlags, captureTimeUs: UInt64, data: [UInt8]) {
        self.flags = flags
        self.captureTimeUs = captureTimeUs
        self.data = data
    }

    public var isKeyframe: Bool { flags.contains(.keyframe) }
    public var isCodecConfig: Bool { flags.contains(.codecConfig) }
    /// Frames that must survive queue overflow if at all possible.
    var isProtected: Bool { isKeyframe || isCodecConfig }

    public func toVideoFrame(seq: UInt32) -> VideoFrame {
        VideoFrame(frameSeq: seq, captureTimeUs: captureTimeUs, flags: flags, data: data)
    }
}
