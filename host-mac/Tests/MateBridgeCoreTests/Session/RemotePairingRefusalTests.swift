import Testing
@testable import MateBridgeCore

// T-338 / decision 0038 section 5: a remote peer never starts a pairing. PAIRED connections are unaffected.

private let A = ConnectionID(1)
private let B = ConnectionID(2)
private let pairKey = SecretBytes([UInt8](repeating: 0x5a, count: 32))

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }

private let config = StreamConfig(configID: 1, codec: .h264, widthPx: 2800, heightPx: 1840, widthPt: 1400,
                                  heightPt: 920, fps: 60, bitrateKbps: 40000, colorPrimaries: 1, transfer: 1,
                                  matrix: 1, fullRange: true)

/// `inline`: pair keys in memory (looked up synchronously); false: the app's asynchronous lookup.
private func makeMachine(approved: Set<DeviceID> = [], withKeys: Bool = true, inline: Bool = true) -> SessionMachine {
    let keys = InMemoryPairKeyStore(keys: withKeys
        ? Dictionary(uniqueKeysWithValues: approved.map { ($0, pairKey) }) : [:])
    var m = SessionMachine(configuration: .init(hostName: "Mac", makeStreamConfig: { _ in config },
                                                makeSessionID: { 77 }, pairKeys: inline ? keys : nil),
                           approvedDevices: approved)
    m.videoPort = 5555
    return m
}

private func hello(_ dev: UInt8) -> Message { .hello(TestClient(device: dev).hello) }

private func acks(_ actions: [SessionAction], to id: ConnectionID) -> [HelloAck] {
    actions.compactMap { if case .send(id, .helloAck(let a)) = $0 { a } else { nil } }
}

private func isRequestApproval(_ a: SessionAction) -> Bool { if case .requestApproval = a { true } else { false } }

private func noApprovalState(_ actions: [SessionAction]) -> Bool {
    !actions.contains {
        switch $0 {
        case .requestApproval, .approvalOrphaned, .persistPairing, .persistOrphanPairing, .startEncryption,
             .sessionStarted, .lookupPairKey: true
        default: false
        }
    }
}

private func isRefusalLog(_ a: SessionAction) -> Bool {
    if case .log(_, "pairing_refused", _, "reason=remote") = a { true } else { false }
}

@Suite struct RemotePairingRefusalTests {
    @Test func remoteNewDeviceIsRejectedPlaintextAndNothingOpens() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0, peer: .remote)
        let actions = m.received(A, hello(1), now: 0)
        let sent = acks(actions, to: A)
        #expect(sent.count == 1)
        #expect(sent.first?.status == .rejected)
        #expect(sent.first?.keyMode == KeyMode.none)
        #expect(actions.contains(.close(A)))
        #expect(actions.contains(where: isRefusalLog))
        #expect(noApprovalState(actions))
        #expect(m.status == .idle)
        #expect(!m.isPendingApproval(A))
        #expect(m.orphanDeviceForTesting == nil)
        // Closing the transport afterwards creates no orphan approval either.
        let closed = m.connectionClosed(A)
        #expect(noApprovalState(closed))
        #expect(m.orphanDeviceForTesting == nil)
    }

    @Test func remoteApprovedDeviceWithoutKeyIsRejectedToo() {
        var m = makeMachine(approved: [device(1)], withKeys: false)
        _ = m.connectionOpened(A, now: 0, peer: .remote)
        let actions = m.received(A, hello(1), now: 0)
        #expect(acks(actions, to: A).map(\.status) == [.rejected])
        #expect(actions.contains(where: isRefusalLog))
        #expect(noApprovalState(actions))
        #expect(m.status == .idle)
    }

    @Test func remoteApprovedDeviceWithoutKeyIsRejectedAfterTheAsyncLookup() {
        var m = makeMachine(approved: [device(1)], withKeys: false, inline: false)
        _ = m.connectionOpened(A, now: 0, peer: .remote)
        let lookup = m.received(A, hello(1), now: 0)
        #expect(lookup.contains { if case .lookupPairKey = $0 { true } else { false } })
        #expect(acks(lookup, to: A).isEmpty)
        let resolved = m.pairKeyResolved(A, key: nil, now: 1)
        #expect(acks(resolved, to: A).map(\.status) == [.rejected])
        #expect(acks(resolved, to: A).first?.keyMode == KeyMode.none)
        #expect(resolved.contains(.close(A)))
        #expect(resolved.contains(where: isRefusalLog))
        #expect(noApprovalState(resolved))
        #expect(m.status == .idle)
    }

    @Test func remotePairedDeviceIsAcceptedAsToday() {
        for inline in [true, false] {
            var m = makeMachine(approved: [device(1)], inline: inline)
            _ = m.connectionOpened(A, now: 0, peer: .remote)
            var actions = m.received(A, hello(1), now: 0)
            if !inline { actions = m.pairKeyResolved(A, key: pairKey, now: 0) }
            let sent = acks(actions, to: A)
            #expect(sent.map(\.status) == [.accepted])
            #expect(sent.first?.keyMode == .paired)
            #expect(actions.contains { if case .startEncryption(A, _) = $0 { true } else { false } })
            #expect(!actions.contains(where: isRefusalLog))
            #expect(!actions.contains(.close(A)))
        }
    }

    @Test func remoteNewDeviceWhileSessionLiveIsRejectedNotBusy() {
        // BUSY would tell an unauthenticated remote peer that a session is live.
        var m = makeMachine(approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(1), now: 0)
        _ = m.connectionOpened(B, now: 1, peer: .remote)
        let actions = m.received(B, hello(2), now: 1)
        #expect(acks(actions, to: B).map(\.status) == [.rejected])
        #expect(actions.contains(where: isRefusalLog))
    }

    @Test func remoteRefusalDoesNotDisturbAnOpenApprovalWindow() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)  // local device pairing, window open
        let first = m.received(A, hello(1), now: 0)
        #expect(first.contains(where: isRequestApproval))
        _ = m.connectionOpened(B, now: 1, peer: .remote)
        let refused = m.received(B, hello(1), now: 1)
        #expect(acks(refused, to: B).map(\.status) == [.rejected])
        #expect(!refused.contains { if case .cancelApproval = $0 { true } else { false } })
        #expect(m.isPendingApproval(A))
    }

    @Test func localPeerStillPairs() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0, peer: .local)
        let actions = m.received(A, hello(1), now: 0)
        #expect(acks(actions, to: A).map(\.status) == [.pendingApproval])
        #expect(acks(actions, to: A).first?.keyMode == .pairing)
        #expect(actions.contains(where: isRequestApproval))
        #expect(!actions.contains(where: isRefusalLog))
        #expect(m.status == .pending(deviceName: "Pad"))
    }

    @Test func versionMismatchStillWinsOverTheRemoteRefusal() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0, peer: .remote)
        let bad = Message.hello(TestClient(device: 1, version: 9).hello)
        #expect(acks(m.received(A, bad, now: 0), to: A).map(\.status) == [.versionMismatch])
    }
}
