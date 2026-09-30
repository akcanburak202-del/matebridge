import Foundation
import Testing
@testable import MateBridgeCore

// T-043: a pairing request whose tablet left keeps its approval window; "Allow" records a short, single-use
// pre-approval (memory only) and the device's next PAIRING HELLO is accepted without asking again.
// Time is a fake clock (every event carries `now`).

private let sec: UInt64 = 1_000_000
private let A = ConnectionID(1)
private let B = ConnectionID(2)
private let C = ConnectionID(3)
private let pairKey = SecretBytes([UInt8](repeating: 0x5a, count: 32))

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }

private let config = StreamConfig(configID: 1, codec: .h264, widthPx: 2800, heightPx: 1840, widthPt: 1400,
                                  heightPt: 920, fps: 60, bitrateKbps: 40000, colorPrimaries: 1, transfer: 1,
                                  matrix: 1, fullRange: true)

private func makeMachine(approved: Set<DeviceID> = []) -> SessionMachine {
    let keys = InMemoryPairKeyStore(keys: Dictionary(uniqueKeysWithValues: approved.map { ($0, pairKey) }))
    var m = SessionMachine(configuration: .init(hostName: "Mac", makeStreamConfig: { _ in config },
                                                makeSessionID: { 77 }, pairKeys: keys), approvedDevices: approved)
    m.videoPort = 5555
    m.configuration.releaseSilenceUs = 1000 * sec
    m.configuration.closeSilenceUs = 1000 * sec
    return m
}

private func connect(_ m: inout SessionMachine, _ id: ConnectionID, dev: UInt8 = 1, now: UInt64) -> [SessionAction] {
    _ = m.connectionOpened(id, now: now)
    return m.received(id, TestClient(device: dev).message, now: now)
}

private func requests(_ actions: [SessionAction]) -> [ConnectionID] {
    actions.compactMap { if case .requestApproval(let id, _, _, _) = $0 { id } else { nil } }
}
private func persists(_ actions: [SessionAction]) -> [ConnectionID] {
    actions.compactMap { if case .persistPairing(let id, _, _, _) = $0 { id } else { nil } }
}
private func cancels(_ actions: [SessionAction]) -> [ConnectionID] {
    actions.compactMap { if case .cancelApproval(let id) = $0 { id } else { nil } }
}
private func orphans(_ actions: [SessionAction]) -> [ConnectionID] {
    actions.compactMap { if case .approvalOrphaned(let id) = $0 { id } else { nil } }
}
private func logs(_ actions: [SessionAction], _ ev: String) -> Bool {
    actions.contains { if case .log(_, let e, _, _) = $0 { e == ev } else { false } }
}

@Suite struct PairingPreapprovalTests {
    @Test func aLeavingPendingTabletKeepsTheWindowOpen() {
        var m = makeMachine()
        #expect(requests(connect(&m, A, now: 0)) == [A])
        let closed = m.connectionClosed(A)
        #expect(orphans(closed) == [A] && cancels(closed).isEmpty)
        #expect(m.status == .idle)  // the slot is free for other devices
        // The window stays open for two minutes, then closes.
        #expect(m.tick(now: 119 * sec).isEmpty)
        #expect(cancels(m.tick(now: 120 * sec)) == [A])
        #expect(cancels(m.tick(now: 121 * sec)).isEmpty)
    }

    @Test func byeAlsoKeepsTheWindow() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        let actions = m.received(A, .bye(.normal), now: 5 * sec)
        #expect(orphans(actions) == [A])
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

    @Test func allowWithoutConnectionThenReconnectIsAcceptedWithoutAsking() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        let allow = m.approvalDecided(A, approved: true, now: 30 * sec)
        #expect(cancels(allow) == [A] && persists(allow).isEmpty)
        #expect(m.preapprovedForTesting(now: 30 * sec) == [device(1)])

        let hello = connect(&m, B, now: 40 * sec)
        #expect(requests(hello).isEmpty)
        #expect(persists(hello) == [B])
        #expect(logs(hello, "approval_preapproved"))
        // First ack is PENDING_APPROVAL/pairing; ACCEPTED follows only after the key is stored.
        guard case .send(B, .helloAck(let ack))? = hello.first else { Issue.record("no ack"); return }
        #expect(ack.status == .pendingApproval && ack.keyMode == .pairing)
        let done = m.pairingPersisted(B, stored: true, now: 40 * sec)
        #expect(done.contains { if case .send(B, .helloAck(let a)) = $0 { a.status == .accepted } else { false } })
        #expect(m.approvedDevices.contains(device(1)))
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
    }

    @Test func preapprovalIsSingleUse() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        _ = m.approvalDecided(A, approved: true, now: 1 * sec)
        _ = connect(&m, B, now: 2 * sec)
        _ = m.pairingPersisted(B, stored: true, now: 2 * sec)
        _ = m.connectionClosed(B)
        // Pairing again (the machine holds no key in this test) asks the user again.
        #expect(m.preapprovedForTesting(now: 3 * sec).isEmpty)
        #expect(requests(connect(&m, C, now: 3 * sec)) == [C])
    }

    @Test func aDroppedPreapprovedAttemptStillConsumesItAndShowsNoWindow() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        _ = m.approvalDecided(A, approved: true, now: 1 * sec)
        _ = connect(&m, B, now: 2 * sec)
        let closed = m.connectionClosed(B)  // before the store finished
        #expect(orphans(closed).isEmpty)
        #expect(m.preapprovedForTesting(now: 2 * sec).isEmpty)
        #expect(requests(connect(&m, C, now: 3 * sec)) == [C])
    }

    @Test func expiredPreapprovalFallsBackToNormalApproval() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        _ = m.approvalDecided(A, approved: true, now: 10 * sec)
        #expect(m.preapprovedForTesting(now: 129 * sec) == [device(1)])
        let late = connect(&m, B, now: 130 * sec)  // 120 s after the click
        #expect(requests(late) == [B] && persists(late).isEmpty)
    }

    @Test func rejectLeavesNoPreapprovalAndClosesTheWindow() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        let reject = m.approvalDecided(A, approved: false, now: 5 * sec)
        #expect(cancels(reject) == [A] && m.preapprovedForTesting(now: 5 * sec).isEmpty)
        #expect(requests(connect(&m, B, now: 6 * sec)) == [B])
        // A second answer for the same window is ignored.
        #expect(m.approvalDecided(A, approved: true, now: 7 * sec).isEmpty)
    }

    @Test func allowAfterTheWindowExpiredIsIgnored() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        _ = m.tick(now: 121 * sec)
        #expect(m.approvalDecided(A, approved: true, now: 122 * sec).isEmpty)
        #expect(m.preapprovedForTesting(now: 122 * sec).isEmpty)
    }

    @Test func aNewPairingRequestReplacesTheOldWindowAndKeepsTheOldPreapproval() {
        var m = makeMachine()
        // Device 1: allowed while away, then a second device-1 window is orphaned too.
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        _ = m.approvalDecided(A, approved: true, now: 1 * sec)
        // Another orphan window for device 2, then a new request for device 2 replaces it.
        _ = connect(&m, B, dev: 2, now: 2 * sec)
        _ = m.connectionClosed(B)
        let again = connect(&m, C, dev: 2, now: 3 * sec)
        #expect(cancels(again) == [B] && requests(again) == [C])
        // The old window is void; the old pre-approval for device 1 survives.
        #expect(m.approvalDecided(B, approved: true, now: 4 * sec).isEmpty)
        #expect(m.preapprovedForTesting(now: 4 * sec) == [device(1)])
    }

    @Test func forgetDropsPreapprovalsAndTheWindow() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        _ = m.connectionClosed(A)
        _ = m.approvalDecided(A, approved: true, now: 1 * sec)
        _ = connect(&m, B, dev: 2, now: 2 * sec)
        _ = m.connectionClosed(B)
        let down = m.shutdown()
        #expect(cancels(down) == [B])
        m.forgetApprovedDevices()
        #expect(m.preapprovedForTesting(now: 3 * sec).isEmpty)
        #expect(requests(connect(&m, C, now: 4 * sec)) == [C])
    }

    @Test func pairedDevicesAndTakeoverAreUntouched() {
        var m = makeMachine(approved: [device(1)])
        // A live PAIRED session; a stray pre-approval for the same device is not consumed by PAIRED HELLOs.
        _ = connect(&m, A, now: 0)
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
        _ = m.connectionOpened(B, now: 1 * sec)
        let takeover = m.received(B, TestClient(device: 1, eph: EphemeralKeyPair()).message, now: 1 * sec)
        #expect(takeover.contains { if case .send(B, .helloAck(let a)) = $0 { a.keyMode == .paired } else { false } })
        #expect(persists(takeover).isEmpty && requests(takeover).isEmpty)
        // A pairing of another device while the slot is taken is BUSY (no window, no pre-approval).
        let other = connect(&m, C, dev: 2, now: 2 * sec)
        #expect(other.contains { if case .send(C, .helloAck(let a)) = $0 { a.status == .busy } else { false } })
    }

    @Test func aLiveConnectionStillDecidesAsBefore() {
        var m = makeMachine()
        _ = connect(&m, A, now: 0)
        let allow = m.approvalDecided(A, approved: true, now: 1 * sec)
        #expect(persists(allow) == [A])
        #expect(m.preapprovedForTesting(now: 1 * sec).isEmpty)
    }
}
