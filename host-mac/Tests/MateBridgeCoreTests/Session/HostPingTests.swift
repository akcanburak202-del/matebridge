import Foundation
import Testing
@testable import MateBridgeCore

// T-171: the host PINGs the ACCEPTED and activated control connection every 500 ms; a PONG that answers one of those
// PINGs becomes a `.deliver` for the input-age clock offset, anything else is ignored.

private let ms: UInt64 = 1_000
private let sec: UInt64 = 1_000_000
private let tickStep: UInt64.Stride = 100_000  // the session tick, 100 ms
private let A = ConnectionID(1)
private let B = ConnectionID(2)

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }
private let pairKey = SecretBytes([UInt8](repeating: 0x5a, count: 32))
private let config = StreamConfig(configID: 1, codec: .h264, widthPx: 2800, heightPx: 1840, widthPt: 1400,
                                  heightPt: 920, fps: 60, bitrateKbps: 40000, colorPrimaries: 1, transfer: 1,
                                  matrix: 1, fullRange: true)

private func hello(_ dev: UInt8 = 1) -> Message { .hello(TestClient(device: dev).hello) }

/// `inlineKeys: false` makes pair-key lookups asynchronous (`.lookingUp`), as in the app.
private func makeMachine(approved: Set<DeviceID> = [], inlineKeys: Bool = true,
                         interval: UInt64? = SessionMachine.Configuration.defaultHostPingIntervalUs) -> SessionMachine {
    let keys = InMemoryPairKeyStore(keys: Dictionary(uniqueKeysWithValues: approved.map { ($0, pairKey) }))
    var c = SessionMachine.Configuration(hostName: "Mac", makeStreamConfig: { _ in config }, makeSessionID: { 77 },
                                         pairKeys: inlineKeys ? keys : nil)
    c.hostPingIntervalUs = interval
    return SessionMachine(configuration: c, approvedDevices: approved)
}

private func pings(_ actions: [SessionAction], to id: ConnectionID? = nil) -> [Ping] {
    actions.compactMap {
        if case .send(let c, .ping(let p)) = $0, id == nil || c == id { p } else { nil }
    }
}

private func delivered(_ actions: [SessionAction]) -> [Message] {
    actions.compactMap { if case .deliver(_, let m) = $0 { m } else { nil } }
}

/// HELLO (PAIRED) at `now`, then the first authenticated record that activates the session (T-152).
private func activate(_ m: inout SessionMachine, _ id: ConnectionID, now: UInt64 = 0) {
    _ = m.connectionOpened(id, now: now)
    _ = m.received(id, hello(), now: now)
    _ = m.received(id, .ping(Ping(seq: 0, senderTimeUs: 0)), now: now)
}

/// The client's answer to a host PING, `delay` later on the client's clock.
private func answer(_ p: Ping, clientNow: UInt64 = 42) -> Message {
    .pong(Pong(seq: p.seq, echoTimeUs: p.senderTimeUs, responderTimeUs: clientNow))
}

@Suite struct HostPingTests {
    @Test("PING-1 every 500 ms on the active connection, first one with the first tick, seq counts up")
    func pingCadence() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A, now: 0)
        var sent: [(UInt64, Ping)] = []
        var now: UInt64 = 0
        while now <= 2 * sec {
            // The client keeps talking, so silence never interferes.
            _ = m.received(A, .ping(Ping(seq: 9, senderTimeUs: 0)), now: now)
            for p in pings(m.tick(now: now), to: A) { sent.append((now, p)) }
            now += 100 * ms
        }
        #expect(sent.map(\.0) == [0, 500 * ms, 1 * sec, 1_500 * ms, 2 * sec])
        #expect(sent.map(\.1.seq) == [1, 2, 3, 4, 5])
        #expect(sent.allSatisfy { $0.0 == $0.1.senderTimeUs })  // sender time is the host clock at the send
    }

    @Test("PING-2 a late tick sends one PING, never a burst, and the next is a whole interval later")
    func lateTickNoBurst() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A, now: 0)
        #expect(pings(m.tick(now: 0)).count == 1)
        _ = m.received(A, .ping(Ping(seq: 9, senderTimeUs: 0)), now: 1_400 * ms)
        #expect(pings(m.tick(now: 1_400 * ms)).count == 1)  // 1.4 s late: still one
        #expect(pings(m.tick(now: 1_800 * ms)).isEmpty)
        #expect(pings(m.tick(now: 1_900 * ms)).count == 1)
    }

    @Test("PING-3 off when the interval is nil (the Core default): tick output is unchanged")
    func offByDefault() {
        #expect(SessionMachine.Configuration(hostName: "Mac", makeStreamConfig: { _ in config })
            .hostPingIntervalUs == nil)
        var m = makeMachine(approved: [device(1)], interval: nil)
        activate(&m, A, now: 0)
        #expect(m.tick(now: 0).isEmpty && m.tick(now: 600 * ms).isEmpty)
    }

    @Test("PING-4 never while awaiting HELLO, looking up the pair key, or proving (before the proof)")
    func noPingBeforeActivation() {
        var m = makeMachine(approved: [device(1)])
        _ = m.connectionOpened(A, now: 0)
        for t in stride(from: 0, to: 4 * sec, by: tickStep) { #expect(pings(m.tick(now: t)).isEmpty) }
        _ = m.received(A, hello(), now: 4 * sec)  // PAIRED: ACCEPTED is sent, the connection is proving
        for t in stride(from: 4 * sec, to: 8 * sec, by: tickStep) { #expect(pings(m.tick(now: t)).isEmpty) }
        _ = m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 8 * sec)  // the proof activates it
        #expect(pings(m.tick(now: 8 * sec), to: A).count == 1)

        var lookup = makeMachine(approved: [device(1)], inlineKeys: false)
        _ = lookup.connectionOpened(A, now: 0)
        let h = lookup.received(A, hello(), now: 0)
        #expect(h.contains { if case .lookupPairKey = $0 { true } else { false } })
        for t in stride(from: 0, to: 4 * sec, by: tickStep) { #expect(pings(lookup.tick(now: t)).isEmpty) }
    }

    @Test("PING-5 never while pending approval; the first one follows ACCEPTED (pairing persisted)")
    func noPingWhilePending() {
        var m = makeMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, hello(), now: 0)  // PAIRING: pending
        for t in stride(from: 0, to: 3 * sec, by: tickStep) {
            _ = m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: t)
            #expect(pings(m.tick(now: t)).isEmpty)
        }
        _ = m.approvalDecided(A, approved: true, now: 3 * sec)
        #expect(pings(m.tick(now: 3 * sec)).isEmpty)  // the key is still being stored: no ACCEPTED yet
        let accepted = m.pairingPersisted(A, stored: true, now: 3_050 * ms)
        #expect(accepted.contains { if case .sessionStarted(A, _, _, _) = $0 { true } else { false } })
        #expect(pings(m.tick(now: 3_100 * ms), to: A).count == 1)
    }

    @Test("PING-6 a takeover candidate is never PINGed while proving; the old session keeps its PINGs")
    func takeoverCandidateNotPinged() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A, now: 0)
        _ = m.connectionOpened(B, now: 1 * sec)
        _ = m.received(B, hello(), now: 1 * sec)
        var toA = 0
        for t in stride(from: 1 * sec, to: 3 * sec, by: tickStep) {
            _ = m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: t)
            let tick = m.tick(now: t)
            #expect(pings(tick, to: B).isEmpty)
            toA += pings(tick, to: A).count
        }
        #expect(toA == 4)
    }

    @Test("PING-7 PINGs go on during a heartbeat-silence release; none once the heartbeat timeout ended the session")
    func silence() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A, now: 0)
        let released = m.tick(now: 1_500 * ms)
        #expect(released.contains(.releaseInput(A, .silence)) && pings(released, to: A).count == 1)
        let closed = m.tick(now: 5 * sec)
        #expect(closed.contains(.close(A)) && pings(closed).isEmpty)
        #expect(pings(m.tick(now: 6 * sec)).isEmpty)
    }

    @Test("PONG-1 an answer to an outstanding host PING is delivered once; unknown seq or wrong echo is ignored")
    func pongMatching() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A, now: 0)
        let p1 = pings(m.tick(now: 0))[0]
        #expect(m.received(A, .pong(Pong(seq: p1.seq + 7, echoTimeUs: p1.senderTimeUs, responderTimeUs: 1)),
                           now: 1 * ms).isEmpty)
        #expect(m.received(A, .pong(Pong(seq: p1.seq, echoTimeUs: p1.senderTimeUs + 1, responderTimeUs: 1)),
                           now: 1 * ms).isEmpty)  // bogus echo
        let ok = m.received(A, answer(p1), now: 2 * ms)
        #expect(ok == [.deliver(A, answer(p1))])
        #expect(m.received(A, answer(p1), now: 3 * ms).isEmpty)  // already answered
    }

    @Test("PONG-2 PONGs arrive in order: answering a PING forgets the older ones; at most 4 stay outstanding")
    func outstandingBounded() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A, now: 0)
        var sent: [Ping] = []
        for i in 0..<6 {
            let t = UInt64(i) * 500 * ms
            _ = m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: t)
            sent += pings(m.tick(now: t))
        }
        #expect(sent.count == 6)
        #expect(m.received(A, answer(sent[0]), now: 3 * sec).isEmpty)  // forgotten: only the last 4 are kept
        #expect(m.received(A, answer(sent[1]), now: 3 * sec).isEmpty)
        #expect(delivered(m.received(A, answer(sent[3]), now: 3 * sec)) == [answer(sent[3])])
        #expect(m.received(A, answer(sent[2]), now: 3 * sec).isEmpty)  // older than an answered one
        #expect(delivered(m.received(A, answer(sent[5]), now: 3 * sec)) == [answer(sent[5])])
    }

    @Test("PONG-3 a PONG from another connection is ignored, even with a matching seq and echo")
    func pongFromAnotherConnection() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A, now: 0)
        let p = pings(m.tick(now: 0))[0]
        // A pending connection never gets a PONG through (on its own machine: here the live session makes it BUSY).
        var pend = makeMachine(approved: [device(1)])
        _ = pend.connectionOpened(B, now: 0)
        _ = pend.received(B, hello(2), now: 0)  // unknown device: pending approval
        #expect(pend.received(B, answer(p), now: 1 * ms).isEmpty)
        // A takeover candidate whose first record is a PONG carrying A's seq and echo: it proves and activates B, but
        // B has no outstanding PING, so nothing is delivered.
        _ = m.connectionOpened(B, now: 1 * ms)
        _ = m.received(B, hello(), now: 1 * ms)
        let proof = m.received(B, answer(p), now: 2 * ms)
        #expect(proof.contains { if case .sessionStarted(B, _, _, _) = $0 { true } else { false } })
        #expect(delivered(proof).isEmpty)
        // A is gone; its late PONG is ignored as well.
        #expect(m.received(A, answer(p), now: 3 * ms).isEmpty)
    }

    @Test("PONG-4 a PONG before any host PING is ignored")
    func pongBeforeAnyPing() {
        var m = makeMachine(approved: [device(1)])
        activate(&m, A, now: 0)
        #expect(m.received(A, .pong(Pong(seq: 1, echoTimeUs: 0, responderTimeUs: 5)), now: 1).isEmpty)
    }
}
