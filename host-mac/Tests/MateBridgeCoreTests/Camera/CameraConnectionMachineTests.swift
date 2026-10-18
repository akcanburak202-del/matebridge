import Testing
@testable import MateBridgeCore

// Pure state machine of the tablet camera connection (decision 0040, PROTOCOL.md section 4 "Kamera bağlantısı").

private let sec: UInt64 = 1_000_000
private let peer = "192.168.1.20"
private let hostNonce = [UInt8](repeating: 0xa0, count: 16)
private let clientNonce = [UInt8](repeating: 0x90, count: 16)

private func C(_ n: UInt64) -> CameraConnID { CameraConnID(n) }

private func hello(session: UInt32 = 7, camID: UInt16 = 3, version: UInt16 = ProtocolConstants.protocolVersion) -> CamHello {
    CamHello(protocolVersion: version, sessionID: session, camID: camID, clientNonce: clientNonce)
}

private let ping: Message = .ping(Ping(seq: 1, senderTimeUs: 2))
private let frame: Message = .camFrame(CamFrame(frameSeq: 1, captureTimeUs: 5, flags: .keyframe, data: [0, 0, 0, 1, 0x65]))

private func makeMachine() -> CameraConnectionMachine {
    var c = CameraConnectionMachine.Configuration()
    c.makeNonce = { hostNonce }
    var m = CameraConnectionMachine(configuration: c)
    _ = m.open(sessionID: 7, camID: 3, controlPeer: peer)
    return m
}

@discardableResult
private func proven(_ m: inout CameraConnectionMachine, _ id: CameraConnID, now: UInt64 = 0) -> [CameraAction] {
    var out = m.accepted(id, peer: peer, now: now)
    out += m.hello(id, hello(), now: now)
    out += m.record(id, ping, now: now)
    return out
}

private func closes(_ actions: [CameraAction]) -> [(CameraConnID, CameraCloseReason)] {
    actions.compactMap { if case .close(let id, let r) = $0 { (id, r) } else { nil } }
}

private func acks(_ actions: [CameraAction]) -> [CamHelloAck] {
    actions.compactMap { if case .sendAck(_, let a) = $0 { a } else { nil } }
}

private func has(_ actions: [CameraAction], _ wanted: CameraAction) -> Bool { actions.contains(wanted) }

@Suite struct CameraConnectionMachineTests {
    // MARK: Accept checks

    @Test func nothingIsAcceptedBeforeOpenOrAfterClose() {
        var m = CameraConnectionMachine()
        #expect(closes(m.accepted(C(1), peer: peer, now: 0)).map(\.1) == [.notOpen])
        _ = m.open(sessionID: 7, camID: 3, controlPeer: peer)
        #expect(m.accepted(C(2), peer: peer, now: 0).isEmpty)
        _ = m.close()
        #expect(!m.isOpen)
        #expect(closes(m.accepted(C(3), peer: peer, now: 0)).map(\.1) == [.notOpen])
    }

    @Test func onlyTheControlPeerIsAccepted() {
        var m = makeMachine()
        #expect(closes(m.accepted(C(1), peer: "192.168.1.99", now: 0)).map(\.1) == [.peerMismatch])
        #expect(m.connectionCount == 0)
        #expect(m.accepted(C(2), peer: "::ffff:192.168.1.20", now: 0).isEmpty)  // same host, mapped form
    }

    @Test func atMostOneConnectionThatHasNotProvenItself() {
        var m = makeMachine()
        #expect(m.accepted(C(1), peer: peer, now: 0).isEmpty)
        let second = m.accepted(C(2), peer: peer, now: 0)
        #expect(closes(second).map(\.1) == [.unprovenLimit])
        #expect(closes(second).map(\.0) == [C(2)])  // the excess one closes, not the waiting one
        #expect(m.unprovenCount == 1)
        // Once the first proved itself a new one may come.
        _ = m.hello(C(1), hello(), now: 1)
        _ = m.record(C(1), ping, now: 1)
        #expect(m.accepted(C(3), peer: peer, now: 2).isEmpty)
    }

    // MARK: CAM_HELLO checks

    @Test func goodHelloGetsAnOkAckWithAFreshNonceAndStartsRecords() {
        var m = makeMachine()
        _ = m.accepted(C(1), peer: peer, now: 0)
        let out = m.hello(C(1), hello(), now: sec)
        #expect(acks(out) == [CamHelloAck(status: .ok, hostNonce: hostNonce)])
        #expect(has(out, .startRecords(C(1), clientNonce: clientNonce, hostNonce: hostNonce)))
        #expect(closes(out).isEmpty)
    }

    @Test(arguments: [
        (UInt32(8), UInt16(3), ProtocolConstants.protocolVersion, "session"),
        (UInt32(7), UInt16(4), ProtocolConstants.protocolVersion, "cam_id"),
        (UInt32(7), UInt16(3), UInt16(2), "version"),
    ])
    func wrongSessionCamIDOrVersionIsRejected(session: UInt32, camID: UInt16, version: UInt16, reason: String) {
        var m = makeMachine()
        _ = m.accepted(C(1), peer: peer, now: 0)
        let out = m.hello(C(1), hello(session: session, camID: camID, version: version), now: 1)
        #expect(acks(out) == [.rejected])
        #expect(acks(out).first?.hostNonce == [UInt8](repeating: 0, count: 16))
        #expect(closes(out).map(\.1) == [.rejected])
        #expect(out.contains { if case .log(_, _, _, let f) = $0 { f.contains("reason=\(reason)") } else { false } })
        #expect(m.connectionCount == 0)
    }

    @Test func aHelloAfterTheFiveSecondsClosesWithoutAnAnswer() {
        var m = makeMachine()
        _ = m.accepted(C(1), peer: peer, now: 0)
        let out = m.hello(C(1), hello(), now: 5 * sec)
        #expect(acks(out).isEmpty)
        #expect(closes(out).map(\.1) == [.helloTimeout])
    }

    @Test func aSecondHelloOrAnyOtherPlainMessageEndsTheConnection() {
        var m = makeMachine()
        _ = m.accepted(C(1), peer: peer, now: 0)
        _ = m.hello(C(1), hello(), now: 1)
        #expect(closes(m.hello(C(1), hello(), now: 2)).map(\.1) == [.protocolError])
    }

    // MARK: Proof

    @Test func noFrameIsAcceptedBeforeTheProof() {
        var m = makeMachine()
        _ = m.accepted(C(1), peer: peer, now: 0)
        _ = m.hello(C(1), hello(), now: 1)
        let out = m.record(C(1), frame, now: 2)
        #expect(closes(out).map(\.1) == [.protocolError])
        #expect(!out.contains { if case .frame = $0 { true } else { false } })
    }

    @Test func theFirstPingActivatesTheConnection() {
        var m = makeMachine()
        let out = proven(&m, C(1), now: sec)
        #expect(has(out, .activated(C(1))))
        #expect(m.activeConnection == C(1))
        #expect(m.unprovenCount == 0)
    }

    @Test func aProofAfterTheFiveSecondsIsTooLate() {
        var m = makeMachine()
        _ = m.accepted(C(1), peer: peer, now: 0)
        _ = m.hello(C(1), hello(), now: sec)
        let out = m.record(C(1), ping, now: 5 * sec)
        #expect(closes(out).map(\.1) == [.proofTimeout])
        #expect(m.activeConnection == nil)
    }

    @Test func theTickClosesWaitingConnectionsAtTheirDeadline() {
        var m = makeMachine()
        _ = m.accepted(C(1), peer: peer, now: 0)
        #expect(m.nextDeadline == 5 * sec)
        #expect(m.tick(now: 5 * sec - 1).isEmpty)
        #expect(closes(m.tick(now: 5 * sec)).map(\.1) == [.helloTimeout])
        _ = m.accepted(C(2), peer: peer, now: 6 * sec)
        _ = m.hello(C(2), hello(), now: 6 * sec)
        #expect(closes(m.tick(now: 11 * sec)).map(\.1) == [.proofTimeout])
        #expect(m.nextDeadline == nil)
    }

    @Test func theOldConnectionClosesOnlyAfterTheNewOneProvedItself() {
        var m = makeMachine()
        proven(&m, C(1), now: 0)
        // A second connection says hello: the old one is untouched.
        _ = m.accepted(C(2), peer: peer, now: sec)
        let helloOut = m.hello(C(2), hello(), now: sec)
        #expect(closes(helloOut).isEmpty)
        #expect(m.activeConnection == C(1))
        // A frame before the proof does not close the old one either, it only ends the newcomer.
        #expect(closes(m.record(C(2), frame, now: sec)) .map(\.0) == [C(2)])
        #expect(m.activeConnection == C(1))
        // A newcomer that proves itself replaces it.
        _ = m.accepted(C(3), peer: peer, now: 2 * sec)
        _ = m.hello(C(3), hello(), now: 2 * sec)
        let out = m.record(C(3), ping, now: 2 * sec)
        #expect(closes(out).map(\.0) == [C(1)])
        #expect(closes(out).map(\.1) == [.superseded])
        #expect(has(out, .activated(C(3))))
        #expect(m.activeConnection == C(3))
        #expect(m.connectionCount == 1)
    }

    // MARK: Frames and type validity

    @Test func framesAreValidOnlyOnTheActiveConnection() {
        var m = makeMachine()
        proven(&m, C(1))
        #expect(m.record(C(1), frame, now: sec) == [.frame(C(1))])
        #expect(m.record(C(1), ping, now: sec).isEmpty)  // keep-alive, no PONG
    }

    @Test(arguments: [
        Message.camHello(CamHello(sessionID: 7, camID: 3, clientNonce: clientNonce)),
        Message.camHelloAck(.rejected),
        Message.camKeyframeRequest(.framesDropped),  // wrong direction
        Message.pong(Pong(seq: 1, echoTimeUs: 2, responderTimeUs: 3)),
        Message.key(KeyEvent(timeUs: 0, scanCode: 4, androidKeyCode: 0, action: .down, capsLockOn: false)),
        Message.bye(.normal),
    ])
    func anyOtherKnownTypeEndsOnlyThisConnection(message: Message) {
        var m = makeMachine()
        proven(&m, C(1))
        _ = m.accepted(C(2), peer: peer, now: 1)
        _ = m.hello(C(2), hello(), now: 1)
        // The proven connection with a wrong message closes, the other connection is untouched.
        let out = m.record(C(1), message, now: 2)
        #expect(closes(out).map(\.0) == [C(1)] && closes(out).map(\.1) == [.protocolError])
        #expect(m.unprovenCount == 1)
        #expect(m.isOpen)
    }

    @Test func malformedPayloadAndAuthFailureCloseOnlyThatConnection() {
        var m = makeMachine()
        proven(&m, C(1))
        #expect(closes(m.protocolError(C(1))).map(\.1) == [.protocolError])
        #expect(m.activeConnection == nil)
        proven(&m, C(2))
        #expect(closes(m.recordAuthFailed(C(2))).map(\.1) == [.authFailed])
        #expect(m.isOpen)
    }

    @Test func keysUnavailableClosesTheConnection() {
        var m = makeMachine()
        _ = m.accepted(C(1), peer: peer, now: 0)
        _ = m.hello(C(1), hello(), now: 1)
        #expect(closes(m.keysUnavailable(C(1))).map(\.1) == [.keysUnavailable])
        #expect(m.connectionCount == 0)
    }

    // MARK: End of the stream

    @Test func closeEndsEveryConnectionAndTheListenerState() {
        var m = makeMachine()
        proven(&m, C(1))
        _ = m.accepted(C(2), peer: peer, now: 1)
        let out = m.close()
        #expect(Set(closes(out).map(\.0)) == [C(1), C(2)])
        #expect(closes(out).allSatisfy { $0.1 == .sessionEnded })
        #expect(!m.isOpen && m.connectionCount == 0)
        #expect(closes(m.accepted(C(3), peer: peer, now: 2)).map(\.1) == [.notOpen])
    }

    @Test func openingAgainForANewCamIDClosesTheOldConnectionsAndRejectsTheOldCamID() {
        var m = makeMachine()
        proven(&m, C(1))
        let out = m.open(sessionID: 7, camID: 4, controlPeer: peer)
        #expect(closes(out).map(\.0) == [C(1)] && closes(out).map(\.1) == [.sessionEnded])
        _ = m.accepted(C(2), peer: peer, now: 1)
        #expect(acks(m.hello(C(2), hello(camID: 3), now: 1)) == [.rejected])
        _ = m.accepted(C(3), peer: peer, now: 1)
        #expect(acks(m.hello(C(3), hello(camID: 4), now: 1)).first?.isOK == true)
    }

    @Test func aTransportCloseForgetsTheConnection() {
        var m = makeMachine()
        proven(&m, C(1))
        _ = m.connectionClosed(C(1))
        #expect(m.activeConnection == nil)
        #expect(m.connectionClosed(C(1)).isEmpty)
        #expect(m.record(C(1), frame, now: 3).isEmpty)  // late events of a gone connection are ignored
    }
}
