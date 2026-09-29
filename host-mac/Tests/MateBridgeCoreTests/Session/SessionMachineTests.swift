import Foundation
import Testing
@testable import MateBridgeCore

private let sec: UInt64 = 1_000_000
private let A = ConnectionID(1)
private let B = ConnectionID(2)
private let V = ConnectionID(100)

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }

private func hello(_ dev: UInt8 = 1, version: UInt16 = 0, name: String = "Pad") -> Message {
    .hello(Hello(protocolVersion: version, deviceID: device(dev), screenWidthPx: 2800, screenHeightPx: 1840,
                 densityDpi: 360, maxRefreshHz: 144, capabilities: [.pen], deviceName: name))
}

private let sampleConfig = StreamConfig(configID: 1, codec: .h264, widthPx: 2800, heightPx: 1840, widthPt: 1400,
                                        heightPt: 920, fps: 60, bitrateKbps: 40000, colorPrimaries: 1, transfer: 1,
                                        matrix: 1, fullRange: true)

private func makeMachine(approved: Set<DeviceID> = []) -> SessionMachine {
    var m = SessionMachine(configuration: .init(hostName: "Mac", makeStreamConfig: { _ in sampleConfig },
                                                makeSessionID: { 77 }), approvedDevices: approved)
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

private func keyDown() -> Message {
    .key(KeyEvent(timeUs: 1, scanCode: 30, androidKeyCode: 29, action: .down, capsLockOn: false))
}

/// Opens a connection and drives it to ACTIVE for a pre-approved device.
private func activate(_ m: inout SessionMachine, _ id: ConnectionID, dev: UInt8 = 1, now: UInt64 = 0) {
    _ = m.connectionOpened(id, now: now)
    _ = m.received(id, hello(dev), now: now)
}

@Suite struct SessionMachineTests {
    @Test func approvedDeviceIsAcceptedWithConfig() {
        var m = makeMachine(approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        let actions = m.received(A, hello(), now: 10)
        let msgs = sent(actions, to: A)
        guard case .helloAck(let ack) = msgs[0] else { Issue.record("no ack"); return }
        #expect(ack.status == .accepted)
        #expect(ack.sessionID == 77)
        #expect(ack.videoPort == 5555)
        #expect(ack.hostName == "Mac")
        #expect(msgs[1] == .streamConfig(sampleConfig))
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
        #expect(has(first) { $0 == .requestApproval(A, deviceID: device(1), deviceName: "Tab") })
        #expect(m.status == .pending(deviceName: "Tab"))

        let approved = m.approvalDecided(A, approved: true, now: 2 * sec)
        #expect(ackStatuses(approved, to: A) == [.accepted])
        #expect(has(approved) { $0 == .rememberDevice(device(1), name: "Tab") })
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
        #expect(!actions.contains { if case .rememberDevice = $0 { true } else { false } })
        #expect(m.status == .idle)
    }

    @Test func pendingConnectionDropCancelsApproval() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(), now: 0)
        let actions = m.connectionClosed(A)
        #expect(has(actions) { $0 == .cancelApproval(A) })
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

    @Test func sameDeviceTakesOverAndOldSessionIsReleasedFirst() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        _ = m.connectionOpened(B, now: 5)
        let actions = m.received(B, hello(1), now: 5)
        let idxRelease = actions.firstIndex { $0 == .releaseInput(A, .superseded) }
        let idxBye = actions.firstIndex { $0 == .send(A, .bye(.superseded)) }
        let idxClose = actions.firstIndex { $0 == .close(A) }
        let idxAck = actions.firstIndex { if case .send(B, .helloAck) = $0 { true } else { false } }
        #expect(idxRelease != nil && idxBye != nil && idxClose != nil && idxAck != nil)
        if let r = idxRelease, let b = idxBye, let c = idxClose, let a = idxAck {
            #expect(r < b && b < c && c < a)
        }
        #expect(ackStatuses(actions, to: B) == [.accepted])
        // Late traffic from the old connection is ignored.
        #expect(m.received(A, keyDown(), now: 6).isEmpty)
    }

    @Test func takeoverClosesOldVideoConnection() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        _ = m.videoOpened(V, now: 1)
        _ = m.videoHello(V, VideoHello(configID: 1, sessionID: 77), now: 1)
        _ = m.connectionOpened(B, now: 2)
        #expect(has(m.received(B, hello(1), now: 2)) { $0 == .closeVideo(V) })
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
        _ = m.videoOpened(V, now: 0)
        _ = m.videoHello(V, VideoHello(configID: 1, sessionID: 77), now: 0)
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
        let ok = m.videoHello(V, VideoHello(configID: 1, sessionID: 77), now: 0)
        #expect(ok == [.videoAttached(video: V, session: A, sessionID: 77, configID: 1)])
    }

    @Test func videoHelloWithoutSessionIsRejected() {
        var m = makeMachine()
        _ = m.videoOpened(V, now: 0)
        #expect(m.videoHello(V, VideoHello(configID: 1, sessionID: 77), now: 0).contains(.closeVideo(V)))
    }

    @Test func videoReconnectReplacesOldVideoConnection() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A)
        let V2 = ConnectionID(101)
        _ = m.videoOpened(V, now: 0)
        _ = m.videoHello(V, VideoHello(configID: 1, sessionID: 77), now: 0)
        _ = m.videoOpened(V2, now: 1)
        let actions = m.videoHello(V2, VideoHello(configID: 1, sessionID: 77), now: 1)
        #expect(actions.first == .closeVideo(V))
    }

    @Test func videoWithoutHelloTimesOut() {
        var m = makeMachine()
        _ = m.videoOpened(V, now: 0)
        #expect(m.tick(now: 4 * sec).isEmpty)
        #expect(m.tick(now: 5 * sec).contains(.closeVideo(V)))
    }

    @Test func staleApprovalCannotApproveTakeoverConnection() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(), now: 0)  // pending
        _ = m.connectionOpened(B, now: 1)
        let takeover = m.received(B, hello(), now: 1)  // same device: A is cancelled, B pending
        #expect(takeover.contains(.cancelApproval(A)))
        #expect(takeover.contains(.requestApproval(B, deviceID: device(1), deviceName: "Pad")))
        #expect(m.approvalDecided(A, approved: true, now: 2).isEmpty)  // stale click for A
        #expect(m.status == .pending(deviceName: "Pad"))
        #expect(!m.approvedDevices.contains(device(1)))
        #expect(ackStatuses(m.approvalDecided(B, approved: true, now: 3), to: B) == [.accepted])
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
        for case .log(_, _, _, let fields) in all { #expect(!fields.contains("SecretName")) }
    }
}
