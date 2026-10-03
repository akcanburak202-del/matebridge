import Foundation
import Testing
@testable import MateBridgeCore

private let sec: UInt64 = 1_000_000
private let A = ConnectionID(1)
private let B = ConnectionID(2)
private let V = ConnectionID(100)
private let V2 = ConnectionID(101)

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }

private let pairKey = SecretBytes([UInt8](repeating: 0x5a, count: 32))

private func hello(_ dev: UInt8 = 1, version: UInt16 = ProtocolConstants.protocolVersion, name: String = "Pad") -> Message {
    .hello(TestClient(device: dev, name: name, version: version).hello)
}

private let sampleConfig = StreamConfig(configID: 1, codec: .h264, widthPx: 2800, heightPx: 1840, widthPt: 1400,
                                        heightPt: 920, fps: 60, bitrateKbps: 40000, colorPrimaries: 1, transfer: 1,
                                        matrix: 1, fullRange: true)

/// Approved devices also have a pair key (PAIRED); an approved device without a key would fall back to PAIRING.
private func makeMachine(approved: Set<DeviceID> = []) -> SessionMachine {
    let keys = InMemoryPairKeyStore(keys: Dictionary(uniqueKeysWithValues: approved.map { ($0, pairKey) }))
    var m = SessionMachine(configuration: .init(hostName: "Mac", makeStreamConfig: { _ in sampleConfig },
                                                makeSessionID: { 77 }, pairKeys: keys), approvedDevices: approved)
    m.videoPort = 5555
    return m
}

private func sent(_ actions: [SessionAction], to id: ConnectionID) -> [Message] {
    actions.compactMap { if case .send(id, let m) = $0 { m } else { nil } }
}

private func ackStatuses(_ actions: [SessionAction], to id: ConnectionID) -> [HelloStatus] {
    sent(actions, to: id).compactMap { if case .helloAck(let a) = $0 { a.status } else { nil } }
}

private func has(_ actions: [SessionAction], _ pred: (SessionAction) -> Bool) -> Bool { actions.contains(where: pred) }

private func isRelease(_ a: SessionAction) -> Bool { if case .releaseInput = a { true } else { false } }
private func isDeliver(_ a: SessionAction) -> Bool { if case .deliver = a { true } else { false } }

private func nonce(_ n: UInt8) -> [UInt8] { [UInt8](repeating: n, count: 16) }

/// VIDEO_HELLO followed by the authenticated PING: returns what `videoProven` did.
@discardableResult
private func attachVideo(_ m: inout SessionMachine, _ vid: ConnectionID, nonce n: UInt8, now: UInt64 = 0) -> [SessionAction] {
    _ = m.videoOpened(vid, now: now)
    _ = m.videoHello(vid, VideoHello(configID: 1, sessionID: 77, videoNonce: nonce(n)), now: now)
    return m.videoProven(vid, now: now)
}

private func keyDown() -> Message {
    .key(KeyEvent(timeUs: 1, scanCode: 30, androidKeyCode: 29, action: .down, capsLockOn: false))
}

/// Opens a connection and drives it to ACTIVE for a pre-approved device: HELLO (PAIRED, proving), then the first
/// authenticated record (a PING, as the client sends it) that activates the session (T-152).
private func activate(_ m: inout SessionMachine, _ id: ConnectionID, dev: UInt8 = 1, now: UInt64 = 0) {
    _ = m.connectionOpened(id, now: now)
    _ = m.received(id, hello(dev), now: now)
    _ = m.received(id, .ping(Ping(seq: 0, senderTimeUs: 0)), now: now)
}

@Suite struct SessionMachineTests {
    @Test func approvedDeviceIsAcceptedWithConfig() {
        var m = makeMachine(approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        let actions = m.received(A, hello(), now: 10)
        let msgs = sent(actions, to: A)
        guard case .helloAck(let ack)? = msgs.first else { Issue.record("no ack"); return }
        #expect(ack.status == .accepted)
        #expect(ack.sessionID == 77)
        #expect(ack.videoPort == 5555)
        #expect(ack.hostName == "Mac")
        #expect(msgs.count == 1)  // STREAM_CONFIG waits for the proof (T-152)
        let proof = m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 11)
        #expect(sent(proof, to: A).first == .streamConfig(sampleConfig))
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
    }

    @Test func helloTimeoutClosesAfterFiveSeconds() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        #expect(m.tick(now: 4_999_999).isEmpty)
        #expect(has(m.tick(now: 5 * sec)) { $0 == .close(A) })
        #expect(m.received(A, hello(), now: 6 * sec).isEmpty)
    }

    @Test func nonHelloFirstMessageIsProtocolError() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        let actions = m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 1)
        #expect(sent(actions, to: A) == [.bye(.protocolError)])
        #expect(has(actions) { $0 == .close(A) })
    }

    @Test func versionMismatchAnswersAndCloses() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        let actions = m.received(A, hello(version: 9), now: 1)
        #expect(ackStatuses(actions, to: A) == [.versionMismatch])
        #expect(has(actions) { $0 == .close(A) })
        #expect(m.status == .idle)
    }

    @Test func newDeviceGoesPendingThenAccepted() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        let first = m.received(A, hello(name: "Tab"), now: 0)
        #expect(ackStatuses(first, to: A) == [.pendingApproval])
        #expect(has(first) { if case .requestApproval(A, device(1), "Tab", _, .none) = $0 { true } else { false } })
        #expect(m.status == .pending(deviceName: "Tab"))

        // Accepting is two steps: persist the pair key first, ACCEPTED only after it is stored.
        let approved = m.approvalDecided(A, approved: true, now: 2 * sec)
        #expect(ackStatuses(approved, to: A).isEmpty)
        #expect(has(approved) { if case .persistPairing(A, device(1), "Tab", _) = $0 { true } else { false } })
        #expect(m.status == .pending(deviceName: "Tab"))
        let stored = m.pairingPersisted(A, stored: true, now: 2 * sec)
        #expect(ackStatuses(stored, to: A) == [.accepted])
        #expect(m.approvedDevices.contains(device(1)))
        #expect(m.status == .active(deviceName: "Tab", sessionID: 77))
    }

    @Test func rejectedClosesAndDoesNotRemember() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(), now: 0)
        let actions = m.approvalDecided(A, approved: false, now: 1)
        #expect(ackStatuses(actions, to: A) == [.rejected])
        #expect(has(actions) { $0 == .close(A) })
        #expect(m.approvedDevices.isEmpty)
        #expect(m.status == .idle)
    }

    @Test func approvalTimesOutAfterSixtySecondsAndSkipsFiveSecondRule() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(), now: 0)
        #expect(m.tick(now: 59 * sec).isEmpty)  // 5 s / 1.5 s heartbeat rules do not apply while pending
        let actions = m.tick(now: 60 * sec)
        #expect(ackStatuses(actions, to: A) == [.rejected])
        #expect(has(actions) { $0 == .cancelApproval(A) })
        #expect(has(actions) { $0 == .close(A) })
        #expect(m.status == .idle)
        #expect(m.approvalDecided(A, approved: true, now: 61 * sec).isEmpty)
    }

    @Test func lateApprovalIsRejected() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(), now: 0)
        let actions = m.approvalDecided(A, approved: true, now: 60 * sec)  // tick has not run yet
        #expect(ackStatuses(actions, to: A) == [.rejected])
        #expect(!m.approvedDevices.contains(device(1)))
        #expect(!actions.contains { if case .persistPairing = $0 { true } else { false } })
        #expect(m.status == .idle)
    }

    @Test func pendingConnectionDropCancelsApproval() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(), now: 0)
        let actions = m.connectionClosed(A)
        // T-043: the window stays (marked as disconnected) instead of being cancelled.
        #expect(has(actions) { $0 == .approvalOrphaned(A) })
        #expect(m.status == .idle)
    }

    @Test func otherDeviceGetsBusyWithoutDisturbingSession() {
        var m = makeMachine(approved: [device(1), device(2)])
        activate(&m, A)
        _ = m.connectionOpened(B, now: 1)
        let actions = m.received(B, hello(2), now: 1)
        #expect(ackStatuses(actions, to: B) == [.busy])
        #expect(has(actions) { $0 == .close(B) })
        #expect(!has(actions, isRelease))
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
    }

    @Test func busyAlsoWhileAnotherDeviceIsPending() {
        var m = makeMachine(approved: [device(2)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(1), now: 0)  // pending
        _ = m.connectionOpened(B, now: 1)
        #expect(ackStatuses(m.received(B, hello(2), now: 1), to: B) == [.busy])
    }

    @Test func sameDeviceTakeoverWaitsForProofThenReleasesTheOldSessionFirst() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        _ = m.connectionOpened(B, now: 5)
        let hello = m.received(B, hello(1), now: 5)
        // The new connection is answered ACCEPTED (PAIRED) but the old session is untouched.
        #expect(ackStatuses(hello, to: B) == [.accepted])
        #expect(!hello.contains { if case .releaseInput = $0 { true } else { false } })
        #expect(!hello.contains(.close(A)) && !hello.contains(.send(A, .bye(.superseded))))
        #expect(!hello.contains { if case .sessionStarted = $0 { true } else { false } })
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
        // The first authenticated record proves key possession: release, BYE, close, then activate, then the record.
        let proof = m.received(B, .ping(Ping(seq: 4, senderTimeUs: 9)), now: 6)
        let idxRelease = proof.firstIndex { $0 == .releaseInput(A, .superseded) }
        let idxBye = proof.firstIndex { $0 == .send(A, .bye(.superseded)) }
        let idxClose = proof.firstIndex { $0 == .close(A) }
        let idxStart = proof.firstIndex { if case .sessionStarted(B, _, _, _) = $0 { true } else { false } }
        let idxPong = proof.firstIndex { $0 == .send(B, .pong(Pong(seq: 4, echoTimeUs: 9, responderTimeUs: 6))) }
        #expect(idxRelease != nil && idxBye != nil && idxClose != nil && idxStart != nil && idxPong != nil)
        if let r = idxRelease, let b = idxBye, let c = idxClose, let a = idxStart, let p = idxPong {
            #expect(r < b && b < c && c < a && a < p)
        }
        #expect(sent(proof, to: B).contains(.streamConfig(sampleConfig)))
        // Late traffic from the old connection is ignored.
        #expect(m.received(A, keyDown(), now: 7).isEmpty)
    }

    @Test func unprovenTakeoverNeverDisturbsTheOldSession() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        _ = m.connectionOpened(B, now: 5 * sec)
        _ = m.received(B, hello(1), now: 5 * sec)
        _ = m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 9 * sec)  // the old session stays alive
        #expect(m.tick(now: 9_999_999).isEmpty)
        let timeout = m.tick(now: 10 * sec)  // 5 s after HELLO, no proof
        #expect(timeout.contains(.close(B)))
        #expect(!timeout.contains { if case .releaseInput = $0 { true } else { false } })
        #expect(!timeout.contains(.close(A)))
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
        #expect(m.scheduleForTesting(B) == nil)
    }

    @Test func lostProvingConnectionLeavesTheOldSessionAlone() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        _ = m.connectionOpened(B, now: 1)
        _ = m.received(B, hello(1), now: 1)
        let schedule = m.scheduleForTesting(B)
        let closed = m.connectionClosed(B)
        #expect(!closed.contains { if case .releaseInput = $0 { true } else { false } })
        #expect(schedule?.prkBytes == nil)
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
    }

    @Test func takeoverNeedingPairingIsBusy() {
        // The device is approved but its key is gone: a new HELLO while its session is live must not take over.
        let store = InMemoryPairKeyStore(keys: [device(1): pairKey])
        var m = SessionMachine(configuration: .init(hostName: "Mac", makeStreamConfig: { _ in sampleConfig },
                                                    makeSessionID: { 77 }, pairKeys: store),
                               approvedDevices: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(1), now: 0)
        _ = m.received(A, .ping(Ping(seq: 0, senderTimeUs: 0)), now: 0)  // proof: A is the live session (T-152)
        try? store.removeAll()
        _ = m.connectionOpened(B, now: 1)
        let actions = m.received(B, hello(1), now: 1)
        #expect(ackStatuses(actions, to: B) == [.busy] && actions.contains(.close(B)))
        #expect(!actions.contains { if case .startEncryption = $0 { true } else { false } })
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
    }

    @Test func takeoverClosesOldVideoConnectionOnlyAfterProof() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        attachVideo(&m, V, nonce: 1, now: 1)
        _ = m.connectionOpened(B, now: 2)
        #expect(!has(m.received(B, hello(1), now: 2)) { $0 == .closeVideo(V) })
        #expect(has(m.received(B, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 3)) { $0 == .closeVideo(V) })
    }

    @Test func pingIsAnsweredEvenWhilePending() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(), now: 0)
        let actions = m.received(A, .ping(Ping(seq: 9, senderTimeUs: 1234)), now: 4242)
        #expect(sent(actions, to: A) == [.pong(Pong(seq: 9, echoTimeUs: 1234, responderTimeUs: 4242))])
    }

    @Test func inputBeforeApprovalIsIgnored() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(), now: 0)
        #expect(m.received(A, keyDown(), now: 1).isEmpty)
        #expect(m.received(A, .releaseAll(.user), now: 1).isEmpty)
        #expect(m.status == .pending(deviceName: "Pad"))
    }

    @Test func inputAfterAcceptIsDelivered() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        #expect(m.received(A, keyDown(), now: 1) == [.deliver(A, keyDown())])
        #expect(m.received(A, .releaseAll(.focusLost), now: 2) == [.releaseInput(A, .clientRequest(.focusLost))])
    }

    @Test func silenceReleasesOnceAt1500msThenClosesAt5s() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A, now: 0)
        _ = m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: sec)
        #expect(m.tick(now: 2_499_999).isEmpty)
        #expect(has(m.tick(now: 2_500_000)) { $0 == .releaseInput(A, .silence) })
        #expect(!has(m.tick(now: 3 * sec), isRelease))  // only once per silence
        let closing = m.tick(now: 6 * sec)
        #expect(has(closing) { $0 == .releaseInput(A, .timeout) })
        #expect(sent(closing, to: A) == [.bye(.timeout)])
        #expect(has(closing) { $0 == .close(A) })
        #expect(m.status == .idle)
    }

    @Test func traffic_rearmsSilenceRelease() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A, now: 0)
        #expect(has(m.tick(now: 2 * sec), isRelease))
        _ = m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 2 * sec)
        #expect(has(m.tick(now: 4 * sec), isRelease))
    }

    @Test func disconnectAndByeReleaseInput() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        let dropped = m.connectionClosed(A)
        #expect(dropped.contains(.releaseInput(A, .disconnected)))
        #expect(dropped.contains(.sessionEnded(A)))

        activate(&m, B)
        let bye = m.received(B, .bye(.normal), now: 1)
        #expect(bye.contains(.releaseInput(B, .bye)))
        #expect(bye.contains(.close(B)))
        #expect(m.status == .idle)
    }

    @Test func protocolErrorSendsByeReleasesAndClosesVideo() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        attachVideo(&m, V, nonce: 1)
        let actions = m.protocolError(A)
        #expect(actions.contains(.releaseInput(A, .protocolError)))
        #expect(sent(actions, to: A) == [.bye(.protocolError)])
        #expect(actions.contains(.closeVideo(V)))
    }

    @Test func shutdownReleasesAndSaysBye() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        let actions = m.shutdown()
        #expect(actions.contains(.releaseInput(A, .shutdown)))
        #expect(sent(actions, to: A) == [.bye(.shuttingDown)])
        #expect(m.status == .idle)
    }

    // MARK: Host sleep (T-132)

    @Test func hostSleepReleasesSaysByeHostSleepAndClosesInOrder() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        attachVideo(&m, V, nonce: 1)
        let actions = m.hostSleep()
        // Protocol order (PROTOCOL.md 7): release first, then BYE, then the closes, then the session end.
        #expect(actions == [.releaseInput(A, .hostSleep), .send(A, .bye(.hostSleep)), .close(A), .closeVideo(V),
                            .sessionEnded(A), .log(.info, ev: "bye_sent", conn: A, fields: "reason=host_sleep")])
        #expect(m.status == .idle)
        #expect(m.hostSleep().isEmpty)  // nothing left: a second notification does nothing
    }

    @Test func hostSleepEndsAProvingReconnectToo() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        _ = m.connectionOpened(B, now: 2)
        _ = m.received(B, hello(1), now: 2)  // same device, PAIRED: proving, the old session still live
        let actions = m.hostSleep()
        #expect(sent(actions, to: A).last == .bye(.hostSleep))
        #expect(sent(actions, to: B) == [.bye(.hostSleep)])
        #expect(actions.contains(.close(A)) && actions.contains(.close(B)))
        #expect(actions.contains(.releaseInput(A, .hostSleep)) && actions.contains(.sessionEnded(A)))
        #expect(m.awaitingHelloCount == 0)
        // The proof arriving after the sleep finds nothing to take over.
        #expect(m.received(B, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 3).isEmpty)
        #expect(m.status == .idle)
    }

    @Test func hostSleepCancelsAPendingPairingAndClosesIt() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(), now: 0)
        let actions = m.hostSleep()
        #expect(actions.contains(.cancelApproval(A)))
        #expect(!actions.contains(.approvalOrphaned(A)))  // the window does not stay open over the sleep
        #expect(sent(actions, to: A) == [.bye(.hostSleep)])
        #expect(actions.contains(.close(A)))
        #expect(!actions.contains { if case .releaseInput = $0 { true } else { false } })
        #expect(m.status == .idle)
        #expect(m.approvalDecided(A, approved: true, now: 1).isEmpty)
        #expect(!m.approvedDevices.contains(device(1)))
    }

    @Test func hostSleepClosesAnOrphanedApprovalWindow() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(), now: 0)
        _ = m.connectionClosed(A)  // tablet left: the window stays open
        #expect(m.orphanDeviceForTesting == device(1))
        #expect(m.hostSleep() == [.cancelApproval(A)])
        #expect(m.orphanDeviceForTesting == nil)
    }

    @Test func hostSleepClosesUnauthenticatedConnections() {
        var m = makeMachine(approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)  // no HELLO yet
        _ = m.videoOpened(V, now: 0)  // no VIDEO_HELLO yet
        let actions = m.hostSleep()
        #expect(actions.contains(.close(A)) && actions.contains(.closeVideo(V)))
        #expect(m.awaitingHelloCount == 0 && m.pendingVideoCount == 0)
    }

    @Test func connectionsAfterHostSleepAreAcceptedNormally() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        _ = m.hostSleep()
        // A dark wake (or the real wake): the tablet reconnects and gets a normal session.
        _ = m.connectionOpened(B, now: 10 * sec)
        let actions = m.received(B, hello(1), now: 10 * sec)
        #expect(ackStatuses(actions, to: B) == [.accepted])
        _ = m.received(B, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 10 * sec)  // the proof (T-152)
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
    }

    @Test func hostSleepWithNothingOpenDoesNothing() {
        var m = makeMachine(approved: [device(1)])
        #expect(m.hostSleep().isEmpty)
    }

    @Test func videoHelloValidatesSessionAndConfig() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        _ = m.videoOpened(V, now: 0)
        #expect(m.videoHello(V, VideoHello(configID: 1, sessionID: 78), now: 0).contains(.closeVideo(V)))
        _ = m.videoOpened(V, now: 0)
        #expect(m.videoHello(V, VideoHello(configID: 2, sessionID: 77), now: 0).contains(.closeVideo(V)))
        _ = m.videoOpened(V, now: 0)
        #expect(m.videoHello(V, VideoHello(protocolVersion: 3, configID: 1, sessionID: 77), now: 0)
            .contains(.closeVideo(V)))
        _ = m.videoOpened(V, now: 0)
        let ok = m.videoHello(V, VideoHello(configID: 1, sessionID: 77, videoNonce: nonce(1)), now: 0)
        guard case .videoProve(V, let c2h)? = ok.first, ok.count == 1 else { Issue.record("no proof: \(ok)"); return }
        let attached = m.videoProven(V, now: 0)
        guard case .videoAttached(V, A, 77, 1, let keys)? = attached.first, attached.count == 1 else {
            Issue.record("not attached: \(attached)"); return
        }
        #expect(keys.c2h == c2h)
        #expect(keys.h2c.bytes.count == 32 && keys.c2h.bytes.count == 32 && keys.h2c != keys.c2h)
    }

    @Test func videoHelloWithoutSessionIsRejected() {
        var m = makeMachine()
        _ = m.videoOpened(V, now: 0)
        #expect(m.videoHello(V, VideoHello(configID: 1, sessionID: 77), now: 0).contains(.closeVideo(V)))
    }

    @Test func provenVideoReplacesTheOldVideoConnectionButAnUnprovenOneDoesNot() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        attachVideo(&m, V, nonce: 1)
        _ = m.videoOpened(V2, now: 1)
        let hello = m.videoHello(V2, VideoHello(configID: 1, sessionID: 77, videoNonce: nonce(2)), now: 1)
        // Unproven: no attach, nothing closed, nothing consumed.
        #expect(hello.count == 1 && !hello.contains(.closeVideo(V)))
        #expect(!hello.contains { if case .videoAttached = $0 { true } else { false } })
        let proven = m.videoProven(V2, now: 2)
        #expect(proven.first == .closeVideo(V))
        #expect(proven.contains { if case .videoAttached(V2, A, _, _, _) = $0 { true } else { false } })
    }

    @Test func unprovenVideoChangesNothingAndIsClosedAfterFiveSeconds() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        attachVideo(&m, V, nonce: 1)
        _ = m.videoOpened(V2, now: 10 * sec)
        _ = m.videoHello(V2, VideoHello(configID: 1, sessionID: 77, videoNonce: nonce(2)), now: 10 * sec)
        #expect(m.pendingVideoCount == 1)
        _ = m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 14 * sec)
        #expect(m.tick(now: 14_999_999).isEmpty)
        let timeout = m.tick(now: 15 * sec)
        #expect(timeout.contains(.closeVideo(V2)) && !timeout.contains(.closeVideo(V)))
        #expect(m.pendingVideoCount == 0)
        // The late proof finds nothing to attach.
        #expect(m.videoProven(V2, now: 16 * sec) == [.closeVideo(V2)])
    }

    @Test func manyUnprovenAttemptsDoNotConsumeAnythingAndNeverLockOutALegitimateClient() {
        var m = makeMachine(approved: [device(1)])
        m.configuration.releaseSilenceUs = 1000 * sec; m.configuration.closeSilenceUs = 1000 * sec
        activate(&m, A)
        for i in 0..<300 {  // an attacker with a valid session_id but no key
            let vid = ConnectionID(1000 + UInt64(i))
            _ = m.videoOpened(vid, now: 0)
            _ = m.videoHello(vid, VideoHello(configID: 1, sessionID: 77, videoNonce: [UInt8(i % 256), UInt8(i / 256)]
                + [UInt8](repeating: 9, count: 14)), now: 0)
            _ = m.tick(now: 5 * sec)  // never proves; times out
        }
        let attached = attachVideo(&m, V, nonce: 1, now: 6 * sec)
        #expect(attached.contains { if case .videoAttached(V, _, _, _, _) = $0 { true } else { false } })
    }

    @Test func everyProvenNonceIsRememberedForTheWholeSessionThenTheSessionEnds() {
        var m = makeMachine(approved: [device(1)])
        m.configuration.maxVideoNonces = 8
        m.configuration.releaseSilenceUs = 1000 * sec; m.configuration.closeSilenceUs = 1000 * sec
        activate(&m, A)
        for i in 0..<8 {
            let attached = attachVideo(&m, ConnectionID(2000 + UInt64(i)), nonce: UInt8(i + 1))
            #expect(attached.contains { if case .videoAttached = $0 { true } else { false } }, "attach \(i)")
        }
        // The first nonce is still refused: nothing was evicted, so a replayed VIDEO_HELLO can never reuse a key.
        _ = m.videoOpened(ConnectionID(3000), now: 0)
        #expect(m.videoHello(ConnectionID(3000), VideoHello(configID: 1, sessionID: 77, videoNonce: nonce(1)), now: 0)
            .contains(.closeVideo(ConnectionID(3000))))
        // Budget spent: the next legitimate attach ends the session (release-all, BYE, close) instead of reusing keys.
        let last = ConnectionID(4000)
        let ended = attachVideo(&m, last, nonce: 100)
        #expect(!ended.contains { if case .videoAttached = $0 { true } else { false } })
        #expect(ended.contains(.closeVideo(last)))
        #expect(ended.contains(.releaseInput(A, .shutdown)) && ended.contains(.send(A, .bye(.shuttingDown))))
        #expect(ended.contains(.close(A)) && ended.contains(.sessionEnded(A)))
        #expect(ended.contains(.log(.info, ev: "video_nonce_budget_exhausted", conn: A, fields: "")))
        #expect(m.status == .idle)
        // The tablet reconnects with a fresh handshake: a new prk, so the same nonces are fine again.
        _ = m.connectionOpened(B, now: 1)
        _ = m.received(B, hello(1), now: 1)
        _ = m.received(B, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 1)  // the proof (T-152)
        #expect(attachVideo(&m, ConnectionID(5000), nonce: 1).contains { if case .videoAttached = $0 { true } else { false } })
    }

    @Test func aRepeatedNonceIsRefusedWhileRememberedAndNotBefore() {
        var m = makeMachine(approved: [device(1)])
        m.configuration.releaseSilenceUs = 1000 * sec; m.configuration.closeSilenceUs = 1000 * sec
        activate(&m, A)
        attachVideo(&m, V, nonce: 1)
        _ = m.videoOpened(V2, now: 0)
        let replay = m.videoHello(V2, VideoHello(configID: 1, sessionID: 77, videoNonce: nonce(1)), now: 0)
        #expect(replay.contains(.closeVideo(V2)))
        #expect(!replay.contains { if case .videoProve = $0 { true } else { false } })
        // An unproven hello with a fresh nonce does not reserve that nonce...
        _ = m.videoOpened(ConnectionID(300), now: 0)
        _ = m.videoHello(ConnectionID(300), VideoHello(configID: 1, sessionID: 77, videoNonce: nonce(5)), now: 0)
        _ = m.tick(now: 6 * sec)
        // ...so the legitimate owner of that nonce can still use it.
        #expect(attachVideo(&m, ConnectionID(301), nonce: 5, now: 7 * sec).contains {
            if case .videoAttached = $0 { true } else { false }
        })
        // Two hellos with the same unproven nonce race: only the one that proves wins; the second proof is refused.
        _ = m.videoOpened(ConnectionID(400), now: 8 * sec)
        _ = m.videoOpened(ConnectionID(401), now: 8 * sec)
        _ = m.videoHello(ConnectionID(400), VideoHello(configID: 1, sessionID: 77, videoNonce: nonce(6)), now: 8 * sec)
        _ = m.videoHello(ConnectionID(401), VideoHello(configID: 1, sessionID: 77, videoNonce: nonce(6)), now: 8 * sec)
        #expect(m.videoProven(ConnectionID(400), now: 8 * sec).contains { if case .videoAttached = $0 { true } else { false } })
        #expect(m.videoProven(ConnectionID(401), now: 8 * sec).contains(.closeVideo(ConnectionID(401))))
    }

    @Test func videoProofIsVoidedWhenTheSessionEndsFirst() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        _ = m.videoOpened(V, now: 0)
        _ = m.videoHello(V, VideoHello(configID: 1, sessionID: 77, videoNonce: nonce(1)), now: 0)
        _ = m.connectionClosed(A)
        #expect(m.videoProven(V, now: 1) == [.closeVideo(V), .log(.warning, ev: "video_hello_rejected", conn: V,
                                                                   fields: "reason=stale")])
    }

    @Test func videoWithoutHelloTimesOut() {
        var m = makeMachine()
        _ = m.videoOpened(V, now: 0)
        #expect(m.tick(now: 4 * sec).isEmpty)
        #expect(m.tick(now: 5 * sec).contains(.closeVideo(V)))
    }

    @Test func sameDeviceWhilePairingIsPendingIsBusyAndTheApprovalStaysValid() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(), now: 0)  // pending
        _ = m.connectionOpened(B, now: 1)
        let second = m.received(B, hello(), now: 1)  // same device, but it would need PAIRING: BUSY
        #expect(ackStatuses(second, to: B) == [.busy])
        #expect(!second.contains { if case .cancelApproval = $0 { true } else { false } })
        #expect(m.approvalDecided(B, approved: true, now: 2).isEmpty)  // B never had an approval
        #expect(m.status == .pending(deviceName: "Pad"))
        _ = m.approvalDecided(A, approved: true, now: 3)
        #expect(ackStatuses(m.pairingPersisted(A, stored: true, now: 3), to: A) == [.accepted])
    }

    @Test func forgetDevicesRequiresApprovalAgain() {
        var m = makeMachine(approved: [device(1)])
        m.forgetApprovedDevices()
        _ = m.connectionOpened(A, now: 0)
        #expect(ackStatuses(m.received(A, hello(), now: 0), to: A) == [.pendingApproval])
    }

    @Test func logActionsNeverContainDeviceName() {
        var m = makeMachine()
        var all: [SessionAction] = m.connectionOpened(A, now: 0)
        all += m.received(A, hello(name: "SecretName"), now: 0)
        all += m.approvalDecided(A, approved: true, now: 1)
        all += m.pairingPersisted(A, stored: true, now: 1)
        for case .log(_, _, _, let fields) in all { #expect(!fields.contains("SecretName")) }
    }
}

// MARK: - STREAM_PREFS reconfiguration (T-049)

extension SessionMachineTests {
    private func config(id: UInt16, width: UInt16 = 2100, height: UInt16 = 1380, fps: UInt16 = 120) -> StreamConfig {
        var c = sampleConfig
        c.configID = id
        c.widthPx = width
        c.heightPx = height
        c.fps = fps
        return c
    }

    @Test func streamPrefsFromTheActiveSessionIsDelivered() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        let prefs = Message.streamPrefs(StreamPrefs(fps: 120, scalePermille: 750))
        #expect(m.received(A, prefs, now: 1).contains(.deliver(A, prefs)))
    }

    @Test func reconfigureSendsConfigThenClosesVideoAndOldConfigIdIsStale() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        attachVideo(&m, V, nonce: 1)
        let actions = m.reconfigure(sessionID: 77, config: config(id: 2))
        #expect(actions.first == .send(A, .streamConfig(config(id: 2))))
        #expect(actions.contains(.closeVideo(V)))
        // The old config_id no longer attaches; the new one does, without closing anything (video was dropped).
        _ = m.videoOpened(V2, now: 1)
        #expect(m.videoHello(V2, VideoHello(configID: 1, sessionID: 77, videoNonce: nonce(2)), now: 1)
            .contains(.closeVideo(V2)))
        _ = m.videoOpened(V2, now: 2)
        _ = m.videoHello(V2, VideoHello(configID: 2, sessionID: 77, videoNonce: nonce(3)), now: 2)
        let proven = m.videoProven(V2, now: 2)
        #expect(proven.contains { if case .videoAttached(V2, A, 77, 2, _) = $0 { true } else { false } })
        #expect(!proven.contains(.closeVideo(V)))
    }

    @Test func reconfigureInvalidatesAProvingVideoConnection() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        _ = m.videoOpened(V, now: 0)
        _ = m.videoHello(V, VideoHello(configID: 1, sessionID: 77, videoNonce: nonce(1)), now: 0)
        _ = m.reconfigure(sessionID: 77, config: config(id: 2))
        #expect(m.videoProven(V, now: 1).first == .closeVideo(V))
    }

    @Test func reconfigureIgnoresUnknownSessionOrSameConfigId() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        #expect(m.reconfigure(sessionID: 99, config: config(id: 2)).isEmpty)
        #expect(m.reconfigure(sessionID: 77, config: config(id: 1)).isEmpty)
    }
}

// MARK: - CLIPBOARD (T-054)

extension SessionMachineTests {
    @Test func clipboardFromTheActiveSessionIsDelivered() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        let clip = Message.clipboard(.text(seq: 1, "x"))
        #expect(m.received(A, clip, now: 1).contains(.deliver(A, clip)))
    }

    @Test func hostClipboardGoesToTheActiveSessionOnly() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        let clip = Message.clipboard(.empty(seq: 0))
        #expect(m.send(sessionID: 77, clip) == [.send(A, clip)])
        #expect(m.send(sessionID: 78, clip).isEmpty)
    }

    @Test func settingsOpenFromTheClientIsWrongDirectionAndIgnored() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        let before = m.status
        #expect(m.received(A, .settingsOpen(SettingsOpen()), now: 1).isEmpty)
        #expect(m.status == before)
        // The session is still alive and keeps delivering input.
        #expect(m.received(A, keyDown(), now: 2) == [.deliver(A, keyDown())])
    }

    @Test func settingsOpenWhilePendingIsIgnored() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(), now: 0)
        #expect(m.received(A, .settingsOpen(SettingsOpen()), now: 1).isEmpty)
    }

    @Test func filesInfoIsDeliveredOnlyFromTheActiveSession() {
        let info = Message.filesInfo(FilesInfo(state: .ready, port: 47010, token: "t"))
        var pending = makeMachine()
        _ = pending.connectionOpened(A, now: 0)
        _ = pending.received(A, hello(), now: 0)
        #expect(pending.received(A, info, now: 1).isEmpty)

        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        #expect(m.received(A, info, now: 1) == [.deliver(A, info)])
    }
}

// MARK: - SETTINGS_OPEN from the host menu (T-106, decision 0013)

private func helloWith(_ caps: Capabilities, dev: UInt8 = 1) -> Message {
    var c = TestClient(device: dev)
    c.hello.capabilities = caps
    return c.message
}

private func isSkip(_ a: SessionAction, _ reason: String) -> Bool {
    a == .log(.info, ev: "settings_open_skipped", conn: nil, fields: "reason=\(reason)")
}

extension SessionMachineTests {
    @Test func settingsOpenIsSentToACapableActiveSession() {
        var m = makeMachine(approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, helloWith([.pen, .settingsPanel]), now: 0)
        _ = m.received(A, .ping(Ping(seq: 0, senderTimeUs: 0)), now: 0)  // the proof (T-152)
        #expect(m.settingsPanelAvailable)
        let actions = m.openSettingsPanel()
        #expect(sent(actions, to: A) == [.settingsOpen(SettingsOpen())])
        #expect(actions.contains(.log(.info, ev: "settings_open_sent", conn: A, fields: "")))
    }

    @Test func settingsOpenIsNotSentWithoutTheCapability() {
        var m = makeMachine(approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, helloWith([.pen, .touch, .audioPCM]), now: 0)
        _ = m.received(A, .ping(Ping(seq: 0, senderTimeUs: 0)), now: 0)  // the proof (T-152)
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
        #expect(!m.settingsPanelAvailable)
        let actions = m.openSettingsPanel()
        #expect(sent(actions, to: A).isEmpty)
        #expect(actions.count == 1 && isSkip(actions[0], "no_capability"))
    }

    @Test func settingsOpenIsNotSentWithoutAnActiveSession() {
        var m = makeMachine()
        #expect(!m.settingsPanelAvailable)
        let none = m.openSettingsPanel()
        #expect(none.count == 1 && isSkip(none[0], "no_session"))
        // A pending (not yet approved) capable client gets nothing either.
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, helloWith([.settingsPanel]), now: 0)
        #expect(m.status == .pending(deviceName: "Pad"))
        #expect(!m.settingsPanelAvailable)
        let pending = m.openSettingsPanel()
        #expect(sent(pending, to: A).isEmpty)
        #expect(pending.count == 1 && isSkip(pending[0], "no_session"))
    }

    @Test func settingsOpenAvailabilityEndsWithTheSession() {
        var m = makeMachine(approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, helloWith([.settingsPanel]), now: 0)
        _ = m.received(A, .ping(Ping(seq: 0, senderTimeUs: 0)), now: 0)  // the proof (T-152)
        #expect(m.settingsPanelAvailable)
        _ = m.connectionClosed(A)
        #expect(!m.settingsPanelAvailable)
        #expect(sent(m.openSettingsPanel(), to: A).isEmpty)
    }
}
