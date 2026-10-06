import Testing
@testable import MateBridgeCore

// Wi-Fi tablet files messages (decision 0035, PROTOCOL.md 0x09 STANDBY, 0x0A, 0x50-0x52): edge cases the golden
// fixtures (FixtureTests) do not cover.

private func frame(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [type]
    for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: UInt32(payload.count) >> (8 * UInt32(i)))) }
    return out + payload
}

private func decodeOne(_ bytes: [UInt8], _ connection: FrameDecoder.Connection = .files) throws -> Message? {
    var d = FrameDecoder(connection: connection)
    var offset = 0
    while offset < bytes.count {  // the receive loop hands over at most 64 KiB at a time
        let end = min(offset + FrameDecoder.maxReadChunk, bytes.count)
        d.append(Array(bytes[offset..<end]))
        offset = end
    }
    return try d.nextMessage()
}

@Suite struct FilesNetCodecTests {
    @Test func typeCodesAndCapabilityBit() {
        #expect(MessageType.filesNet.rawValue == 0x0A)
        #expect(MessageType.filesHello.rawValue == 0x50)
        #expect(MessageType.filesHelloAck.rawValue == 0x51)
        #expect(MessageType.filesData.rawValue == 0x52)
        #expect(Capabilities.filesNet.rawValue == 1 << 12)
        #expect(FilesState.standby.rawValue == 2)
        #expect(ProtocolConstants.filesDataMax == 65_534)
    }

    @Test func filesNetUnknownStateIsClose() throws {
        guard case .filesNet(let odd)? = try decodeOne(frame(0x0A, [7, 0x9b, 0xb7, 2, 12]), .control) else {
            Issue.record("not FILES_NET")
            return
        }
        #expect(odd.state == FilesNetState(rawValue: 7))
        #expect(!odd.isOpen)
        #expect(odd.port == 47003)
        #expect(FilesNet.open(port: 1).isOpen)
        #expect(!FilesNet.close.isOpen)
    }

    @Test func filesNetShortPayloadIsAProtocolError() {
        #expect(throws: ProtocolError.payloadTooShort(type: 0x0A)) { try decodeOne(frame(0x0A, [1, 0x9b, 0xb7, 2]), .control) }
    }

    @Test func filesNetIgnoresExtraTrailingBytes() throws {
        let long = try decodeOne(frame(0x0A, [1, 0x9b, 0xb7, 2, 12, 99, 98]), .control)
        #expect(long == .filesNet(FilesNet(state: .open, port: 47003, pool: 2, max: 12)))
    }

    @Test func filesNetHelperDefaultsMatchTheProtocolRecommendation() {
        #expect(FilesNet.open(port: 47003) == FilesNet(state: .open, port: 47003, pool: 2, max: 12))
        #expect(FilesNet.close == FilesNet(state: .close, port: 0, pool: 0, max: 0))
    }

    @Test func standbyIsNotReadyAndUnknownStatesStayOff() throws {
        #expect(FilesInfo.standby.isStandby)
        #expect(!FilesInfo.standby.isReady)
        // Even with a port and a token, STANDBY never counts as READY (a USB host reads it as OFF).
        let odd = FilesInfo(state: .standby, port: 47010, token: "x")
        #expect(!odd.isReady)
        #expect(!FilesInfo.off.isStandby)
        #expect(!FilesInfo(state: .ready, port: 1, token: "t").isStandby)
        let decoded = try decodeOne(frame(0x09, [2, 0, 0, 0]), .control)
        #expect(decoded == .filesInfo(.standby))
    }

    @Test func filesHelloShortIsAProtocolError() {
        for n in [0, 1, 6, 21] {
            #expect(throws: ProtocolError.payloadTooShort(type: 0x50)) {
                try decodeOne(frame(0x50, [UInt8](repeating: 0x70, count: n)))
            }
        }
    }

    @Test func filesHelloIgnoresExtraBytesAndRoundTrips() throws {
        let hello = FilesHello(sessionID: 7, clientNonce: Array(0..<16))
        let bytes = try Message.filesHello(hello).encode()
        #expect(bytes.count == 5 + 22)
        #expect(try decodeOne(bytes) == .filesHello(hello))
        let longer = frame(0x50, Array(bytes.dropFirst(5)) + [1, 2, 3])
        #expect(try decodeOne(longer) == .filesHello(hello))
    }

    @Test func unknownAckStatusIsRejected() throws {
        guard case .filesHelloAck(let ack)? = try decodeOne(frame(0x51, [9] + [UInt8](repeating: 0xaa, count: 16))) else {
            Issue.record("not an ACK")
            return
        }
        #expect(ack.status == FilesHelloStatus(rawValue: 9))
        #expect(!ack.isOK)
        #expect(FilesHelloAck(status: .ok, hostNonce: Array(0..<16)).isOK)
        #expect(!FilesHelloAck.rejected.isOK)
        #expect(FilesHelloAck.rejected.hostNonce == [UInt8](repeating: 0, count: 16))
        #expect(throws: ProtocolError.payloadTooShort(type: 0x51)) { try decodeOne(frame(0x51, [0] + Array(0..<15))) }
    }

    @Test func filesDataBounds() throws {
        // size = 0 is a protocol error, in the decoder and in the encoder.
        #expect(throws: ProtocolError.invalidField("size")) { try decodeOne(frame(0x52, [0, 0])) }
        #expect(throws: ProtocolError.invalidField("size")) { try Message.filesData(FilesData(data: [])).encode() }
        // 1 byte and the 65 534-byte maximum round-trip; 65 535 is refused before it is built.
        for n in [1, 2, 4096, ProtocolConstants.filesDataMax] {
            let m = Message.filesData(FilesData(data: [UInt8](repeating: UInt8(n & 0xff), count: n)))
            let bytes = try m.encode()
            #expect(bytes.count == 5 + 2 + n)
            #expect(try decodeOne(bytes) == m)
        }
        #expect(throws: ProtocolError.invalidField("size")) {
            try Message.filesData(FilesData(data: [UInt8](repeating: 0, count: ProtocolConstants.filesDataMax + 1))).encode()
        }
        // A `size` larger than what follows is a short payload; bytes after `data` are ignored.
        #expect(throws: ProtocolError.payloadTooShort(type: 0x52)) { try decodeOne(frame(0x52, [5, 0, 1, 2, 3])) }
        #expect(try decodeOne(frame(0x52, [2, 0, 7, 8, 9, 9])) == .filesData(FilesData(data: [7, 8])))
    }

    @Test func fileMessagesLiveOnTheFileConnection() {
        #expect(Message.filesHello(FilesHello(sessionID: 1, clientNonce: Array(0..<16))).connection == .files)
        #expect(Message.filesHelloAck(.rejected).connection == .files)
        #expect(Message.filesData(FilesData(data: [1])).connection == .files)
        #expect(Message.filesNet(.close).connection == .control)
        #expect(FrameDecoder.Connection.files.maxPayload == ProtocolConstants.maxControlPayload)
    }

    @Test func oversizedFileFrameIsRefusedAtTheHeader() {
        var d = FrameDecoder(connection: .files)
        var header: [UInt8] = [0x52]
        let length = UInt32(ProtocolConstants.maxControlPayload + 1)
        for i in 0..<4 { header.append(UInt8(truncatingIfNeeded: length >> (8 * UInt32(i)))) }
        d.append(header)
        #expect(throws: ProtocolError.payloadTooLarge(length: length, limit: ProtocolConstants.maxControlPayload)) {
            try d.nextMessage()
        }
    }

    @Test func fileMessagesOnTheControlConnectionAreIgnoredBySessionAndInputState() {
        // Wrong connection for a known type: the session machine ignores it and the input machine does nothing.
        var machine = InputStateMachine()
        let actions = machine.handle(.filesData(FilesData(data: [1])), now: 0)
        #expect(actions.isEmpty)
    }

    @Test func peerAddressesAreComparedWithoutScopeOrMapping() {
        #expect(FilesPeer.same("192.168.1.20", "192.168.1.20"))
        #expect(FilesPeer.same("::ffff:192.168.1.20", "192.168.1.20"))
        #expect(FilesPeer.same("FE80::1%en0", "fe80::1"))
        #expect(!FilesPeer.same("192.168.1.21", "192.168.1.20"))
        #expect(!FilesPeer.same("::ffff:192.168.1.21", "192.168.1.20"))
        #expect(!FilesPeer.same("", "192.168.1.20"))
        #expect(!FilesPeer.same("::ffff", "192.168.1.20"))
    }
}
