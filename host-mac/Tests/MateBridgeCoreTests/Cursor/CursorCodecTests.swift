import Testing
@testable import MateBridgeCore

// Local cursor messages (decision 0036, PROTOCOL.md 0x0B-0x0D): edge cases the golden fixtures (FixtureTests) do not
// cover. The valid and the invalid golden vectors are in FixtureTests.

private func frame(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [type]
    for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: UInt32(payload.count) >> (8 * UInt32(i)))) }
    return out + payload
}

private func decodeOne(_ bytes: [UInt8]) throws -> Message? {
    var d = FrameDecoder(connection: .control)
    var offset = 0
    while offset < bytes.count {
        let end = min(offset + FrameDecoder.maxReadChunk, bytes.count)
        d.append(Array(bytes[offset..<end]))
        offset = end
    }
    return try d.nextMessage()
}

private func shapePayload(dataLen: Int, declared: Int? = nil, format: UInt8 = 1) -> [UInt8] {
    var p: [UInt8] = [0x67, 0xaa, 0xba, 0x67, 0x90, 0, 0x20, 1, 0x40, 0, 0x90, 0, format, 0]
    let n = declared ?? dataLen
    p += [UInt8(n & 0xff), UInt8(n >> 8)]
    return p + [UInt8](repeating: 0xab, count: dataLen)
}

@Suite struct CursorCodecTests {
    @Test func typeCodesAndCapabilityBit() {
        #expect(MessageType.cursorPrefs.rawValue == 0x0B)
        #expect(MessageType.cursorShape.rawValue == 0x0C)
        #expect(MessageType.cursorState.rawValue == 0x0D)
        #expect(Capabilities.localCursor.rawValue == 1 << 13)
        #expect(CursorShape.maxDataBytes == 61_440)
        #expect(CursorState.size == 22)
        #expect(CursorShape.fixedSize == 16)
    }

    @Test func prefsUnknownEnabledValueIsOff() throws {
        #expect(try decodeOne(frame(0x0B, [2, 0, 0, 0])) == .cursorPrefs(CursorPrefs(enabled: false)))
        #expect(try decodeOne(frame(0x0B, [255, 9, 9, 9])) == .cursorPrefs(CursorPrefs(enabled: false)))
        #expect(try decodeOne(frame(0x0B, [1, 9, 9, 9])) == .cursorPrefs(CursorPrefs(enabled: true)))
    }

    @Test func prefsShortPayloadIsAProtocolError() {
        #expect(throws: ProtocolError.payloadTooShort(type: 0x0B)) { try decodeOne(frame(0x0B, [1, 0, 0])) }
    }

    @Test func prefsIgnoresTrailingBytes() throws {
        #expect(try decodeOne(frame(0x0B, [1, 0, 0, 0, 7, 7])) == .cursorPrefs(CursorPrefs(enabled: true)))
    }

    @Test func stateUnknownVisibleValueIsHidden() throws {
        var p = Message.cursorState(CursorState(seq: 1, x: 2, y: 3, visible: true, shapeID: 4, hostTimeUs: 5))
            .encodePayload()
        p[8] = 2  // visible
        guard case .cursorState(let s)? = try decodeOne(frame(0x0D, p)) else {
            Issue.record("not CURSOR_STATE")
            return
        }
        #expect(!s.visible)
        #expect(s.seq == 1 && s.x == 2 && s.y == 3 && s.shapeID == 4 && s.hostTimeUs == 5)
    }

    @Test func stateShortPayloadIsAProtocolError() {
        let p = Message.cursorState(CursorState(seq: 1, x: 2, y: 3, visible: true, shapeID: 4, hostTimeUs: 5))
            .encodePayload()
        #expect(p.count == CursorState.size)
        #expect(throws: ProtocolError.payloadTooShort(type: 0x0D)) { try decodeOne(frame(0x0D, Array(p.dropLast()))) }
    }

    @Test func stateExtremesRoundTrip() throws {
        let s = CursorState(seq: .max, x: .max, y: 0, visible: false, shapeID: .max, hostTimeUs: .max)
        #expect(try decodeOne(Message.cursorState(s).encode()) == .cursorState(s))
    }

    @Test func shapeUnknownFormatDecodes() throws {
        guard case .cursorShape(let s)? = try decodeOne(frame(0x0C, shapePayload(dataLen: 5, format: 9))) else {
            Issue.record("not CURSOR_SHAPE")
            return
        }
        #expect(s.format == CursorShapeFormat(rawValue: 9))
        #expect(s.data.count == 5)
    }

    @Test func shapeDataLengthZeroIsAProtocolError() {
        #expect(throws: ProtocolError.invalidField("data_len")) { try decodeOne(frame(0x0C, shapePayload(dataLen: 0))) }
    }

    @Test func shapeDataLengthAboveTheLimitIsAProtocolError() {
        let p = shapePayload(dataLen: 8, declared: 61_441)
        #expect(throws: ProtocolError.invalidField("data_len")) { try decodeOne(frame(0x0C, p)) }
    }

    @Test func shapeAtTheLimitRoundTrips() throws {
        let shape = CursorShape(shapeID: 7, widthPt16: 100, heightPt16: 200, hotXPt16: 1, hotYPt16: 2,
                                data: [UInt8](repeating: 0x5a, count: CursorShape.maxDataBytes))
        let bytes = try Message.cursorShape(shape).encode()
        #expect(bytes.count == 5 + 16 + 61_440)
        #expect(try decodeOne(bytes) == .cursorShape(shape))
    }

    @Test func shapeIgnoresTrailingBytes() throws {
        var p = shapePayload(dataLen: 4)
        p += [1, 2, 3]
        guard case .cursorShape(let s)? = try decodeOne(frame(0x0C, p)) else {
            Issue.record("not CURSOR_SHAPE")
            return
        }
        #expect(s.data == [0xab, 0xab, 0xab, 0xab])
    }

    @Test func encodingAnEmptyOrOversizeShapeThrows() {
        let empty = CursorShape(shapeID: 1, widthPt16: 1, heightPt16: 1, hotXPt16: 0, hotYPt16: 0, data: [])
        let big = CursorShape(shapeID: 1, widthPt16: 1, heightPt16: 1, hotXPt16: 0, hotYPt16: 0,
                              data: [UInt8](repeating: 0, count: CursorShape.maxDataBytes + 1))
        #expect(throws: ProtocolError.invalidField("data_len")) { try Message.cursorShape(empty).encode() }
        #expect(throws: ProtocolError.invalidField("data_len")) { try Message.cursorShape(big).encode() }
    }

    @Test func allThreeAreControlConnectionMessages() {
        #expect(Message.cursorPrefs(CursorPrefs(enabled: true)).connection == .control)
        #expect(Message.cursorShape(CursorShape(shapeID: 1, widthPt16: 1, heightPt16: 1, hotXPt16: 0, hotYPt16: 0,
                                                data: [1])).connection == .control)
        #expect(Message.cursorState(CursorState(seq: 0, x: 0, y: 0, visible: false, shapeID: 0, hostTimeUs: 0))
            .connection == .control)
    }
}
