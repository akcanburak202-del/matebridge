import Testing
@testable import MateBridgeCore

private func frame(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
    var w = ByteWriter()
    w.u8(type)
    w.u32(UInt32(payload.count))
    w.raw(payload)
    return w.bytes
}

private func penPayload(tool: UInt8 = 0, count: UInt8, dts: [UInt32]) -> [UInt8] {
    var w = ByteWriter()
    w.u8(tool)
    w.u8(count)
    w.u16(0)
    w.u64(0)
    for dt in dts {
        w.u32(dt)
        w.raw([UInt8](repeating: 0, count: 12))
    }
    return w.bytes
}

private func decodeOne(_ bytes: [UInt8], _ c: FrameDecoder.Connection = .control) throws -> Message? {
    var d = FrameDecoder(connection: c)
    d.append(bytes)
    return try d.nextMessage()
}

@Suite struct CodecTests {
    @Test func penRejectsBadToolCountAndDecreasingTime() throws {
        #expect(throws: ProtocolError.invalidField("tool")) { try decodeOne(frame(0x10, penPayload(tool: 2, count: 1, dts: [0]))) }
        #expect(throws: ProtocolError.invalidField("count")) { try decodeOne(frame(0x10, penPayload(count: 65, dts: []))) }
        #expect(throws: ProtocolError.decreasingSampleTime) { try decodeOne(frame(0x10, penPayload(count: 2, dts: [5, 4]))) }
        #expect(throws: ProtocolError.payloadTooShort(type: 0x10)) { try decodeOne(frame(0x10, penPayload(count: 2, dts: [1]))) }
        #expect(try decodeOne(frame(0x10, penPayload(count: 2, dts: [4, 4]))) != nil)
    }

    @Test func penAcceptsMaxCount() throws {
        let dts = (0..<64).map { UInt32($0) }
        guard case .pen(let batch) = try decodeOne(frame(0x10, penPayload(count: 64, dts: dts))) else {
            Issue.record("not a pen batch")
            return
        }
        #expect(batch.samples.count == 64)
    }

    @Test func keyRejectsInvalidAction() {
        var w = ByteWriter()
        w.u64(0); w.u16(30); w.u16(29); w.u8(2); w.u8(0); w.u16(0)
        #expect(throws: ProtocolError.invalidField("action")) { try decodeOne(frame(0x11, w.bytes)) }
    }

    @Test func nonFiniteFloatsAreRejected() {
        for bad in [Float.nan, .infinity, -.infinity] {
            var w = ByteWriter()
            w.u64(0); w.u32(bad.bitPattern); w.u32(0); w.u8(0); w.u8(0); w.u16(0)
            #expect(throws: ProtocolError.nonFiniteFloat("dx")) { try decodeOne(frame(0x12, w.bytes)) }
            #expect(throws: ProtocolError.nonFiniteFloat("dx")) { try decodeOne(frame(0x14, w.bytes)) }
        }
    }

    @Test func invalidEnumsAreRejected() {
        var scroll = ByteWriter()
        scroll.u64(0); scroll.f32(0); scroll.f32(0); scroll.u8(9); scroll.u8(0); scroll.u16(0)
        #expect(throws: ProtocolError.invalidField("phase")) { try decodeOne(frame(0x14, scroll.bytes)) }
        var ack = ByteWriter()
        ack.u16(0); ack.u8(9); ack.u8(0); ack.u32(0); ack.u16(0); ack.u8(0)
        #expect(throws: ProtocolError.invalidField("status")) { try decodeOne(frame(0x02, ack.bytes)) }
    }

    @Test func unknownGestureAndReasonsAreTolerated() throws {
        var w = ByteWriter()
        w.u64(1); w.u8(77); w.u8(0); w.u16(0)
        #expect(try decodeOne(frame(0x15, w.bytes)) == .penGesture(PenGesture(timeUs: 1, gesture: PenGestureKind(rawValue: 77))))
        #expect(try decodeOne(frame(0x16, [200])) == .releaseAll(ReleaseReason(rawValue: 200)))
    }

    @Test func longerPayloadIsAcceptedShorterIsNot() throws {
        let ping = Message.ping(Ping(seq: 1, senderTimeUs: 2))
        #expect(try decodeOne(frame(0x20, ping.encodePayload() + [1, 2, 3])) == ping)
        #expect(throws: ProtocolError.payloadTooShort(type: 0x20)) { try decodeOne(frame(0x20, [1, 2, 3])) }
    }

    @Test func payloadLimitsPerConnection() throws {
        var control = FrameDecoder(connection: .control)
        control.append([0x7f, 0x01, 0x00, 0x01, 0x00])  // 65537
        #expect(throws: ProtocolError.payloadTooLarge(length: 65537, limit: 65536)) { try control.nextMessage() }

        var atLimit = FrameDecoder(connection: .control)
        let big = frame(0x7f, [UInt8](repeating: 0, count: 65536))
        atLimit.append(big[..<30_000])
        atLimit.append(big[30_000...])
        #expect(try atLimit.nextMessage() == nil)

        var video = FrameDecoder(connection: .video)
        video.append([0x41, 0x01, 0x00, 0x00, 0x01])  // 16777217
        #expect(throws: ProtocolError.payloadTooLarge(length: 16_777_217, limit: 16_777_216)) { try video.nextMessage() }
    }

    @Test func str8Handling() throws {
        var long = ByteWriter()
        long.str8(String(repeating: "ğ", count: 40))  // 80 bytes, cut to 64 on a boundary
        #expect(long.bytes[0] == 64)
        #expect(String(decoding: long.bytes.dropFirst(), as: UTF8.self) == String(repeating: "ğ", count: 32))

        var ack = ByteWriter()
        ack.u16(0); ack.u8(0); ack.u8(0); ack.u32(1); ack.u16(1); ack.u8(65); ack.raw([UInt8](repeating: 0x61, count: 65))
        #expect(throws: ProtocolError.invalidField("str8 length")) { try decodeOne(frame(0x02, ack.bytes)) }
        var overrun = ByteWriter()
        overrun.u16(0); overrun.u8(0); overrun.u8(0); overrun.u32(1); overrun.u16(1); overrun.u8(10); overrun.raw([0x61])
        #expect(throws: ProtocolError.payloadTooShort(type: 0x02)) { try decodeOne(frame(0x02, overrun.bytes)) }
    }

    @Test func keyIdentity() {
        func id(_ s: UInt16, _ a: UInt16) -> UInt32? {
            KeyEvent(timeUs: 0, scanCode: s, androidKeyCode: a, action: .down, capsLockOn: false).keyIdentity
        }
        #expect(id(30, 29) == 30)
        #expect(id(0, 85) == 0x10055)
        #expect(id(0, 0) == nil)
    }

    @Test func penFlagsNormalization() {
        #expect(PenFlags.contact.normalized == [])
        #expect(PenFlags([.contact, .strokeStart]).normalized == [])
        #expect(PenFlags([.inRange, .contact]).normalized == [.inRange, .contact])
    }

    @Test func coordinateMapping() {
        #expect(NormalizedCoord.encode(px: 0, surface: 2800) == 0)
        #expect(NormalizedCoord.encode(px: 2800, surface: 2800) == 65535)
        #expect(NormalizedCoord.encode(px: -50, surface: 2800) == 0)
        #expect(NormalizedCoord.encode(px: 9999, surface: 2800) == 65535)
        #expect(NormalizedCoord.encode(px: 1400, surface: 2800) == 32768)  // 32767.5 rounds up
        #expect(NormalizedCoord.encode(px: .nan, surface: 2800) == 0)
        #expect(NormalizedCoord.encode(px: 1, surface: 0) == 0)

        #expect(NormalizedCoord.toPoints(0, origin: 100, extent: 1400, scale: 2) == 100)
        #expect(NormalizedCoord.toPoints(65535, origin: 100, extent: 1400, scale: 2) == 100 + 1400 - 0.5)
        #expect(NormalizedCoord.toPoints(65535, origin: -1400, extent: 1400, scale: 2) == -0.5)
        let mid = NormalizedCoord.toPoints(32768, origin: 0, extent: 1400, scale: 2)
        #expect(abs(mid - 700.01) < 0.01)
    }

    @Test func pressureAndTilt() {
        #expect(PressureCodec.encode(0) == 0)
        #expect(PressureCodec.encode(1) == 65535)
        #expect(PressureCodec.encode(2) == 65535)
        #expect(PressureCodec.encode(-1) == 0)
        #expect(PressureCodec.encode(.infinity) == 0)
        #expect(PressureCodec.decode(65535) == 1)
        #expect(TiltCodec.encode(1) == 32767)
        #expect(TiltCodec.encode(-1) == -32767)
        #expect(TiltCodec.encode(-5) == -32767)
        #expect(TiltCodec.encode(0.5) == 16384)
        #expect(TiltCodec.decode(-32768) == -1)
        #expect(TiltCodec.decode(32767) == 1)
        #expect(TiltCodec.decode(0) == 0)
    }

    @Test func roundingIsHalfAwayFromZero() {
        // Exact ties: 0.5 * 65535 / 65535 etc. must round away from zero, never to even.
        #expect(PressureCodec.encode(0.5 / 65535) == 1)
        #expect(PressureCodec.encode(1.5 / 65535) == 2)
        #expect(PressureCodec.encode(2.5 / 65535) == 3)
        #expect(TiltCodec.encode(0.5 / 32767) == 1)
        #expect(TiltCodec.encode(-0.5 / 32767) == -1)
        #expect(TiltCodec.encode(2.5 / 32767) == 3)
        #expect(TiltCodec.encode(-2.5 / 32767) == -3)
        #expect(NormalizedCoord.encode(px: 0.5, surface: 65535) == 1)
        #expect(NormalizedCoord.encode(px: 2.5, surface: 65535) == 3)
        #expect(NormalizedCoord.encode(px: 1, surface: 131_070) == 1)
    }

    @Test func videoFrameFragmentFieldsAreValidated() throws {
        func videoPayload(index: UInt16 = 0, count: UInt16 = 1, size: UInt32 = 4, data: Int = 4) -> [UInt8] {
            var w = ByteWriter()
            w.u32(0); w.u64(0); w.u8(0); w.u8(0); w.u16(index); w.u16(count); w.u16(0); w.u32(size)
            w.raw([UInt8](repeating: 1, count: data))
            return w.bytes
        }
        #expect(try decodeOne(frame(0x41, videoPayload()), .video) != nil)
        // Trailing bytes after frame_size bytes of data are future fields.
        if case .videoFrame(let f)? = try decodeOne(frame(0x41, videoPayload(size: 3)), .video) {
            #expect(f.data == [1, 1, 1] && f.frameSize == 3)
        } else {
            Issue.record("expected video frame")
        }
        for bad in [videoPayload(index: 1), videoPayload(count: 2), videoPayload(count: 0),
                    videoPayload(size: 5)] {
            #expect(throws: ProtocolError.invalidField("video fragment")) { try decodeOne(frame(0x41, bad), .video) }
        }
    }

    @Test func encodersRefuseOversizedAndInvalidMessages() throws {
        // 24-byte VIDEO_FRAME header counts toward the 16 MiB limit.
        let maxData = ProtocolConstants.maxVideoPayload - 24
        let fits = Message.videoFrame(VideoFrame(frameSeq: 0, captureTimeUs: 0, flags: [], data: [UInt8](repeating: 0, count: maxData)))
        #expect(try fits.encode().count == ProtocolConstants.headerSize + ProtocolConstants.maxVideoPayload)
        let over = Message.videoFrame(VideoFrame(frameSeq: 0, captureTimeUs: 0, flags: [], data: [UInt8](repeating: 0, count: maxData + 1)))
        #expect(throws: ProtocolError.payloadTooLarge(length: UInt32(ProtocolConstants.maxVideoPayload + 1), limit: ProtocolConstants.maxVideoPayload)) {
            try over.encode()
        }
        let sample = PenSample(dtUs: 0, x: 0, y: 0, pressure: 0, tiltX: 0, tiltY: 0, flags: [])
        #expect(throws: ProtocolError.invalidField("count")) { try Message.pen(PenBatch(tool: .pen, baseTimeUs: 0, samples: [])).encode() }
        #expect(throws: ProtocolError.invalidField("count")) {
            try Message.pen(PenBatch(tool: .pen, baseTimeUs: 0, samples: Array(repeating: sample, count: 65))).encode()
        }
        let mismatched = VideoFrame(frameSeq: 0, captureTimeUs: 0, flags: [], fragmentIndex: 0, fragmentCount: 1, frameSize: 9, data: [1])
        #expect(throws: ProtocolError.invalidField("video fragment")) { try Message.videoFrame(mismatched).encode() }
    }

    @Test func oversizedHeaderIsRejectedWithoutBufferingPayload() throws {
        // Only the 5 header bytes are present; the limit fires immediately.
        var control = FrameDecoder(connection: .control)
        control.append([0x10, 0xff, 0xff, 0xff, 0xff])
        #expect(throws: ProtocolError.payloadTooLarge(length: UInt32.max, limit: 65536)) { try control.nextMessage() }
        #expect(control.bufferedCount == 0)

        // Header split across appends is checked as soon as the 5th byte arrives.
        var video = FrameDecoder(connection: .video)
        video.append([0x41, 0x01, 0x00])
        #expect(try video.nextMessage() == nil)
        video.append([0x00, 0x01])
        #expect(throws: ProtocolError.payloadTooLarge(length: 16_777_217, limit: 16_777_216)) { try video.nextMessage() }
    }

    @Test func bufferStaysBoundedWhenCallerDoesNotDrain() throws {
        var d = FrameDecoder(connection: .control)
        let chunk = [UInt8](repeating: 0, count: 40_000)
        d.append([0x7f, 0x00, 0x00, 0x01, 0x00])  // 65536-byte unknown frame, payload pending
        for _ in 0..<30 { d.append(chunk) }  // never drained, 1.2 MB
        #expect(throws: ProtocolError.bufferOverflow) { try d.nextMessage() }
        #expect(throws: ProtocolError.decoderFailed) { try d.nextMessage() }
        #expect(d.bufferedCount == 0)
    }

    @Test func appendHonorsSliceIndices() throws {
        let ping = Message.ping(Ping(seq: 3, senderTimeUs: 4))
        let bytes = try ping.encode()
        let padded = [UInt8](repeating: 0xEE, count: 7) + bytes + [0xEE, 0xEE]
        var d = FrameDecoder(connection: .control)
        d.append(padded[7..<(7 + bytes.count)])
        #expect(try d.nextMessage() == ping)
    }

    @Test func slicedFeedProducesSameMessages() throws {
        let ping = Message.ping(Ping(seq: 3, senderTimeUs: 4))
        let bytes = try ping.encode() + ping.encode()
        let big = [UInt8](repeating: 0, count: 100) + bytes
        var d = FrameDecoder(connection: .control)
        d.append(big[100..<(100 + 10)])
        d.append(big[110...])
        #expect(try d.nextMessage() == ping)
        #expect(try d.nextMessage() == ping)
        #expect(try d.nextMessage() == nil)
    }

    @Test func unknownColorCodesAndUndefinedBitsAreAccepted() throws {
        var w = ByteWriter()
        w.u16(1); w.u8(1); w.u8(0); w.u16(10); w.u16(10); w.u16(5); w.u16(5); w.u16(60); w.u32(1000)
        w.u8(99); w.u8(98); w.u8(97); w.u8(1)
        guard case .streamConfig(let c) = try decodeOne(frame(0x03, w.bytes)) else { Issue.record("not config"); return }
        #expect(c.colorPrimaries == 99 && c.transfer == 98 && c.matrix == 97)
        #expect(throws: ProtocolError.invalidField("codec")) {
            var b = w.bytes; b[2] = 9
            return try decodeOne(frame(0x03, b))
        }
        // Undefined capability and pen flag bits do not fail decoding.
        var pen = ByteWriter()
        pen.u8(0); pen.u8(1); pen.u16(0); pen.u64(0)
        pen.u32(0); pen.u16(0); pen.u16(0); pen.u16(0); pen.i16(0); pen.i16(0); pen.u8(0xF1); pen.u8(0)
        #expect(try decodeOne(frame(0x10, pen.bytes)) != nil)
        var hello = ByteWriter()
        hello.u16(1); hello.raw([UInt8](repeating: 1, count: 16)); hello.u16(1); hello.u16(1); hello.u16(1); hello.u16(1)
        hello.u32(0xFFFF_FF00); hello.u8(0)
        hello.raw([UInt8](repeating: 2, count: 16)); hello.raw([4] + [UInt8](repeating: 3, count: 64))
        #expect(try decodeOne(frame(0x01, hello.bytes)) != nil)
    }

    @Test func oversizedHeaderInLargeInputIsNotBuffered() throws {
        var d = FrameDecoder(connection: .control)
        var first = [UInt8](repeating: 0xAB, count: 65_536)
        first.replaceSubrange(0..<5, with: [0x10, 0xff, 0xff, 0xff, 0x7f])
        d.append(first)
        #expect(d.bufferedCount == 5)  // only the offending header is kept
        for _ in 0..<150 { d.append([UInt8](repeating: 0xAB, count: 65_536)) }  // ~10 MB total, dropped
        #expect(d.bufferedCount == 5)
        #expect(throws: ProtocolError.payloadTooLarge(length: 0x7fff_ffff, limit: 65536)) { try d.nextMessage() }

        // A valid frame before the bad header is still delivered first.
        let ping = Message.ping(Ping(seq: 1, senderTimeUs: 2))
        var d2 = FrameDecoder(connection: .control)
        d2.append(try ping.encode())
        d2.append(first)
        #expect(try d2.nextMessage() == ping)
        #expect(throws: ProtocolError.payloadTooLarge(length: 0x7fff_ffff, limit: 65536)) { try d2.nextMessage() }
    }

    @Test func appendAcceptsAtMost64KiBPerCall() {
        var d = FrameDecoder(connection: .control)
        d.append([UInt8](repeating: 0, count: 10_000_000))
        #expect(throws: ProtocolError.chunkTooLarge) { try d.nextMessage() }
        #expect(throws: ProtocolError.decoderFailed) { try d.nextMessage() }
    }

    @Test func fullChunkOfSmallFramesDrainsWithoutOverflow() throws {
        let ping = Message.ping(Ping(seq: 9, senderTimeUs: 1))
        let one = try ping.encode()  // 17 bytes
        let count = 65_536 / one.count
        var stream: [UInt8] = []
        for _ in 0..<count { stream += one }
        var d = FrameDecoder(connection: .control)
        var drained = 0
        for _ in 0..<20 {  // consumed bytes do not count toward the cap
            d.append(stream)
            while let m = try d.nextMessage() {
                #expect(m == ping)
                drained += 1
            }
        }
        #expect(drained == count * 20)
        #expect(d.bufferedCount == 0)
    }

    @Test func videoFrameShortDataIsProtocolError() {
        var w = ByteWriter()
        w.u32(0); w.u64(0); w.u8(0); w.u8(0); w.u16(0); w.u16(1); w.u16(0); w.u32(10); w.raw([1, 2, 3])
        #expect(throws: ProtocolError.invalidField("video fragment")) { try decodeOne(frame(0x41, w.bytes), .video) }
    }

    @Test func penEncoderRejectsDecreasingTime() {
        let a = PenSample(dtUs: 5, x: 0, y: 0, pressure: 0, tiltX: 0, tiltY: 0, flags: [])
        var b = a
        b.dtUs = 4
        #expect(throws: ProtocolError.decreasingSampleTime) {
            try Message.pen(PenBatch(tool: .pen, baseTimeUs: 0, samples: [a, b])).encode()
        }
    }
}
