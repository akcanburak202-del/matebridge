extension KeyframeReason {
    /// Whether the host must re-send `CODEC_CONFIG` ahead of the keyframe this request forces (PROTOCOL.md 0x23).
    ///
    /// STARTUP and DECODE_ERROR mean the client (re)built its decoder and may have thrown the parameter sets away,
    /// and the encoder only announces them when they change. Unknown reasons are treated like DECODE_ERROR.
    /// FRAMES_DROPPED keeps the decoder running, so a config in mid-stream would be noise.
    public var resendsCodecConfig: Bool { self != .framesDropped }

    /// Coalescing rule for keyframe requests that are still pending: a request that needs a config resend is never
    /// downgraded by a later one that does not (STARTUP followed by FRAMES_DROPPED must still resend the config).
    /// Otherwise the later request wins.
    public static func merged(pending: KeyframeReason, incoming: KeyframeReason) -> KeyframeReason {
        pending.resendsCodecConfig && !incoming.resendsCodecConfig ? pending : incoming
    }
}
