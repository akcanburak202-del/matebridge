// Audio messages, docs/PROTOCOL.md 0x30-0x32 (decision 0011). Audio content is private: never log `AudioFrame.data`.

/// `AUDIO_CONFIG.state`. Unknown values decode fine; the client ignores such a stream.
public struct AudioState: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let stopped = AudioState(rawValue: 0)
    public static let started = AudioState(rawValue: 1)
}

/// `AUDIO_CONFIG.format`. Unknown values decode fine; the client ignores such a stream.
public struct AudioFormat: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// Signed 16-bit little-endian PCM, channels interleaved.
    public static let pcmS16LE = AudioFormat(rawValue: 1)
    /// AAC-LC, 48 kHz stereo, 1024-frame raw access units, no ADTS (decision 0038). The AAC encoder is T-340.
    public static let aacLC = AudioFormat(rawValue: 2)
}

/// `AUDIO_PREFS.codec` as the host reads it (decision 0038): unknown values are PCM.
public enum AudioCodecPreference: UInt8, Equatable, Sendable {
    case pcm = 0
    case aac = 1

    public init(wire: UInt8) { self = AudioCodecPreference(rawValue: wire) ?? .pcm }
}

/// `AUDIO_PREFS` (C->H, 0x30): whether the client wants audio.
public struct AudioPrefs: Equatable, Sendable {
    public var enabled: Bool
    /// The raw `codec` byte (the former `reserved`; decision 0038): 0 PCM, 1 AAC, anything else counts as 0 (`codec`).
    public var codecWire: UInt8

    public init(enabled: Bool, codecWire: UInt8 = 0) {
        self.enabled = enabled
        self.codecWire = codecWire
    }

    /// The codec the client asks for (unknown values are PCM). The host still plays AAC only with HELLO bit14.
    public var codec: AudioCodecPreference { AudioCodecPreference(wire: codecWire) }

    func write(_ w: inout ByteWriter) {
        w.u8(enabled ? 1 : 0)
        w.u8(codecWire)
        w.u16(0)
    }

    /// Any value other than 1 counts as 0 (PROTOCOL.md 0x30).
    static func read(_ r: inout ByteReader) throws -> AudioPrefs {
        let enabled = try r.u8()
        let codec = try r.u8()
        try r.skip(2)
        return AudioPrefs(enabled: enabled == 1, codecWire: codec)
    }
}

/// `AUDIO_CONFIG` (H->C, 0x31): an audio stream started or stopped.
public struct AudioConfig: Equatable, Sendable {
    public var streamID: UInt16
    public var state: AudioState
    public var format: AudioFormat
    public var sampleRate: UInt32
    public var channels: UInt8
    /// Typical packet length in frames; informational, every packet carries its own `frame_count`.
    public var framesPerPacket: UInt16

    public init(streamID: UInt16, state: AudioState, format: AudioFormat, sampleRate: UInt32, channels: UInt8,
                framesPerPacket: UInt16) {
        self.streamID = streamID
        self.state = state
        self.format = format
        self.sampleRate = sampleRate
        self.channels = channels
        self.framesPerPacket = framesPerPacket
    }

    /// `STOPPED` for `streamID`; the other fields are 0 (PROTOCOL.md 0x31).
    public static func stopped(streamID: UInt16) -> AudioConfig {
        AudioConfig(streamID: streamID, state: .stopped, format: AudioFormat(rawValue: 0), sampleRate: 0, channels: 0,
                    framesPerPacket: 0)
    }

    func write(_ w: inout ByteWriter) {
        w.u16(streamID)
        w.u8(state.rawValue)
        w.u8(format.rawValue)
        w.u32(sampleRate)
        w.u8(channels)
        w.u8(0)
        w.u16(framesPerPacket)
    }

    /// Unknown `state`/`format` are kept, not rejected (PROTOCOL.md 0x31).
    static func read(_ r: inout ByteReader) throws -> AudioConfig {
        let streamID = try r.u16()
        let state = AudioState(rawValue: try r.u8())
        let format = AudioFormat(rawValue: try r.u8())
        let sampleRate = try r.u32()
        let channels = try r.u8()
        try r.skip(1)
        let framesPerPacket = try r.u16()
        return AudioConfig(streamID: streamID, state: state, format: format, sampleRate: sampleRate,
                           channels: channels, framesPerPacket: framesPerPacket)
    }
}

/// `AUDIO_FRAME` (H->C, 0x32): one PCM packet. `data_len` on the wire is `data.count`.
public struct AudioFrame: Equatable, Sendable {
    /// Fixed part before `data`: stream_id, reserved, seq, sample_index, capture_time_us, frame_count, data_len.
    public static let fixedSize = 28

    public var streamID: UInt16
    public var seq: UInt32
    /// Index of the packet's first frame in the stream; a jump means the host dropped that range.
    public var sampleIndex: UInt64
    /// Host monotonic time of the first frame, same clock as `VIDEO_FRAME.capture_time_us`.
    public var captureTimeUs: UInt64
    /// Frames in this packet, 1...1024 (always 1024 for AAC_LC).
    public var frameCount: UInt16
    /// PCM samples. Never log.
    public var data: [UInt8]

    public init(streamID: UInt16, seq: UInt32, sampleIndex: UInt64, captureTimeUs: UInt64, frameCount: UInt16,
                data: [UInt8]) {
        self.streamID = streamID
        self.seq = seq
        self.sampleIndex = sampleIndex
        self.captureTimeUs = captureTimeUs
        self.frameCount = frameCount
        self.data = data
    }

    func write(_ w: inout ByteWriter) {
        w.u16(streamID)
        w.u16(0)
        w.u32(seq)
        w.u64(sampleIndex)
        w.u64(captureTimeUs)
        w.u16(frameCount)
        w.u16(UInt16(clamping: data.count))
        w.raw(data)
    }

    /// `frame_count` outside 1...1024 or a payload shorter than the fixed part + `data_len` is a protocol error.
    /// Trailing bytes are future fields and ignored.
    static func read(_ r: inout ByteReader) throws -> AudioFrame {
        let streamID = try r.u16()
        try r.skip(2)
        let seq = try r.u32()
        let sampleIndex = try r.u64()
        let captureTimeUs = try r.u64()
        let frameCount = try r.u16()
        let dataLen = Int(try r.u16())
        guard (1...ProtocolConstants.audioMaxFrames).contains(Int(frameCount)) else {
            throw ProtocolError.invalidField("frame_count")
        }
        return AudioFrame(streamID: streamID, seq: seq, sampleIndex: sampleIndex, captureTimeUs: captureTimeUs,
                          frameCount: frameCount, data: try r.raw(dataLen))
    }
}
