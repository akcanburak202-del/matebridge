import Foundation
import Testing
@testable import MateBridgeCore

// T-152: every PAIRED connection, not only a takeover, starts its session on its first authenticated record. Before
// that the host sends nothing after HELLO_ACK (no STREAM_CONFIG) and emits no `sessionStarted`, so a peer that only
// knows an approved `device_id` (sent in the clear) cannot make the Mac build a display or hold display sleep.

private let sec: UInt64 = 1_000_000
private let A = ConnectionID(1)
private let B = ConnectionID(2)

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }

private let pairKey = SecretBytes([UInt8](repeating: 0x5a, count: 32))

private let config = StreamConfig(configID: 1, codec: .h264, widthPx: 2800, heightPx: 1840, widthPt: 1400,
                                  heightPt: 920, fps: 60, bitrateKbps: 40000, colorPrimaries: 1, transfer: 1,
                                  matrix: 1, fullRange: true)

private func makeMachine(approved: Set<DeviceID>) -> SessionMachine {
    let keys = InMemoryPairKeyStore(keys: Dictionary(uniqueKeysWithValues: approved.map { ($0, pairKey) }))
    var m = SessionMachine(configuration: .init(hostName: "Mac", makeStreamConfig: { _ in config },
                                                makeSessionID: { 77 }, pairKeys: keys), approvedDevices: approved)
    m.videoPort = 5555
    return m
}

private func hello(_ dev: UInt8) -> Message { .hello(TestClient(device: dev).hello) }
private func ping(_ seq: UInt32) -> Message { .ping(Ping(seq: seq, senderTimeUs: UInt64(seq) * 10)) }

private func isStarted(_ a: SessionAction) -> Bool { if case .sessionStarted = a { true } else { false } }
private func isStreamConfig(_ a: SessionAction) -> Bool {
    if case .send(_, .streamConfig) = a { true } else { false }
}
/// Everything that makes the host touch the display, the sleep gate or input.
private func isSessionSideEffect(_ a: SessionAction) -> Bool {
    switch a {
    case .sessionStarted, .sessionEnded, .videoAttached, .releaseInput, .deliver: true
    default: isStreamConfig(a)
    }
}

private func ackStatuses(_ actions: [SessionAction], to id: ConnectionID) -> [HelloStatus] {
    actions.compactMap { if case .send(id, .helloAck(let a)) = $0 { a.status } else { nil } }
}

/// The parts of `SessionServer` that move bytes for one control connection, with real records on the wire.
private struct Wire {
    var machine: SessionMachine
    let id: ConnectionID
    var inbound = ControlInbound()
    var sealer: RecordSealer?
    var wire: [UInt8] = []
    var actions: [SessionAction] = []
    var closed = false

    init(machine: SessionMachine, id: ConnectionID = A) {
        self.machine = machine
        self.id = id
        apply(self.machine.connectionOpened(id, now: 0))
    }

    mutating func apply(_ new: [SessionAction]) {
        actions += new
        for action in new {
            switch action {
            case .send(id, let message):
                wire += sealer != nil ? try! message.sealed(using: &sealer!) : try! message.encode()
            case .startEncryption(id, let keys):
                sealer = RecordSealer(key: keys.h2c, maxPayload: ProtocolConstants.maxControlPayload)
                try! inbound.enableEncryption(key: keys.c2h)
            case .close(id):
                closed = true
            default: break
            }
        }
    }

    mutating func receive(_ bytes: [UInt8], now: UInt64) {
        inbound.append(bytes)
        do {
            while let m = try inbound.nextMessage() { apply(machine.received(id, m, now: now)) }
        } catch is CryptoError {
            apply(machine.recordAuthFailed(id, counter: inbound.recordCounter))
        } catch {
            apply(machine.protocolError(id))
        }
    }

    /// The plain first HELLO_ACK at the head of the wire; removes it.
    mutating func takeFirstAck() throws -> HelloAck {
        var decoder = FrameDecoder(connection: .control)
        decoder.append(Array(wire.prefix(FrameDecoder.maxReadChunk)))
        guard case .helloAck(let ack)? = try decoder.nextMessage() else { throw ProtocolError.invalidField("no ack") }
        let consumed = ProtocolConstants.headerSize + (1...4).reduce(0) { $0 | Int(wire[$1]) << (8 * ($1 - 1)) }
        wire.removeFirst(consumed)
        return ack
    }
}

@Suite struct PairedProofFirstTests {
    @Test func withoutARecordNothingStartsAndTheConnectionClosesAtTheProofDeadline() {
        var m = makeMachine(approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        let hello = m.received(A, hello(1), now: 1 * sec)
        #expect(ackStatuses(hello, to: A) == [.accepted])
        #expect(!hello.contains(where: isSessionSideEffect))
        #expect(hello.contains(.log(.info, ev: "paired_proving", conn: A, fields: "")))
        #expect(!hello.contains { if case .log(_, "takeover_proving", _, _) = $0 { true } else { false } })
        #expect(m.status == .idle)
        #expect(m.send(sessionID: 77, .settingsOpen(SettingsOpen())).isEmpty)  // no session to send on

        // The heartbeat rules do not apply yet; only the proof deadline (5 s after HELLO) does.
        #expect(m.tick(now: 1 * sec + m.configuration.proofTimeoutUs - 1).isEmpty)
        let timeout = m.tick(now: 1 * sec + m.configuration.proofTimeoutUs)
        #expect(timeout == [.close(A), .log(.warning, ev: "proof_timeout", conn: A, fields: "")])
        #expect(m.scheduleForTesting(A) == nil)  // the session keys are wiped
        #expect(m.awaitingHelloCount == 0)
        // A record arriving after the deadline finds nothing.
        #expect(m.received(A, ping(1), now: 7 * sec).isEmpty)
        #expect(m.status == .idle)
    }

    @Test func aValidSealedPingStartsTheSessionSendsStreamConfigThenAnswersThePing() throws {
        var w = Wire(machine: makeMachine(approved: [device(1)]))
        var client = TestClient(device: 1)
        w.receive(try client.message.encode(), now: 0)
        let ack = try w.takeFirstAck()
        #expect(ack.status == .accepted && ack.keyMode == .paired)
        #expect(w.wire.isEmpty)  // nothing after the first ack until the proof
        #expect(!w.actions.contains(where: isSessionSideEffect))
        try client.receiveFirstAck(ack, pairKey: pairKey)

        let before = w.actions.count
        w.receive(try client.seal(ping(3)), now: 2 * sec)
        let proof = Array(w.actions[before...])
        let idxConfig = try #require(proof.firstIndex(of: .send(A, .streamConfig(config))))
        let idxStarted = try #require(proof.firstIndex(where: isStarted))
        let idxPong = try #require(proof.firstIndex(of: .send(A, .pong(Pong(seq: 3, echoTimeUs: 30,
                                                                             responderTimeUs: 2 * sec)))))
        // `start()` queues STREAM_CONFIG and emits `sessionStarted` together (same order as a takeover and as an
        // accepted pairing); the answer to the proving record always comes after both.
        #expect(idxConfig < idxStarted && idxStarted < idxPong)
        guard case .sessionStarted(A, 77, 1, let h) = proof[idxStarted] else { Issue.record("no start"); return }
        #expect(h.deviceID == device(1))
        #expect(proof.contains(.log(.info, ev: "session_started", conn: A, fields: "config_id=1 video_port=5555")))
        // The client reads STREAM_CONFIG, then the PONG, sealed.
        #expect(try client.open(w.wire) == [.streamConfig(config), .pong(Pong(seq: 3, echoTimeUs: 30,
                                                                             responderTimeUs: 2 * sec))])
        #expect(w.machine.status == .active(deviceName: "Pad", sessionID: 77))
        #expect(w.machine.awaitingHelloCount == 0)
        // The heartbeat baseline is the proof, not the HELLO.
        #expect(w.machine.tick(now: 2 * sec + w.machine.configuration.releaseSilenceUs - 1).isEmpty)
    }

    @Test func aRecordThatFailsAuthenticationClosesWithoutStartingAnything() throws {
        var w = Wire(machine: makeMachine(approved: [device(1)]))
        var client = TestClient(device: 1)
        w.receive(try client.message.encode(), now: 0)
        try client.receiveFirstAck(try w.takeFirstAck(), pairKey: pairKey)
        var record = try client.seal(ping(1))
        record[record.count - 1] ^= 1
        w.receive(record, now: 1 * sec)
        #expect(w.closed)
        #expect(w.actions.contains(.close(A)))
        #expect(!w.actions.contains(where: isSessionSideEffect))
        #expect(!w.actions.contains { if case .send(_, .bye) = $0 { true } else { false } })  // untrusted: no BYE
        #expect(w.actions.contains(.log(.info, ev: "record_auth_failed", conn: A, fields: "counter=0")))
        #expect(w.wire.isEmpty)
        #expect(w.machine.status == .idle && w.machine.awaitingHelloCount == 0)
    }

    @Test func aRecordUnderAnotherPairKeyIsRejectedTheSameWay() throws {
        // The attacker knows `device_id` but not the pair key: its keys differ, its first record cannot open.
        var w = Wire(machine: makeMachine(approved: [device(1)]))
        var client = TestClient(device: 1)
        w.receive(try client.message.encode(), now: 0)
        try client.receiveFirstAck(try w.takeFirstAck(), pairKey: SecretBytes([UInt8](repeating: 0x11, count: 32)))
        w.receive(try client.seal(ping(1)), now: 1 * sec)
        #expect(w.closed)
        #expect(!w.actions.contains(where: isSessionSideEffect))
        #expect(w.machine.status == .idle)
    }

    @Test func provingConnectionsCountTowardTheUnauthenticatedBound() {
        // `SessionServer.maxUnauthenticated` (4) refuses new connections while `awaitingHelloCount` is at it.
        let maxUnauthenticated = 4
        let devices: [UInt8] = [1, 2, 3, 4]
        var m = makeMachine(approved: Set(devices.map(device)))
        for (i, dev) in devices.enumerated() {
            let id = ConnectionID(UInt64(10 + i))
            _ = m.connectionOpened(id, now: 0)
            let actions = m.received(id, hello(dev), now: 0)
            #expect(ackStatuses(actions, to: id) == [.accepted])
            #expect(!actions.contains(where: isSessionSideEffect))
        }
        #expect(m.awaitingHelloCount == maxUnauthenticated)  // a fifth connection would be refused
        #expect(m.status == .idle)
        // The first proof activates that connection; it leaves the unauthenticated count.
        let proof = m.received(ConnectionID(10), ping(1), now: 1)
        #expect(proof.contains(where: isStarted))
        #expect(m.awaitingHelloCount == maxUnauthenticated - 1)
        // Another device proving later finds the slot taken: BUSY, nothing started.
        let late = m.received(ConnectionID(11), ping(1), now: 2)
        #expect(ackStatuses(late, to: ConnectionID(11)) == [.busy])
        #expect(late.contains(.close(ConnectionID(11))))
        #expect(!late.contains(where: isSessionSideEffect))
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
        // The rest time out at the proof deadline, the live session is untouched.
        let timeout = m.tick(now: m.configuration.proofTimeoutUs)
        #expect(timeout.contains(.close(ConnectionID(12))) && timeout.contains(.close(ConnectionID(13))))
        #expect(!timeout.contains(.close(ConnectionID(10))))
        #expect(m.awaitingHelloCount == 0)
    }

    @Test func aPairingHelloFromAnotherDeviceDuringTheProofTakesTheSlotAndTheProverGetsBusy() {
        // Known window (card T-152): `.proving` is not a slot owner, so a PAIRING request of device 2 that arrives
        // during device 1's ~1 RTT proof becomes pending, and device 1 is answered BUSY at its proof.
        var m = makeMachine(approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(1), now: 0)
        _ = m.connectionOpened(B, now: 1)
        let pairing = m.received(B, hello(2), now: 1)
        #expect(ackStatuses(pairing, to: B) == [.pendingApproval])
        #expect(pairing.contains { if case .requestApproval(B, device(2), _, _) = $0 { true } else { false } })
        #expect(m.status == .pending(deviceName: "Pad"))

        let proof = m.received(A, ping(1), now: 2)
        #expect(ackStatuses(proof, to: A) == [.busy])
        #expect(proof.contains(.close(A)))
        #expect(!proof.contains(where: isSessionSideEffect))
        #expect(!proof.contains(.cancelApproval(B)))
        #expect(m.isPendingApproval(B))
        #expect(m.scheduleForTesting(A) == nil)
        #expect(m.awaitingHelloCount == 0)
    }

    @Test func aProvingConnectionThatGoesAwayLeavesNothingBehind() {
        var m = makeMachine(approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(1), now: 0)
        let schedule = m.scheduleForTesting(A)
        let closed = m.connectionClosed(A)
        #expect(!closed.contains(where: isSessionSideEffect))
        #expect(schedule?.prkBytes == nil)
        #expect(m.awaitingHelloCount == 0 && m.status == .idle)
    }

    @Test func twoUnprovenConnectionsOfTheSameDeviceTheLaterProofSupersedesTheEarlier() {
        // E.g. a client retry: the first to prove starts the session; the second proof is a regular takeover.
        var m = makeMachine(approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(1), now: 0)
        _ = m.connectionOpened(B, now: 1)
        let second = m.received(B, hello(1), now: 1)
        #expect(second.contains(.log(.info, ev: "paired_proving", conn: B, fields: "")))  // no slot owner yet
        #expect(m.awaitingHelloCount == 2)
        #expect(m.received(A, ping(1), now: 2).contains(where: isStarted))
        let takeover = m.received(B, ping(1), now: 3)
        #expect(takeover.contains(.releaseInput(A, .superseded)) && takeover.contains(.send(A, .bye(.superseded))))
        #expect(takeover.contains { if case .sessionStarted(B, _, _, _) = $0 { true } else { false } })
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
    }

    @Test func aPairedHelloDuringALiveSessionStillLogsTakeoverProving() {
        var m = makeMachine(approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(1), now: 0)
        _ = m.received(A, ping(1), now: 0)
        _ = m.connectionOpened(B, now: 1)
        let takeover = m.received(B, hello(1), now: 1)
        #expect(takeover.contains(.log(.info, ev: "takeover_proving", conn: B, fields: "")))
        #expect(!takeover.contains { if case .log(_, "paired_proving", _, _) = $0 { true } else { false } })
    }
}
