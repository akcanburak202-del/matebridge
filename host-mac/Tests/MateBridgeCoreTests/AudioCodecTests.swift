import Testing
@testable import MateBridgeCore

/// Audio message rules from docs/PROTOCOL.md 0x30-0x32 that the fixtures do not cover directly.
@Suite struct AudioCodecTests {
    private func frame(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var w = ByteWriter()
        w.u8(type)
        w.u32(UInt32(payload.count))
        w.raw(payload)
        return w.bytes
    }

    private func decodeOne(_ bytes: [UInt8]) throws -> Message? {
        var d = FrameDecoder(connection: .control)
        d.append(bytes)
        return try d.nextMessage()
    }

    private func audioFramePayload(frameCount: UInt16, dataLen: UInt16, dataBytes: Int, trailing: [UInt8] = [])
        -> [UInt8] {
        var w = ByteWriter()
        w.u16(9)                 // stream_id
        w.u16(0)                 // reserved
        w.u32(1)                 // seq
        w.u64(480)               // sample_index
        w.u64(1_000_000)         // capture_time_us
        w.u16(frameCount)
        w.u16(dataLen)
        w.raw([UInt8](repeating: 0x11, count: dataBytes))
        w.raw(trailing)
        return w.bytes
    }

    @Test func messageTypesAndCapabilityBit() {
        #expect(MessageType.audioPrefs.rawValue == 0x30)
        #expect(MessageType.audioConfig.rawValue == 0x31)
        #expect(MessageType.audioFrame.rawValue == 0x32)
        #expect(Capabilities.audioPCM.rawValue == 0x100)
        #expect(AudioFrame.fixedSize == 28)
        #expect(Message.audioFrame(AudioFrame(streamID: 1, seq: 0, sampleIndex: 0, captureTimeUs: 0, frameCount: 1,
                                              data: [0, 0, 0, 0])).connection == .control)
    }

    @Test(arguments: [UInt8(0), 2, 0x7f, 0xff])
    func prefsEnabledOtherThanOneIsFalse(raw: UInt8) throws {
        #expect(try decodeOne(frame(0x30, [raw, 0, 0, 0])) == .audioPrefs(AudioPrefs(enabled: false)))
    }

    @Test func prefsEncodeDisabled() throws {
        #expect(try Message.audioPrefs(AudioPrefs(enabled: false)).encode() == [0x30, 4, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func prefsShortPayloadIsAnError() {
        #expect(throws: ProtocolError.payloadTooShort(type: 0x30)) { try decodeOne(frame(0x30, [1, 0, 0])) }
    }

    @Test func configKeepsUnknownStateAndFormat() throws {
        var w = ByteWriter()
        w.u16(5); w.u8(7); w.u8(9); w.u32(44100); w.u8(6); w.u8(0); w.u16(256)
        let expected = AudioConfig(streamID: 5, state: AudioState(rawValue: 7), format: AudioFormat(rawValue: 9),
                                   sampleRate: 44100, channels: 6, framesPerPacket: 256)
        #expect(try decodeOne(frame(0x31, w.bytes)) == .audioConfig(expected))
        #expect(try Message.audioConfig(expected).encode() == frame(0x31, w.bytes))
    }

    @Test func configShortPayloadIsAnError() {
        #expect(throws: ProtocolError.payloadTooShort(type: 0x31)) {
            try decodeOne(frame(0x31, [UInt8](repeating: 0, count: 11)))
        }
    }

    @Test(arguments: [UInt16(0), 961, 0xffff])
    func frameCountOutOfRangeIsAnError(count: UInt16) {
        #expect(throws: ProtocolError.invalidField("frame_count")) {
            try decodeOne(frame(0x32, audioFramePayload(frameCount: count, dataLen: 4, dataBytes: 4)))
        }
    }

    @Test func frameCountLimitsAccepted() throws {
        let one = try decodeOne(frame(0x32, audioFramePayload(frameCount: 1, dataLen: 4, dataBytes: 4)))
        guard case .audioFrame(let a)? = one else { Issue.record("not an audio frame"); return }
        #expect(a.frameCount == 1 && a.data.count == 4)
        let max = try decodeOne(frame(0x32, audioFramePayload(frameCount: 960, dataLen: 3840, dataBytes: 3840)))
        guard case .audioFrame(let b)? = max else { Issue.record("not an audio frame"); return }
        #expect(b.frameCount == 960 && b.data.count == 3840)
    }

    @Test func frameShortDataIsAnError() {
        #expect(throws: ProtocolError.payloadTooShort(type: 0x32)) {
            try decodeOne(frame(0x32, audioFramePayload(frameCount: 4, dataLen: 16, dataBytes: 15)))
        }
        #expect(throws: ProtocolError.payloadTooShort(type: 0x32)) {
            try decodeOne(frame(0x32, Array(audioFramePayload(frameCount: 4, dataLen: 0, dataBytes: 0).prefix(27))))
        }
    }

    @Test func frameTrailingBytesIgnored() throws {
        let payload = audioFramePayload(frameCount: 2, dataLen: 8, dataBytes: 8, trailing: [0xaa, 0xbb, 0xcc])
        guard case .audioFrame(let m)? = try decodeOne(frame(0x32, payload)) else {
            Issue.record("not an audio frame"); return
        }
        #expect(m.data == [UInt8](repeating: 0x11, count: 8))
        #expect(m.streamID == 9 && m.seq == 1 && m.sampleIndex == 480 && m.captureTimeUs == 1_000_000)
    }

    /// data_len that does not match frame_count x channels x 2 is the client's to drop, not a protocol error.
    @Test func frameDataLenMismatchDecodes() throws {
        #expect(try decodeOne(frame(0x32, audioFramePayload(frameCount: 4, dataLen: 6, dataBytes: 6))) != nil)
    }

    @Test func encodeRejectsInvalidFrames() {
        #expect(throws: ProtocolError.invalidField("frame_count")) {
            try Message.audioFrame(AudioFrame(streamID: 1, seq: 0, sampleIndex: 0, captureTimeUs: 0, frameCount: 0,
                                              data: [])).encode()
        }
        #expect(throws: ProtocolError.invalidField("frame_count")) {
            try Message.audioFrame(AudioFrame(streamID: 1, seq: 0, sampleIndex: 0, captureTimeUs: 0, frameCount: 961,
                                              data: [])).encode()
        }
        #expect(throws: ProtocolError.invalidField("data_len")) {
            try Message.audioFrame(AudioFrame(streamID: 1, seq: 0, sampleIndex: 0, captureTimeUs: 0, frameCount: 960,
                                              data: [UInt8](repeating: 0, count: 65_536))).encode()
        }
    }

    @Test func fullTenMsPacketRoundTrips() throws {
        let pcm = (0..<1920).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let m = Message.audioFrame(AudioFrame(streamID: 2, seq: 100, sampleIndex: 48_000, captureTimeUs: 5,
                                              frameCount: 480, data: pcm))
        let bytes = try m.encode()
        #expect(bytes.count == ProtocolConstants.headerSize + AudioFrame.fixedSize + 1920)
        #expect(try decodeOne(bytes) == m)
    }

    @Test func hostIgnoresAudioMessagesForInput() {
        var machine = InputStateMachine()
        #expect(machine.handle(.audioPrefs(AudioPrefs(enabled: true)), now: 1).isEmpty)
    }
}
