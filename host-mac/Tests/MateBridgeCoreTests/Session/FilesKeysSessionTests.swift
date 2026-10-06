import Foundation
import Testing
@testable import MateBridgeCore

// Decision 0035: the file listener asks the session machine for the keys of one file connection (the narrow query
// of T-267). Only the live ACCEPTED session has a `prk`; once the session ends nothing can be derived.

private let A = ConnectionID(1)
private let B = ConnectionID(2)
private let pairKey = SecretBytes([UInt8](repeating: 0x5a, count: 32))
private let config = StreamConfig(configID: 1, codec: .h264, widthPx: 2800, heightPx: 1840, widthPt: 1400,
                                  heightPt: 920, fps: 60, bitrateKbps: 40000, colorPrimaries: 1, transfer: 1,
                                  matrix: 1, fullRange: true)
private let clientNonce = [UInt8](repeating: 0x11, count: 16)
private let hostNonce = [UInt8](repeating: 0x22, count: 16)

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }

private func makeMachine() -> SessionMachine {
    let keys = InMemoryPairKeyStore(keys: [device(1): pairKey])
    var m = SessionMachine(configuration: .init(hostName: "Mac", makeStreamConfig: { _ in config },
                                                makeSessionID: { 77 }, pairKeys: keys), approvedDevices: [device(1)])
    m.videoPort = 5555
    return m
}

private func activate(_ m: inout SessionMachine, _ id: ConnectionID) {
    _ = m.connectionOpened(id, now: 0)
    _ = m.received(id, .hello(TestClient(device: 1).hello), now: 0)
    _ = m.received(id, .ping(Ping(seq: 0, senderTimeUs: 0)), now: 0)
}

@Suite struct FilesKeysSessionTests {
    @Test func theActiveSessionDerivesTheFileKeysOfItsPrk() throws {
        var m = makeMachine()
        #expect(m.activeSessionID == nil)
        activate(&m, A)
        #expect(m.activeSessionID == 77)
        let keys = try #require(m.filesKeys(sessionID: 77, clientNonce: clientNonce, hostNonce: hostNonce))
        let expected = try #require(m.scheduleForTesting(A)?.filesKeys(clientNonce: clientNonce, hostNonce: hostNonce))
        #expect(keys == expected)
        // Another connection gets other keys: the nonces are part of the derivation.
        let other = try #require(m.filesKeys(sessionID: 77, clientNonce: hostNonce, hostNonce: clientNonce))
        #expect(other != keys)
    }

    @Test func onlyTheCurrentSessionIdHasKeys() {
        var m = makeMachine()
        activate(&m, A)
        #expect(m.filesKeys(sessionID: 76, clientNonce: clientNonce, hostNonce: hostNonce) == nil)
        #expect(m.filesKeys(sessionID: 0, clientNonce: clientNonce, hostNonce: hostNonce) == nil)
        #expect(m.filesKeys(sessionID: 77, clientNonce: [1], hostNonce: hostNonce) == nil)
    }

    @Test func noKeysBeforeTheSessionIsActive() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, .hello(TestClient(device: 1).hello), now: 0)  // PAIRED, still proving
        #expect(m.activeSessionID == nil)
        #expect(m.filesKeys(sessionID: 77, clientNonce: clientNonce, hostNonce: hostNonce) == nil)
    }

    @Test(arguments: ["closed", "bye", "silence", "sleep", "shutdown"])
    func noKeysOnceTheSessionEnded(how: String) {
        var m = makeMachine()
        activate(&m, A)
        #expect(m.filesKeys(sessionID: 77, clientNonce: clientNonce, hostNonce: hostNonce) != nil)
        switch how {
        case "closed": _ = m.connectionClosed(A)
        case "bye": _ = m.received(A, .bye(.normal), now: 1)
        case "silence": _ = m.tick(now: 5_000_000)
        case "sleep": _ = m.hostSleep()
        default: _ = m.shutdown()
        }
        #expect(m.activeSessionID == nil)
        #expect(m.filesKeys(sessionID: 77, clientNonce: clientNonce, hostNonce: hostNonce) == nil)
    }

    @Test func aTakeoverEndsTheOldSessionsKeys() {
        var m = makeMachine()
        activate(&m, A)
        _ = m.connectionOpened(B, now: 10)
        _ = m.received(B, .hello(TestClient(device: 1).hello), now: 10)
        // B only proves itself with its first authenticated record; until then A is the live session.
        #expect(m.activeSessionID == 77)
        _ = m.received(B, .ping(Ping(seq: 0, senderTimeUs: 0)), now: 11)
        #expect(m.activeSessionID == 77)  // B's (same id: the test uses a fixed session id)
        #expect(m.scheduleForTesting(A) == nil)
    }

    @Test func fileMessagesOnTheControlConnectionChangeNothing() {
        var m = makeMachine()
        activate(&m, A)
        #expect(m.received(A, .filesData(FilesData(data: [1, 2, 3])), now: 1).isEmpty)
        #expect(m.received(A, .filesNet(.open(port: 47003)), now: 1).isEmpty)
        #expect(m.received(A, .filesHello(FilesHello(sessionID: 77, clientNonce: clientNonce)), now: 1).isEmpty)
        #expect(m.received(A, .filesHelloAck(.rejected), now: 1).isEmpty)
        #expect(m.activeSessionID == 77)
    }

    @Test func filesNetCanBeSentOnTheActiveSession() {
        var m = makeMachine()
        activate(&m, A)
        #expect(m.send(sessionID: 77, .filesNet(.open(port: 47003))) == [.send(A, .filesNet(.open(port: 47003)))])
        #expect(m.send(sessionID: 1, .filesNet(.close)).isEmpty)
    }

    @Test func filesInfoStandbyIsDeliveredLikeAnyFilesInfo() {
        var m = makeMachine()
        activate(&m, A)
        #expect(m.received(A, .filesInfo(.standby), now: 1) == [.deliver(A, .filesInfo(.standby))])
    }
}
