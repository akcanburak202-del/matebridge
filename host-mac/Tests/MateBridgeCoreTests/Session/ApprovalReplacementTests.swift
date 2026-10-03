import Foundation
import Testing
@testable import MateBridgeCore

// T-155: a new PAIRING request replaces an orphaned approval window (T-043) without being blocked, but says whether the
// window belonged to the same or to a different device_id, so the panel can make the swap visible.

private let sec: UInt64 = 1_000_000
private let A = ConnectionID(1)
private let B = ConnectionID(2)

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }

private let config = StreamConfig(configID: 1, codec: .h264, widthPx: 2800, heightPx: 1840, widthPt: 1400,
                                  heightPt: 920, fps: 60, bitrateKbps: 40000, colorPrimaries: 1, transfer: 1,
                                  matrix: 1, fullRange: true)

private func makeMachine() -> SessionMachine {
    var m = SessionMachine(configuration: .init(hostName: "Mac", makeStreamConfig: { _ in config },
                                                makeSessionID: { 77 }, pairKeys: InMemoryPairKeyStore()))
    m.videoPort = 5555
    m.configuration.releaseSilenceUs = 1000 * sec
    m.configuration.closeSilenceUs = 1000 * sec
    return m
}

private func connect(_ m: inout SessionMachine, _ id: ConnectionID, dev: UInt8, name: String = "Pad",
                     now: UInt64) -> [SessionAction] {
    _ = m.connectionOpened(id, now: now)
    return m.received(id, TestClient(device: dev, name: name).message, now: now)
}

private struct Request: Equatable {
    let id: ConnectionID
    let deviceID: DeviceID
    let code: PairingCode
    let replaced: ApprovalReplacement
}

private func requests(_ actions: [SessionAction]) -> [Request] {
    actions.compactMap {
        if case .requestApproval(let id, let device, _, let code, let replaced) = $0 {
            Request(id: id, deviceID: device, code: code, replaced: replaced)
        } else { nil }
    }
}

private func index(_ actions: [SessionAction], _ match: (SessionAction) -> Bool) -> Int? {
    actions.firstIndex(where: match)
}

private func pendingLog(_ actions: [SessionAction]) -> String? {
    for a in actions {
        if case .log(_, "approval_pending", _, let fields) = a { return fields }
    }
    return nil
}

private func ackStatus(_ actions: [SessionAction]) -> HelloStatus? {
    for a in actions { if case .send(_, .helloAck(let ack)) = a { return ack.status } }
    return nil
}

@Suite struct ApprovalReplacementTests {
    @Test func aRequestWithoutAnOpenWindowReplacesNothing() throws {
        var m = makeMachine()
        let actions = connect(&m, A, dev: 1, now: 0)
        let request = try #require(requests(actions).first)
        #expect(request.replaced == .none)
        #expect(pendingLog(actions) == "replaced=none")
    }

    @Test func anotherDeviceReplacingAnOrphanIsFlaggedButNotBlocked() throws {
        var m = makeMachine()
        _ = connect(&m, A, dev: 1, now: 0)
        _ = m.connectionClosed(A)  // tablet left (e.g. switched to Parsec): window stays open
        #expect(m.orphanDeviceForTesting == device(1))

        let actions = connect(&m, B, dev: 2, now: 30 * sec)
        #expect(ackStatus(actions) == .pendingApproval)  // not BUSY, not delayed
        let request = try #require(requests(actions).first)
        #expect(request.id == B && request.deviceID == device(2))
        #expect(request.replaced == .otherDevice)
        #expect(request.deviceID.shortHex == "02020202")  // the fingerprint the panel shows
        // The orphan's window is closed first, then the new request is shown.
        let cancel = try #require(index(actions) { if case .cancelApproval(A) = $0 { true } else { false } })
        let ask = try #require(index(actions) { if case .requestApproval = $0 { true } else { false } })
        #expect(cancel < ask)
        #expect(pendingLog(actions) == "replaced=other")
        #expect(m.orphanDeviceForTesting == nil)
        #expect(m.status == .pending(deviceName: "Pad"))
    }

    @Test func theSameDeviceComingBackIsFlaggedAsSameAndNotBlocked() throws {
        var m = makeMachine()
        _ = connect(&m, A, dev: 1, now: 0)
        _ = m.connectionClosed(A)

        let actions = connect(&m, B, dev: 1, now: 30 * sec)
        #expect(ackStatus(actions) == .pendingApproval)
        let request = try #require(requests(actions).first)
        #expect(request.id == B && request.deviceID == device(1))
        #expect(request.replaced == .sameDevice)
        #expect(actions.contains { if case .cancelApproval(A) = $0 { true } else { false } })
        #expect(pendingLog(actions) == "replaced=same")
    }

    @Test func anExpiredOrphanNoLongerCountsAsReplaced() throws {
        var m = makeMachine()
        _ = connect(&m, A, dev: 1, now: 0)
        _ = m.connectionClosed(A)
        _ = m.tick(now: 120 * sec)  // orphan window over
        let actions = connect(&m, B, dev: 2, now: 121 * sec)
        #expect(try #require(requests(actions).first).replaced == .none)
    }

    @Test func aDecidedOrphanNoLongerCountsAsReplaced() throws {
        var m = makeMachine()
        _ = connect(&m, A, dev: 1, now: 0)
        _ = m.connectionClosed(A)
        _ = m.approvalDecided(A, approved: false, now: 10 * sec)
        let actions = connect(&m, B, dev: 2, now: 20 * sec)
        #expect(try #require(requests(actions).first).replaced == .none)
    }

    @Test func noLogLineCarriesTheDeviceNameOrTheCode() throws {
        var m = makeMachine()
        var all = connect(&m, A, dev: 1, name: "SecretTabletName", now: 0)
        all += m.connectionClosed(A)
        let second = connect(&m, B, dev: 2, name: "OtherSecretName", now: 30 * sec)
        all += second
        let codes = requests(all).map(\.code.digits)
        #expect(codes.count == 2)
        for a in all {
            guard case .log(_, _, _, let fields) = a else { continue }
            #expect(!fields.contains("SecretTabletName") && !fields.contains("OtherSecretName"))
            for code in codes { #expect(!fields.contains(code)) }
            #expect(!fields.contains("02020202") && !fields.contains("01010101"))
        }
    }

    @Test func logValuesAreStable() {
        #expect(ApprovalReplacement.none.logValue == "none")
        #expect(ApprovalReplacement.sameDevice.logValue == "same")
        #expect(ApprovalReplacement.otherDevice.logValue == "other")
    }
}
