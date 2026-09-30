import Foundation
import Testing
@testable import MateBridgeCore

// T-043: a pairing request whose tablet left keeps its approval window (same code, 2 min) and that handshake's
// new_pair_key. "Allow" stores that key and the approval (no ACCEPTED); the device's next connection is PAIRED.
// There is no device_id based auto-accept. Time is a fake clock (every event carries `now`).

private let sec: UInt64 = 1_000_000
private let A = ConnectionID(1)
private let B = ConnectionID(2)
private let C = ConnectionID(3)
private let pairKey = SecretBytes([UInt8](repeating: 0x5a, count: 32))

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }

private let config = StreamConfig(configID: 1, codec: .h264, widthPx: 2800, heightPx: 1840, widthPt: 1400,
                                  heightPt: 920, fps: 60, bitrateKbps: 40000, colorPrimaries: 1, transfer: 1,
                                  matrix: 1, fullRange: true)

private func makeMachine(keys: InMemoryPairKeyStore = InMemoryPairKeyStore()) -> SessionMachine {
    var m = SessionMachine(configuration: .init(hostName: "Mac", makeStreamConfig: { _ in config },
                                                makeSessionID: { 77 }, pairKeys: keys))
    m.videoPort = 5555
    m.configuration.releaseSilenceUs = 1000 * sec
    m.configuration.closeSilenceUs = 1000 * sec
    return m
}

private func connect(_ m: inout SessionMachine, _ id: ConnectionID, dev: UInt8 = 1, now: UInt64,
                     client: TestClient? = nil) -> [SessionAction] {
    _ = m.connectionOpened(id, now: now)
    return m.received(id, (client ?? TestClient(device: dev)).message, now: now)
}

private func requests(_ actions: [SessionAction]) -> [ConnectionID] {
    actions.compactMap { if case .requestApproval(let id, _, _, _) = $0 { id } else { nil } }
}
private func cancels(_ actions: [SessionAction]) -> [ConnectionID] {
    actions.compactMap { if case .cancelApproval(let id) = $0 { id } else { nil } }
}
private func orphans(_ actions: [SessionAction]) -> [ConnectionID] {
    actions.compactMap { if case .approvalOrphaned(let id) = $0 { id } else { nil } }
}
private func orphanPersists(_ actions: [SessionAction]) -> [SecretBytes] {
    actions.compactMap { if case .persistOrphanPairing(_, _, _, let key) = $0 { key } else { nil } }
}
private func liveSaves(_ actions: [SessionAction]) -> Int {
    actions.filter { if case .persistPairing = $0 { true } else { false } }.count
}
private func firstAck(_ actions: [SessionAction]) -> HelloAck? {
    for a in actions { if case .send(_, .helloAck(let ack)) = a { return ack } }
    return nil
}

/// Runs a PAIRING handshake for a real test client and returns the key the client derived (what T-044 stores).
private func pairingHandshake(_ m: inout SessionMachine, _ id: ConnectionID, now: UInt64) throws -> (TestClient, SecretBytes) {
    var client = TestClient(device: 1)
    let actions = connect(&m, id, now: now, client: client)
    let ack = try #require(firstAck(actions))
    try client.receiveFirstAck(ack, pairKey: nil)
    return (client, try #require(client.schedule?.newPairKey))
}

@Suite struct PairingOrphanApprovalTests {
    @Test func aLeavingPendingTabletKeepsTheWindowOpenForTwoMinutes() {
        var m = makeMachine()
        #expect(requests(connect(&m, A, now: 0)) == [A])
        let closed = m.connectionClosed(A)
        #expect(orphans(closed) == [A] && cancels(closed).isEmpty)
        #expect(m.status == .idle)
        #expect(m.tick(now: 119 * sec).isEmpty)
        #expect(cancels(m.tick(now: 120 * sec)) == [A])
        #expect(m.orphanDeviceForTesting == nil)
        #expect(cancels(m.tick(now: 121 * sec)).isEmpty)
    }

    @Test func byeAlsoKeepsTheWindow() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        #expect(orphans(m.received(A, .bye(.normal), now: 5 * sec)) == [A])
    }

    @Test func protocolErrorShutdownAndApprovalTimeoutStillCancel() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        let err = m.protocolError(A)
        #expect(cancels(err) == [A] && orphans(err).isEmpty)
        _ = connect(&m, B, now: 0)
        let auth = m.recordAuthFailed(B, counter: 1)
        #expect(cancels(auth) == [B] && orphans(auth).isEmpty)
        _ = connect(&m, C, now: 0)
        let down = m.shutdown()
        #expect(cancels(down) == [C] && orphans(down).isEmpty)
        _ = connect(&m, A, now: 10 * sec)
        let timeout = m.tick(now: 70 * sec)
        #expect(cancels(timeout) == [A] && orphans(timeout).isEmpty)
    }

    @Test func allowOnAnOrphanStoresThatHandshakesKeyAndSendsNothing() throws {
        var m = makeMachine()
        let (_, clientKey) = try pairingHandshake(&m, A, now: 0)
        _ = m.connectionClosed(A)
        let allow = m.approvalDecided(A, approved: true, now: 30 * sec)
        #expect(orphanPersists(allow) == [clientKey])  // the key the tablet stored at PAIRING start
        #expect(liveSaves(allow) == 0)
        #expect(!allow.contains { if case .send = $0 { true } else { false } })
        #expect(cancels(allow) == [A])
        // Approval counts only after the store finished.
        #expect(!m.approvedDevices.contains(device(1)))
        m.orphanPairingPersisted(deviceID: device(1), stored: true)
        #expect(m.approvedDevices.contains(device(1)))
    }

    @Test func afterAnOrphanApprovalTheReconnectIsPairedWithThatKey() throws {
        let keys = InMemoryPairKeyStore()
        var m = makeMachine(keys: keys)
        let (_, clientKey) = try pairingHandshake(&m, A, now: 0)
        _ = m.connectionClosed(A)
        let allow = m.approvalDecided(A, approved: true, now: 30 * sec)
        try keys.save(try #require(orphanPersists(allow).first), for: device(1))  // what the server does
        m.orphanPairingPersisted(deviceID: device(1), stored: true)

        var again = TestClient(device: 1, eph: EphemeralKeyPair())
        let hello = connect(&m, B, now: 40 * sec, client: again)
        #expect(requests(hello).isEmpty)
        let ack = try #require(firstAck(hello))
        #expect(ack.status == .accepted && ack.keyMode == .paired)
        try again.receiveFirstAck(ack, pairKey: clientKey)  // only the holder of the stored key derives the session
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
    }

    @Test func aReconnectWhileTheOrphanSaveIsInFlightIsBusyThenPaired() throws {
        let keys = InMemoryPairKeyStore()
        var m = makeMachine(keys: keys)
        let (_, clientKey) = try pairingHandshake(&m, A, now: 0)
        _ = m.connectionClosed(A)
        let allow = m.approvalDecided(A, approved: true, now: 10 * sec)
        #expect(orphanPersists(allow) == [clientKey])
        // The Keychain save has not finished: the device must not start another PAIRING (it would replace its key).
        let during = connect(&m, B, now: 11 * sec, client: TestClient(device: 1, eph: EphemeralKeyPair()))
        #expect(requests(during).isEmpty && firstAck(during)?.status == .busy)
        #expect(during.contains(.close(B)))
        // Another device is unaffected by the in-flight save.
        let other = connect(&m, C, dev: 2, now: 11 * sec)
        #expect(requests(other) == [C])
        _ = m.connectionClosed(C)
        // Save done: the same device's next HELLO is PAIRED through the normal lookup.
        try keys.save(clientKey, for: device(1))
        m.orphanPairingPersisted(deviceID: device(1), stored: true)
        let after = connect(&m, ConnectionID(4), now: 12 * sec, client: TestClient(device: 1, eph: EphemeralKeyPair()))
        #expect(firstAck(after)?.keyMode == .paired)
    }

    @Test func aFailedOrDiscardedOrphanSaveAlsoEndsTheBusyPeriod() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        _ = m.approvalDecided(A, approved: true, now: 1 * sec)
        m.orphanPairingPersisted(deviceID: device(1), stored: false)  // failed, or revoked by "forget" meanwhile
        #expect(!m.approvedDevices.contains(device(1)))
        #expect(requests(connect(&m, B, now: 2 * sec)) == [B])  // asks normally again
    }

    @Test func rejectAndExpiryStoreNothing() throws {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        let reject = m.approvalDecided(A, approved: false, now: 5 * sec)
        #expect(cancels(reject) == [A] && orphanPersists(reject).isEmpty)
        #expect(m.approvalDecided(A, approved: true, now: 6 * sec).isEmpty)  // the window is gone

        _ = connect(&m, B, now: 10 * sec)
        _ = m.connectionClosed(B)
        _ = m.tick(now: 131 * sec)
        #expect(m.approvalDecided(B, approved: true, now: 132 * sec).isEmpty)
        #expect(m.approvedDevices.isEmpty)
    }

    @Test func anAnswerAfterTheDeadlineButBeforeTickStoresNothing() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        #expect(orphanPersists(m.approvalDecided(A, approved: true, now: 121 * sec)).isEmpty)
    }

    @Test func aNewPairingRequestReplacesTheOldWindowAndDropsItsKey() throws {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        let again = connect(&m, B, now: 3 * sec)  // same device, new handshake
        #expect(cancels(again) == [A] && requests(again) == [B])
        #expect(m.orphanDeviceForTesting == nil)
        // The old window's answer is void; nothing is stored for it.
        #expect(m.approvalDecided(A, approved: true, now: 4 * sec).isEmpty)
    }

    @Test func noDeviceIDAutoAccept() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        _ = m.approvalDecided(A, approved: true, now: 1 * sec)
        m.orphanPairingPersisted(deviceID: device(1), stored: true)  // approved, but the key store never got the key
        // Without a stored key a HELLO with the same device_id (any ephemeral key) is PAIRING and asks the user again.
        let hello = connect(&m, B, now: 2 * sec, client: TestClient(device: 1, eph: EphemeralKeyPair()))
        #expect(requests(hello) == [B])
        #expect(firstAck(hello)?.keyMode == .pairing && firstAck(hello)?.status == .pendingApproval)
        #expect(liveSaves(hello) == 0)
    }

    @Test func forgetAndShutdownDropTheWindowAndItsKey() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        let down = m.shutdown()
        #expect(cancels(down) == [A])
        #expect(m.approvalDecided(A, approved: true, now: 1 * sec).isEmpty)
    }

    @Test func aLiveConnectionStillDecidesAsBefore() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        let allow = m.approvalDecided(A, approved: true, now: 1 * sec)
        #expect(liveSaves(allow) == 1 && orphanPersists(allow).isEmpty)
    }
}
