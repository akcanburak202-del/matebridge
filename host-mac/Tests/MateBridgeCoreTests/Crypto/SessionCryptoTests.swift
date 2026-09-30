import Foundation
import Testing
@testable import MateBridgeCore

// The handshake, pairing and key lifecycle of `SessionMachine` (PROTOCOL.md 3 and 9), driven end to end with a real
// client (`TestClient`) and a small stand-in for the parts of `SessionServer` that move bytes (`MiniServer`).

private let A = ConnectionID(1)
private let B = ConnectionID(2)
private let V = ConnectionID(100)
private let V2 = ConnectionID(101)
private let sec: UInt64 = 1_000_000

private let config = StreamConfig(configID: 1, codec: .hevc, widthPx: 2800, heightPx: 1840, widthPt: 1400,
                                  heightPt: 920, fps: 60, bitrateKbps: 40_000, colorPrimaries: 1, transfer: 13,
                                  matrix: 1, fullRange: true)
private let hostID = Array(0x30...0x3f) as [UInt8]

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }

private func makeMachine(store: InMemoryPairKeyStore, approved: Set<DeviceID> = []) -> SessionMachine {
    var m = SessionMachine(configuration: .init(hostName: "Mac", makeStreamConfig: { _ in config },
                                                makeSessionID: { 77 }, hostID: hostID, pairKeys: store),
                           approvedDevices: approved)
    m.videoPort = 5555
    return m
}

/// What `SessionServer` does with actions for the control connection: encode plain until `startEncryption`, seal
/// afterwards, and decode inbound bytes the same way. Records everything written to the wire.
private struct MiniServer {
    var machine: SessionMachine
    let store: InMemoryPairKeyStore
    var id = A
    var inbound = ControlInbound()
    var sealer: RecordSealer?
    var wire: [UInt8] = []
    var actions: [SessionAction] = []
    var closed = false
    var now: UInt64 = 0

    init(machine: SessionMachine, store: InMemoryPairKeyStore, id: ConnectionID = A) {
        self.machine = machine
        self.store = store
        self.id = id
        _ = self.machine.connectionOpened(id, now: 0)
    }

    mutating func apply(_ new: [SessionAction]) {
        actions += new
        for action in new {
            switch action {
            case .send(let target, let message) where target == id:
                if sealer != nil {
                    wire += try! message.sealed(using: &sealer!)
                } else {
                    wire += try! message.encode()
                }
            case .startEncryption(let target, let keys) where target == id:
                sealer = RecordSealer(key: keys.h2c, maxPayload: ProtocolConstants.maxControlPayload)
                try! inbound.enableEncryption(key: keys.c2h)
            case .persistPairing(let target, let dev, _, let key) where target == id:
                try! store.save(key, for: dev)
                apply(machine.pairingPersisted(id, stored: true, now: now))
            case .close(let target) where target == id:
                closed = true
            default: break
            }
        }
    }

    /// Bytes from the client, like `receiveControlBytes`. Returns false when the connection ended.
    @discardableResult
    mutating func receive(_ bytes: [UInt8]) -> Bool {
        inbound.append(bytes)
        do {
            while let m = try inbound.nextMessage() {
                apply(machine.received(id, m, now: now))
            }
        } catch is CryptoError {
            apply(machine.recordAuthFailed(id, counter: inbound.recordCounter))
            return false
        } catch {
            apply(machine.protocolError(id))
            return false
        }
        return !closed
    }

    /// Everything written since the last call.
    mutating func takeWire() -> [UInt8] {
        defer { wire = [] }
        return wire
    }
}

/// The first HELLO_ACK, decoded from the plain bytes on the wire.
private func firstAck(_ wire: inout [UInt8]) throws -> HelloAck {
    var decoder = FrameDecoder(connection: .control)
    decoder.append(Array(wire.prefix(FrameDecoder.maxReadChunk)))
    guard case .helloAck(let ack)? = try decoder.nextMessage() else { throw ProtocolError.invalidField("no ack") }
    let consumed = 5 + (1...4).reduce(0) { $0 | Int(wire[$1]) << (8 * ($1 - 1)) }
    wire.removeFirst(consumed)
    return ack
}

private let pairKey = SecretBytes([UInt8](repeating: 0x5a, count: 32))

@Suite struct HandshakeTests {
    @Test func pairedHandshakeAgreesWithTheClientAndEncryptsEverythingAfterTheFirstAck() throws {
        let store = InMemoryPairKeyStore(keys: [device(1): pairKey])
        var server = MiniServer(machine: makeMachine(store: store, approved: [device(1)]), store: store)
        var client = TestClient(device: 1)
        server.receive(try Message.hello(client.hello).encode())
        var wire = server.takeWire()
        let ack = try firstAck(&wire)  // plaintext, decodes with the plain decoder
        #expect(ack.status == .accepted && ack.keyMode == .paired && ack.sessionID == 77 && ack.videoPort == 5555)
        #expect(ack.hostID == hostID && ack.hostName == "Mac")
        #expect(ack.hostNonce.count == 16 && ack.hostEphPub.count == 65)
        try client.receiveFirstAck(ack, pairKey: pairKey)
        // The keys the host hands to its transport equal the ones the client derived on its own.
        let started = server.actions.compactMap { a -> ControlKeys? in if case .startEncryption(_, let k) = a { k } else { nil } }
        #expect(started == [client.schedule!.control])
        // STREAM_CONFIG follows in the same write burst, as an encrypted record.
        #expect(try client.open(wire) == [.streamConfig(config)])
        // Client -> host: PING sealed with c2h is answered with a sealed PONG.
        server.now = 5 * sec
        server.receive(try client.seal(.ping(Ping(seq: 9, senderTimeUs: 1234))))
        #expect(try client.open(server.takeWire()) == [.pong(Pong(seq: 9, echoTimeUs: 1234, responderTimeUs: 5 * sec))])
    }

    @Test func unauthenticatedBytesAfterTheHandshakeAreRejectedWithoutBye() throws {
        let store = InMemoryPairKeyStore(keys: [device(1): pairKey])
        var server = MiniServer(machine: makeMachine(store: store, approved: [device(1)]), store: store)
        var client = TestClient(device: 1)
        server.receive(try Message.hello(client.hello).encode())
        var wire = server.takeWire()
        try client.receiveFirstAck(try firstAck(&wire), pairKey: pairKey)
        // A record-shaped blob that was not sealed under the session key (length 17 = empty plaintext + tag).
        let ended = server.receive([17, 0, 0, 0] + [UInt8](repeating: 0x42, count: 17))
        #expect(ended == false)
        #expect(server.actions.contains(.releaseInput(A, .protocolError)))
        #expect(server.actions.contains(.close(A)))
        #expect(!server.actions.contains(.send(A, .bye(.protocolError))))  // the channel is not trusted: no BYE
        #expect(server.machine.status == .idle)
    }

    @Test func tamperedRecordClosesWithoutByeAndReleasesInput() throws {
        let store = InMemoryPairKeyStore(keys: [device(1): pairKey])
        var server = MiniServer(machine: makeMachine(store: store, approved: [device(1)]), store: store)
        var client = TestClient(device: 1)
        server.receive(try Message.hello(client.hello).encode())
        var wire = server.takeWire()
        try client.receiveFirstAck(try firstAck(&wire), pairKey: pairKey)
        var record = try client.seal(.ping(Ping(seq: 1, senderTimeUs: 1)))
        record[record.count - 1] ^= 1
        #expect(server.receive(record) == false)
        #expect(server.actions.contains(.releaseInput(A, .protocolError)))
        #expect(server.actions.contains(.close(A)))
        #expect(!server.actions.contains { if case .send(_, .bye) = $0 { true } else { false } })
        #expect(server.actions.contains(.sessionEnded(A)))
        let logged = server.actions.compactMap { a -> String? in
            if case .log(_, "record_auth_failed", _, let f) = a { f } else { nil }
        }
        #expect(logged == ["counter=0"])
    }

    @Test func pairingShowsTheSameCodeOnBothSidesAndStoresTheKeyBeforeAccepting() throws {
        let store = InMemoryPairKeyStore()
        var server = MiniServer(machine: makeMachine(store: store), store: store)
        var client = TestClient(device: 1, name: "Tab")
        server.receive(try Message.hello(client.hello).encode())
        var wire = server.takeWire()
        let ack = try firstAck(&wire)
        #expect(ack.status == .pendingApproval && ack.keyMode == .pairing && ack.hostID == hostID)
        #expect(ack.sessionID == 0 && ack.videoPort == 0)
        try client.receiveFirstAck(ack, pairKey: nil)
        #expect(wire.isEmpty)  // nothing else until the user decides
        // The approval window gets the same code the tablet computed.
        let shown = server.actions.compactMap { a -> PairingCode? in
            if case .requestApproval(_, _, _, let c) = a { c } else { nil }
        }
        #expect(shown.count == 1 && shown[0].digits == client.schedule!.pairingCode!.digits)
        #expect(shown[0].digits.count == 6 && shown[0].digits.allSatisfy(\.isNumber))
        #expect(store.count == 0)

        // Accept: the key is stored first, then ACCEPTED goes out (encrypted, key_mode NONE) plus STREAM_CONFIG.
        let persistedAt = server.actions.count
        server.now = 3 * sec
        server.apply(server.machine.approvalDecided(A, approved: true, now: 3 * sec))
        #expect(store.key(for: device(1)) == client.schedule!.newPairKey)
        let after = Array(server.actions[persistedAt...])
        let persistIndex = try #require(after.firstIndex { if case .persistPairing = $0 { true } else { false } })
        let ackIndex = try #require(after.firstIndex { if case .send(_, .helloAck) = $0 { true } else { false } })
        #expect(persistIndex < ackIndex)
        let opened = try client.open(server.takeWire())
        guard case .helloAck(let second) = opened[0] else { Issue.record("no second ack"); return }
        #expect(second.status == .accepted && second.keyMode == .none && second.sessionID == 77)
        #expect(second.hostID == [UInt8](repeating: 0, count: 16) && second.hostEphPub == [UInt8](repeating: 0, count: 65))
        #expect(opened[1] == .streamConfig(config))
        #expect(server.machine.status == .active(deviceName: "Tab", sessionID: 77))
        #expect(server.actions.contains(.sessionStarted(A, sessionID: 77, configID: 1, deviceName: "Tab")))
    }

    @Test func secondConnectionAfterPairingIsPairedWithTheStoredKey() throws {
        let store = InMemoryPairKeyStore()
        var first = MiniServer(machine: makeMachine(store: store), store: store)
        var tablet = TestClient(device: 1)
        first.receive(try Message.hello(tablet.hello).encode())
        var wire = first.takeWire()
        try tablet.receiveFirstAck(try firstAck(&wire), pairKey: nil)
        first.apply(first.machine.approvalDecided(A, approved: true, now: 1))
        let stored = try #require(tablet.schedule?.newPairKey)

        // Same machine, new connection: the device is approved and has a key.
        _ = first.machine.connectionClosed(A)
        var second = MiniServer(machine: first.machine, store: store, id: B)
        var again = TestClient(device: 1, eph: EphemeralKeyPair())
        second.receive(try Message.hello(again.hello).encode())
        var wire2 = second.takeWire()
        let ack = try firstAck(&wire2)
        #expect(ack.status == .accepted && ack.keyMode == .paired)
        try again.receiveFirstAck(ack, pairKey: stored)
        #expect(try again.open(wire2) == [.streamConfig(config)])
        // The key is bound into the session: a client with another pair key derives different keys.
        var stranger = TestClient(device: 1, eph: again.eph)
        try stranger.receiveFirstAck(ack, pairKey: SecretBytes([UInt8](repeating: 9, count: 32)))
        #expect(stranger.schedule!.control != again.schedule!.control)
    }

    @Test func approvedDeviceWithoutKeyAndKeyWithoutApprovalBothFallBackToPairing() throws {
        // v0 approval record (no key): PAIRING.
        let empty = InMemoryPairKeyStore()
        var legacy = MiniServer(machine: makeMachine(store: empty, approved: [device(1)]), store: empty)
        legacy.receive(try Message.hello(TestClient(device: 1).hello).encode())
        var wire = legacy.takeWire()
        #expect(try firstAck(&wire).keyMode == .pairing)
        // A key with no approval record (device list was deleted): also PAIRING; the key is not trusted on its own.
        let orphan = InMemoryPairKeyStore(keys: [device(2): pairKey])
        var stale = MiniServer(machine: makeMachine(store: orphan), store: orphan)
        stale.receive(try Message.hello(TestClient(device: 2).hello).encode())
        var wire2 = stale.takeWire()
        #expect(try firstAck(&wire2).keyMode == .pairing)
    }

    @Test func rejectedPairingIsSealedAndStoresNothing() throws {
        let store = InMemoryPairKeyStore()
        var server = MiniServer(machine: makeMachine(store: store), store: store)
        var client = TestClient(device: 1)
        server.receive(try Message.hello(client.hello).encode())
        var wire = server.takeWire()
        try client.receiveFirstAck(try firstAck(&wire), pairKey: nil)
        server.apply(server.machine.approvalDecided(A, approved: false, now: 1))
        let opened = try client.open(server.takeWire())
        guard case .helloAck(let ack) = opened.first else { Issue.record("no ack"); return }
        #expect(ack.status == .rejected && ack.keyMode == .none)
        #expect(store.count == 0 && server.closed)
    }

    @Test func failedKeyStorageRejectsInsteadOfAccepting() throws {
        let store = InMemoryPairKeyStore()
        var m = makeMachine(store: store)
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, TestClient(device: 1).message, now: 0)
        _ = m.approvalDecided(A, approved: true, now: 1)
        let actions = m.pairingPersisted(A, stored: false, now: 1)
        #expect(actions.contains { if case .send(_, .helloAck(let a)) = $0 { a.status == .rejected } else { false } })
        #expect(!actions.contains { if case .send(_, .helloAck(let a)) = $0 { a.status == .accepted } else { false } })
        #expect(actions.contains(.close(A)))
        #expect(m.approvedDevices.isEmpty && m.status == .idle)
    }

    @Test func versionMismatchIsPlaintextWithKeyModeNoneAndNeverReadsTheRest() throws {
        let store = InMemoryPairKeyStore()
        var server = MiniServer(machine: makeMachine(store: store), store: store)
        // A v0 HELLO is short: no nonce, no key.
        var w = ByteWriter()
        w.u16(0); w.raw([UInt8](repeating: 1, count: 16)); w.u16(2800); w.u16(1840); w.u16(360); w.u16(144)
        w.u32(255); w.str8("Old Pad")
        var frame = ByteWriter()
        frame.u8(0x01); frame.u32(UInt32(w.bytes.count)); frame.raw(w.bytes)
        server.receive(frame.bytes)
        var wire = server.takeWire()
        let ack = try firstAck(&wire)
        #expect(ack.status == .versionMismatch && ack.keyMode == .none && ack.protocolVersion == 1)
        #expect(ack.hostID == [UInt8](repeating: 0, count: 16) && ack.hostNonce == [UInt8](repeating: 0, count: 16))
        #expect(ack.hostEphPub == [UInt8](repeating: 0, count: 65))
        #expect(server.closed && !server.actions.contains { if case .startEncryption = $0 { true } else { false } })
    }

    @Test func busyIsPlaintextWithKeyModeNone() throws {
        let store = InMemoryPairKeyStore(keys: [device(1): pairKey, device(2): pairKey])
        var m = makeMachine(store: store, approved: [device(1), device(2)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, TestClient(device: 1).message, now: 0)
        _ = m.connectionOpened(B, now: 1)
        let actions = m.received(B, TestClient(device: 2).message, now: 1)
        guard case .send(B, .helloAck(let ack))? = actions.first else { Issue.record("no ack"); return }
        #expect(ack.status == .busy && ack.keyMode == .none)
        #expect(!actions.contains { if case .startEncryption = $0 { true } else { false } })
    }

    @Test func invalidPublicKeyIsAProtocolErrorThatDoesNotDisturbALiveSession() throws {
        let store = InMemoryPairKeyStore(keys: [device(1): pairKey])
        var m = makeMachine(store: store, approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, TestClient(device: 1).message, now: 0)
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
        // Somebody who knows the device_id (it is sent in the clear) sends a HELLO with garbage as public key.
        var bad = TestClient(device: 1).hello
        bad.clientEphPub = [UInt8](repeating: 0, count: 65)
        _ = m.connectionOpened(B, now: 1)
        let actions = m.received(B, .hello(bad), now: 1)
        #expect(actions.contains(.send(B, .bye(.protocolError))) && actions.contains(.close(B)))
        #expect(!actions.contains(.releaseInput(A, .superseded)))
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
    }
}

@Suite struct VideoKeyTests {
    private func activeMachine() throws -> (SessionMachine, TestClient) {
        let store = InMemoryPairKeyStore(keys: [device(1): pairKey])
        var m = makeMachine(store: store, approved: [device(1)])
        var client = TestClient(device: 1)
        _ = m.connectionOpened(A, now: 0)
        let actions = m.received(A, client.message, now: 0)
        guard case .send(_, .helloAck(let ack))? = actions.first else { throw ProtocolError.invalidField("ack") }
        try client.receiveFirstAck(ack, pairKey: pairKey)
        return (m, client)
    }

    @Test func videoKeysDeriveFromThePrkAndTheNonceAndMatchTheClient() throws {
        var (m, client) = try activeMachine()
        let n1 = [UInt8](repeating: 1, count: 16), n2 = [UInt8](repeating: 2, count: 16)
        _ = m.videoOpened(V, now: 0)
        let first = m.videoHello(V, VideoHello(configID: 1, sessionID: 77, videoNonce: n1), now: 0)
        _ = m.videoOpened(V2, now: 0)
        let second = m.videoHello(V2, VideoHello(configID: 1, sessionID: 77, videoNonce: n2), now: 0)
        func keys(_ a: [SessionAction]) -> VideoKeys? {
            for case .videoAttached(_, _, _, _, let k) in a { return k }
            return nil
        }
        let k1 = try #require(keys(first)), k2 = try #require(keys(second))
        #expect(k1 == client.schedule!.videoKeys(nonce: n1))
        #expect(k2 == client.schedule!.videoKeys(nonce: n2))
        #expect(k1 != k2)
        #expect(k1.h2c != k1.c2h)
    }

    @Test func aReplayedVideoNonceIsRefusedSoAKeyAndNonceNeverEncryptTwoStreams() throws {
        var (m, _) = try activeMachine()
        let n = [UInt8](repeating: 7, count: 16)
        _ = m.videoOpened(V, now: 0)
        #expect(m.videoHello(V, VideoHello(configID: 1, sessionID: 77, videoNonce: n), now: 0).contains {
            if case .videoAttached = $0 { true } else { false }
        })
        _ = m.videoOpened(V2, now: 1)
        let replay = m.videoHello(V2, VideoHello(configID: 1, sessionID: 77, videoNonce: n), now: 1)
        #expect(replay.contains(.closeVideo(V2)))
        #expect(!replay.contains { if case .videoAttached = $0 { true } else { false } })
        // The refused replay did not displace the legitimate connection.
        #expect(!replay.contains(.closeVideo(V)))
    }

    @Test func videoAttachesAreCappedPerSession() throws {
        var (m, _) = try activeMachine()
        m.configuration.maxVideoAttaches = 3
        var attached = 0
        for i in 0..<6 {
            let vid = ConnectionID(200 + UInt64(i))
            _ = m.videoOpened(vid, now: 0)
            let actions = m.videoHello(vid, VideoHello(configID: 1, sessionID: 77,
                                                       videoNonce: [UInt8](repeating: UInt8(i), count: 16)), now: 0)
            if actions.contains(where: { if case .videoAttached = $0 { true } else { false } }) { attached += 1 }
        }
        #expect(attached == 3)
    }

    @Test func prkIsWipedWhenTheSessionEnds() throws {
        let ends: [(String, (inout SessionMachine) -> Void)] = [
            ("disconnect", { _ = $0.connectionClosed(A) }),
            ("bye", { _ = $0.received(A, .bye(.normal), now: 1) }),
            ("protocol error", { _ = $0.protocolError(A) }),
            ("auth failure", { _ = $0.recordAuthFailed(A, counter: 0) }),
            ("shutdown", { _ = $0.shutdown() }),
            ("silence timeout", { _ = $0.tick(now: 10 * sec) }),
        ]
        for (name, end) in ends {
            var (m, _) = try activeMachine()
            let schedule = try #require(m.scheduleForTesting(A), "\(name)")
            #expect(schedule.prkBytes != nil)
            end(&m)
            #expect(schedule.prkBytes == nil, "prk must be wiped on \(name)")
            #expect(schedule.secret.rawStorage.allSatisfy { $0 == 0 })
        }
    }

    @Test func prkIsWipedWhenAPendingPairingEnds() throws {
        let ends: [(String, (inout SessionMachine) -> Void)] = [
            ("reject", { _ = $0.approvalDecided(A, approved: false, now: 1) }),
            ("timeout", { _ = $0.tick(now: 61 * sec) }),
            ("disconnect", { _ = $0.connectionClosed(A) }),
        ]
        for (name, end) in ends {
            var m = makeMachine(store: InMemoryPairKeyStore())
            _ = m.connectionOpened(A, now: 0)
            _ = m.received(A, TestClient(device: 1).message, now: 0)
            let schedule = try #require(m.scheduleForTesting(A), "\(name)")
            end(&m)
            #expect(schedule.prkBytes == nil, "prk must be wiped on \(name)")
        }
    }

    @Test func takeoverWipesTheOldSessionsPrk() throws {
        var (m, _) = try activeMachine()
        let old = try #require(m.scheduleForTesting(A))
        _ = m.connectionOpened(B, now: 1)
        _ = m.received(B, TestClient(device: 1, eph: EphemeralKeyPair()).message, now: 1)
        #expect(old.prkBytes == nil)
        #expect(m.scheduleForTesting(B)?.prkBytes != nil)
    }
}

@Suite struct CryptoPrivacyTests {
    @Test func noLogActionCarriesKeyMaterialOrTheCode() throws {
        let store = InMemoryPairKeyStore()
        var server = MiniServer(machine: makeMachine(store: store), store: store)
        var client = TestClient(device: 1, name: "SecretName")
        server.receive(try Message.hello(client.hello).encode())
        var wire = server.takeWire()
        try client.receiveFirstAck(try firstAck(&wire), pairKey: nil)
        server.apply(server.machine.approvalDecided(A, approved: true, now: 1))
        _ = server.machine.videoOpened(V, now: 1)
        server.apply(server.machine.videoHello(V, VideoHello(configID: 1, sessionID: 77,
                                                             videoNonce: [UInt8](repeating: 3, count: 16)), now: 1))
        _ = server.machine.recordAuthFailed(A, counter: 4)

        let s = client.schedule!
        let secrets = [Hex.string(s.control.c2h.bytes), Hex.string(s.control.h2c.bytes), Hex.string(s.newPairKey!.bytes),
                       Hex.string(s.prkBytes ?? []), s.pairingCode!.digits, "SecretName"]
        var text = ""
        for case .log(_, let ev, _, let fields) in server.actions { text += "\(ev) \(fields)\n" }
        for secret in secrets { #expect(!text.contains(secret)) }
        #expect(text.contains("handshake mode=pairing"))
    }

    @Test func pairedHandshakeLogsModeOnly() throws {
        let store = InMemoryPairKeyStore(keys: [device(1): pairKey])
        var m = makeMachine(store: store, approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        let actions = m.received(A, TestClient(device: 1).message, now: 0)
        #expect(actions.contains(.log(.info, ev: "handshake", conn: A, fields: "mode=paired")))
    }

    @Test func actionsDoNotPrintSecrets() throws {
        let store = InMemoryPairKeyStore()
        var m = makeMachine(store: store)
        _ = m.connectionOpened(A, now: 0)
        let actions = m.received(A, TestClient(device: 1).message, now: 0)
        let client = try {
            var c = TestClient(device: 1)
            guard case .send(_, .helloAck(let ack))? = actions.first else { throw ProtocolError.invalidField("ack") }
            try c.receiveFirstAck(ack, pairKey: nil)
            return c
        }()
        let printed = "\(actions)" + String(reflecting: actions)
        #expect(!printed.contains(Hex.string(client.schedule!.control.c2h.bytes)))
        #expect(!printed.contains(client.schedule!.pairingCode!.digits))
    }
}
