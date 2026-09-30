extension KeyframeReason {
    /// Whether the host must re-send `CODEC_CONFIG` ahead of the keyframe this request forces (PROTOCOL.md 0x23).
    ///
    /// STARTUP and DECODE_ERROR mean the client (re)built its decoder and may have thrown the parameter sets away,
    /// and the encoder only announces them when they change. Unknown reasons are treated like DECODE_ERROR.
    /// FRAMES_DROPPED keeps the decoder running, so a config in mid-stream would be noise.
    public var resendsCodecConfig: Bool { self != .framesDropped }
}
