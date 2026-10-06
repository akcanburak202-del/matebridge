import Testing
@testable import MateBridgeCore

// Pure state machine of the Wi-Fi file connections (decision 0035, PROTOCOL.md section 4 "Dosya bağlantısı").

private let sec: UInt64 = 1_000_000
private let peer = "192.168.1.20"
private let hostNonce = [UInt8](repeating: 0x80, count: 16)
private let clientNonce = [UInt8](repeating: 0x70, count: 16)

private func F(_ n: UInt64) -> FilesConnID { FilesConnID(n) }
private func L(_ n: UInt64) -> LocalConnID { LocalConnID(n) }

private func hello(session: UInt32 = 7, version: UInt16 = ProtocolConstants.protocolVersion) -> FilesHello {
    FilesHello(protocolVersion: version, sessionID: session, clientNonce: clientNonce)
}

private let ping: Message = .ping(Ping(seq: 1, senderTimeUs: 2))
private let data: Message = .filesData(FilesData(data: [1, 2, 3]))

private func makeMachine(max: Int = 12, pool: Int = 2) -> FilesConnectionMachine {
    var c = FilesConnectionMachine.Configuration()
    c.makeNonce = { hostNonce }
    var m = FilesConnectionMachine(configuration: c)
    _ = m.open(sessionID: 7, controlPeer: peer, max: max, pool: pool)
    return m
}

/// A connection that was accepted, said hello and proved itself: idle in the pool.
@discardableResult
private func proven(_ m: inout FilesConnectionMachine, _ id: FilesConnID, now: UInt64 = 0) -> [FilesAction] {
    var out = m.accepted(id, peer: peer, now: now)
    out += m.hello(id, hello(), now: now)
    out += m.record(id, ping, now: now)
    return out
}

private func closes(_ actions: [FilesAction]) -> [(FilesConnID, FilesCloseReason)] {
    actions.compactMap { if case .close(let id, let r) = $0 { (id, r) } else { nil } }
}

private func closedLocals(_ actions: [FilesAction]) -> [(LocalConnID, FilesCloseReason)] {
    actions.compactMap { if case .closeLocal(let id, let r) = $0 { (id, r) } else { nil } }
}

private func binds(_ actions: [FilesAction]) -> [FilesAction] {
    actions.filter { if case .bind = $0 { true } else { false } }
}

@Suite struct FilesConnectionMachineTests {
    // MARK: Accept checks

    @Test func nothingIsAcceptedBeforeOpenOrAfterClose() {
        var m = FilesConnectionMachine()
        #expect(closes(m.accepted(F(1), peer: peer, now: 0)).map(\.1) == [.notOpen])
        _ = m.open(sessionID: 7, controlPeer: peer, max: 12, pool: 2)
        #expect(m.accepted(F(2), peer: peer, now: 0).isEmpty)
        _ = m.close()
        #expect(!m.isOpen)
        #expect(closes(m.accepted(F(3), peer: peer, now: 0)).map(\.1) == [.notOpen])
        #expect(closedLocals(m.localOpened(L(1), now: 0)).map(\.1) == [.notOpen])
    }

    @Test func onlyTheControlPeerIsAccepted() {
        var m = makeMachine()
        let out = m.accepted(F(1), peer: "192.168.1.99", now: 0)
        #expect(closes(out).map(\.1) == [.peerMismatch])
        #expect(m.counts.total == 0)
        #expect(m.accepted(F(2), peer: "::ffff:192.168.1.20", now: 0).isEmpty)  // same host, mapped form
    }

    @Test func atMostTwoUnprovenConnectionsAtOnce() {
        var m = makeMachine()
        #expect(m.accepted(F(1), peer: peer, now: 0).isEmpty)
        #expect(m.accepted(F(2), peer: peer, now: 0).isEmpty)
        #expect(closes(m.accepted(F(3), peer: peer, now: 0)).map(\.1) == [.unprovenLimit])
        #expect(m.counts.unproven == 2)
        // A connection that proved itself frees a slot.
        _ = m.hello(F(1), hello(), now: 1)
        _ = m.record(F(1), ping, now: 1)
        #expect(m.counts.unproven == 1)
        #expect(m.accepted(F(4), peer: peer, now: 2).isEmpty)
    }

    // MARK: FILES_HELLO

    @Test func validHelloIsAnsweredAndStartsRecords() {
        var m = makeMachine()
        _ = m.accepted(F(1), peer: peer, now: 0)
        let out = m.hello(F(1), hello(), now: 1)
        #expect(out == [.sendAck(F(1), FilesHelloAck(status: .ok, hostNonce: hostNonce)),
                        .startRecords(F(1), clientNonce: clientNonce, hostNonce: hostNonce)])
    }

    @Test func helloIsRejectedForWrongVersionSessionOrCapacity() {
        var m = makeMachine(max: 2)
        for (n, h) in [(UInt64(1), hello(version: 2)), (2, hello(session: 8)), (3, hello(session: 0))] {
            _ = m.accepted(F(n), peer: peer, now: 0)
            let out = m.hello(F(n), h, now: 0)
            #expect(out.first == .sendAck(F(n), .rejected))
            #expect(closes(out).map(\.1) == [.rejected])
            #expect(m.counts.total == 0)
            _ = m.fileClosed(F(n))  // the transport flushed the REJECTED ack and closed
        }
    }

    @Test func totalLimitCountsEveryConnectionFromItsAccept() {
        var m = makeMachine(max: 3)
        proven(&m, F(1))
        proven(&m, F(2))
        proven(&m, F(3))
        // `max` proven: a further socket is closed at the accept, it never waits for a HELLO.
        #expect(closes(m.accepted(F(4), peer: peer, now: 0)).map(\.1) == [.capacity])
        #expect(m.counts.total == 3)
        // Awaiting-HELLO sockets count too: with 1 proven and 2 awaiting (max 3) the next accept is refused.
        var n = makeMachine(max: 3)
        proven(&n, F(1))
        #expect(n.accepted(F(2), peer: peer, now: 0).isEmpty)
        #expect(n.accepted(F(3), peer: peer, now: 0).isEmpty)
        #expect(closes(n.accepted(F(4), peer: peer, now: 0)).map(\.1) == [.capacity])
        #expect(n.counts.total == 3)
        // The ones that were admitted can still say HELLO (the others < max).
        #expect(n.hello(F(2), hello(), now: 0).contains(.startRecords(F(2), clientNonce: clientNonce, hostNonce: hostNonce)))
        // A slot freed by a close is usable again.
        _ = n.record(F(2), ping, now: 0)
        _ = n.fileClosed(F(1))
        #expect(n.accepted(F(5), peer: peer, now: 0).isEmpty)
    }

    @Test func helloIsRejectedWhenTheLimitWasLoweredBelowTheCurrentCount() {
        var m = makeMachine(max: 4)
        proven(&m, F(1))
        proven(&m, F(2))
        _ = m.accepted(F(3), peer: peer, now: 0)
        _ = m.open(sessionID: 7, controlPeer: peer, max: 2, pool: 1)  // same session: only the limits change
        let out = m.hello(F(3), hello(), now: 0)
        #expect(out.first == .sendAck(F(3), .rejected))
        #expect(closes(out).map(\.1) == [.rejected])
        #expect(m.counts.total == 2)
    }

    @Test func aLateHelloOrProofIsTooLateEvenBeforeTheTick() {
        // Accept t=0, HELLO at 4 s (fine), the proof PING is processed at 6 s before any tick ran: closed.
        var m = makeMachine()
        _ = m.accepted(F(1), peer: peer, now: 0)
        #expect(!m.hello(F(1), hello(), now: 4 * sec).isEmpty)
        let late = m.record(F(1), ping, now: 6 * sec)
        #expect(closes(late).map(\.1) == [.proofTimeout])
        #expect(m.counts.total == 0 && m.counts.idle == 0)
        // The same instant as the deadline is already too late (like the tick).
        _ = m.accepted(F(2), peer: peer, now: 0)
        _ = m.hello(F(2), hello(), now: 1)
        #expect(closes(m.record(F(2), ping, now: 5 * sec)).map(\.1) == [.proofTimeout])
        // Just before it the proof is fine.
        _ = m.accepted(F(3), peer: peer, now: 0)
        _ = m.hello(F(3), hello(), now: 1)
        _ = m.record(F(3), ping, now: 5 * sec - 1)
        #expect(m.counts.idle == 1)
        // A HELLO after the 5 s closes without an answer.
        _ = m.accepted(F(4), peer: peer, now: 10 * sec)
        let lateHello = m.hello(F(4), hello(), now: 15 * sec)
        #expect(closes(lateHello).map(\.1) == [.helloTimeout])
        #expect(!lateHello.contains { if case .sendAck = $0 { true } else { false } })
        #expect(!lateHello.contains { if case .startRecords = $0 { true } else { false } })
        // A late proof does not take a waiting local connection either.
        var w = makeMachine()
        _ = w.localOpened(L(1), now: 0)
        _ = w.accepted(F(1), peer: peer, now: 0)
        _ = w.hello(F(1), hello(), now: 1)
        #expect(binds(w.record(F(1), ping, now: 5 * sec)).isEmpty)
    }

    @Test func aClosingConnectionStillCountsTowardTheLimitUntilTheTransportConfirms() {
        var m = makeMachine(max: 2)
        proven(&m, F(1))
        proven(&m, F(2))
        // The tablet stops reading while Finder cancels: the host closes F(1) and F(2) but their flush hangs.
        _ = m.protocolError(F(1))
        _ = m.protocolError(F(2))
        #expect(m.counts.total == 0 && m.counts.closing == 2)
        #expect(closes(m.accepted(F(3), peer: peer, now: 0)).map(\.1) == [.capacity])  // no room: they are draining
        // One confirms: a slot is free again.
        #expect(m.fileClosed(F(1)).isEmpty)
        #expect(m.counts.closing == 1)
        #expect(m.accepted(F(4), peer: peer, now: 0).isEmpty)
        #expect(closes(m.accepted(F(5), peer: peer, now: 0)).map(\.1) == [.capacity])
        // A repeated report is harmless.
        #expect(m.fileClosed(F(1)).isEmpty)
        #expect(m.counts.closing == 1)
    }

    @Test func everyCloseReasonKeepsTheConnectionCountedWhileItDrains() {
        var m = makeMachine(max: 20)
        proven(&m, F(1))  // closed by the Finder side
        proven(&m, F(2))  // auth failure
        _ = m.localOpened(L(1), now: 0)
        _ = m.localClosed(L(1))
        _ = m.recordAuthFailed(F(2))
        _ = m.accepted(F(5), peer: peer, now: 0)  // key derivation failed
        _ = m.hello(F(5), hello(), now: 0)
        _ = m.keysUnavailable(F(5))
        _ = m.accepted(F(6), peer: peer, now: 0)  // rejected HELLO
        _ = m.hello(F(6), hello(session: 1), now: 0)
        #expect(m.counts.closing == 4)
        // A timer close drains too: a connection that never said HELLO.
        _ = m.accepted(F(7), peer: peer, now: 0)
        let out = m.tick(now: 5 * sec)
        // The four older ones had their 5 s of flushing (clock 0): aborted. F(7) was closed just now: draining.
        #expect(out.filter { if case .abort = $0 { true } else { false } }.count == 4)
        #expect(closes(out).map(\.0) == [F(7)])
        #expect(m.counts.closing == 1)
        #expect(m.counts.total == 0)
    }

    @Test func idleTimeoutDrainsAndIsCounted() {
        var m = makeMachine()
        proven(&m, F(1), now: 0)
        let out = m.tick(now: 30 * sec)
        #expect(closes(out).map(\.1) == [.idleTimeout])
        #expect(m.counts.closing == 1 && m.counts.total == 0)
    }

    @Test func aDrainThatDoesNotFinishIsAbortedAfterTheTimeout() {
        var m = makeMachine()
        _ = m.accepted(F(1), peer: peer, now: 100)
        _ = m.hello(F(1), hello(), now: 100)
        let out = m.protocolError(F(1))  // at the machine's clock: 100
        #expect(closes(out).map(\.1) == [.protocolError])
        #expect(m.nextDeadline == 100 + 5 * sec)
        #expect(m.tick(now: 100 + 5 * sec - 1).isEmpty)
        #expect(m.counts.closing == 1)
        let abort = m.tick(now: 100 + 5 * sec)
        #expect(abort.contains(.abort(F(1))))
        #expect(m.counts.closing == 0)  // the hard close is immediate: it no longer counts
        #expect(m.nextDeadline == nil)
        #expect(!m.tick(now: 200 * sec).contains(.abort(F(1))))  // once only
        #expect(m.fileClosed(F(1)).isEmpty)  // the late report changes nothing
    }

    @Test func aConfirmedCloseIsNeverAborted() {
        var m = makeMachine()
        proven(&m, F(1))
        _ = m.localOpened(L(1), now: 0)
        _ = m.localClosed(L(1))
        _ = m.fileClosed(F(1))
        #expect(m.tick(now: 60 * sec).isEmpty)
        #expect(m.nextDeadline == nil)
    }

    @Test func aRefusalAtTheAcceptDoesNotOccupyAClosingSlot() {
        var m = makeMachine(max: 1)
        proven(&m, F(1))
        _ = m.accepted(F(2), peer: "10.0.0.9", now: 0)  // wrong peer: nothing queued
        _ = m.accepted(F(3), peer: peer, now: 0)  // capacity
        #expect(m.counts.closing == 0)
        _ = m.fileClosed(F(1))
        #expect(m.accepted(F(4), peer: peer, now: 0).isEmpty)
    }

    @Test func rejectedAckCarriesAZeroNonce() {
        #expect(FilesHelloAck.rejected.hostNonce == [UInt8](repeating: 0, count: 16))
        #expect(FilesHelloAck.rejected.status == .rejected)
    }

    @Test func helloAfterHelloOrOnAnUnknownConnectionIsHandledStrictly() {
        var m = makeMachine()
        #expect(m.hello(F(9), hello(), now: 0).isEmpty)  // never accepted
        _ = m.accepted(F(1), peer: peer, now: 0)
        _ = m.hello(F(1), hello(), now: 0)
        #expect(closes(m.hello(F(1), hello(), now: 0)).map(\.1) == [.protocolError])
    }

    @Test func aWrongSessionIsRejectedAfterTheListenerMovedToANewSession() {
        var m = makeMachine()
        _ = m.open(sessionID: 8, controlPeer: peer, max: 12, pool: 2)
        _ = m.accepted(F(1), peer: peer, now: 0)
        #expect(m.hello(F(1), hello(session: 7), now: 0).first == .sendAck(F(1), .rejected))
        _ = m.accepted(F(2), peer: peer, now: 0)
        #expect(m.hello(F(2), hello(session: 8), now: 0).contains(.startRecords(F(2), clientNonce: clientNonce, hostNonce: hostNonce)))
    }

    // MARK: Proof

    @Test func firstRecordMustBeAPing() {
        for first in [data, Message.bye(.normal), .pong(Pong(seq: 1, echoTimeUs: 1, responderTimeUs: 1))] {
            var m = makeMachine()
            _ = m.accepted(F(1), peer: peer, now: 0)
            _ = m.hello(F(1), hello(), now: 0)
            #expect(closes(m.record(F(1), first, now: 1)).map(\.1) == [.protocolError])
            #expect(m.counts.total == 0)
        }
    }

    @Test func provenConnectionJoinsThePoolAndPingsAreNotAnswered() {
        var m = makeMachine()
        let out = proven(&m, F(1))
        #expect(!out.contains { if case .sendAck(_, let a) = $0 { !a.isOK } else { false } })
        #expect(m.counts.idle == 1 && m.counts.unproven == 0)
        #expect(m.record(F(1), ping, now: 5 * sec).isEmpty)  // keepalive: no PONG, no action
    }

    @Test func helloAndProofTogetherHaveFiveSecondsFromTheAccept() {
        var m = makeMachine()
        _ = m.accepted(F(1), peer: peer, now: 100)
        #expect(m.tick(now: 100 + 5 * sec - 1).isEmpty)
        #expect(closes(m.tick(now: 100 + 5 * sec)).map(\.1) == [.helloTimeout])
        // After HELLO the same deadline still runs: the HELLO wait is part of the five seconds.
        _ = m.accepted(F(2), peer: peer, now: 200)
        _ = m.hello(F(2), hello(), now: 200 + 4 * sec)
        #expect(m.tick(now: 200 + 5 * sec - 1).isEmpty)
        #expect(closes(m.tick(now: 200 + 5 * sec)).map(\.1) == [.proofTimeout])
        #expect(m.counts.total == 0)
    }

    @Test func aProvenConnectionIsNotKilledByTheProofTimer() {
        var m = makeMachine()
        proven(&m, F(1), now: 0)
        #expect(m.tick(now: 6 * sec).isEmpty)
        #expect(m.counts.idle == 1)
    }

    // MARK: Idle timeout and keepalive

    @Test func idleConnectionClosesAfterThirtySecondsOfSilence() {
        var m = makeMachine()
        proven(&m, F(1), now: 0)
        #expect(m.tick(now: 30 * sec - 1).isEmpty)
        #expect(closes(m.tick(now: 30 * sec)).map(\.1) == [.idleTimeout])
        #expect(m.counts.total == 0)
    }

    @Test func aKeepalivePingExtendsTheIdleTime() {
        var m = makeMachine()
        proven(&m, F(1), now: 0)
        _ = m.record(F(1), ping, now: 10 * sec)
        _ = m.record(F(1), ping, now: 20 * sec)
        #expect(m.tick(now: 49 * sec).isEmpty)
        #expect(closes(m.tick(now: 50 * sec)).map(\.1) == [.idleTimeout])
    }

    @Test func boundConnectionsHaveNoProtocolTimeout() {
        var m = makeMachine()
        proven(&m, F(1), now: 0)
        _ = m.localOpened(L(1), now: 1)
        #expect(m.tick(now: 3600 * sec).isEmpty)
        #expect(m.counts.bound == 1)
    }

    // MARK: Pool, pairing, 1:1 close

    @Test func aLocalConnectionTakesTheOldestIdleFileConnection() {
        var m = makeMachine()
        proven(&m, F(5), now: 0)
        proven(&m, F(3), now: 1)  // proven later although it has the lower id
        let out = m.localOpened(L(1), now: 2)
        #expect(binds(out) == [.bind(F(5), L(1))])
        #expect(m.local(for: F(5)) == L(1))
        #expect(binds(m.localOpened(L(2), now: 2)) == [.bind(F(3), L(2))])
        #expect(m.counts.idle == 0 && m.counts.bound == 2)
    }

    @Test func aWaitingLocalConnectionIsBoundWhenAFileConnectionProves() {
        var m = makeMachine()
        #expect(m.localOpened(L(1), now: 0).isEmpty)
        #expect(m.localOpened(L(2), now: 1).isEmpty)
        #expect(m.counts.waitingLocal == 2)
        let out = proven(&m, F(1), now: 2 * sec)
        #expect(binds(out) == [.bind(F(1), L(1))])  // the oldest waiter first
        #expect(m.counts.waitingLocal == 1)
    }

    @Test func aLocalConnectionWaitsAtMostFiveSecondsForAFileConnection() {
        var m = makeMachine()
        _ = m.localOpened(L(1), now: 100)
        #expect(m.tick(now: 100 + 5 * sec - 1).isEmpty)
        #expect(closedLocals(m.tick(now: 100 + 5 * sec)).map(\.1) == [.noIdleConnection])
        #expect(m.counts.waitingLocal == 0)
        // A late file connection finds nobody to bind.
        #expect(binds(proven(&m, F(1), now: 6 * sec)).isEmpty)
    }

    @Test func moreThanEightWaitingLocalConnectionsAreClosedAtOnce() {
        var m = makeMachine()
        for n in 1...8 { #expect(m.localOpened(L(UInt64(n)), now: 0).isEmpty) }
        #expect(closedLocals(m.localOpened(L(9), now: 0)).map(\.1) == [.tooManyWaiting])
        #expect(m.counts.waitingLocal == 8)
    }

    @Test func aWaitingLocalConnectionThatClosedIsForgotten() {
        var m = makeMachine()
        _ = m.localOpened(L(1), now: 0)
        #expect(m.localClosed(L(1)).isEmpty)
        #expect(m.counts.waitingLocal == 0)
        #expect(binds(proven(&m, F(1))).isEmpty)
    }

    @Test func closingTheLocalSideClosesTheFileConnectionAndNothingElse() {
        var m = makeMachine()
        proven(&m, F(1))
        proven(&m, F(2))
        _ = m.localOpened(L(1), now: 0)
        let out = m.localClosed(L(1))
        #expect(closes(out).map(\.1) == [.localClosed])
        #expect(m.counts.total == 1 && m.counts.idle == 1)
        #expect(m.localClosed(L(1)).isEmpty)  // repeated report
    }

    @Test func closingTheFileSideClosesTheBoundLocalConnectionOnly() {
        var m = makeMachine()
        proven(&m, F(1))
        _ = m.localOpened(L(1), now: 0)
        let out = m.fileClosed(F(1))
        #expect(closedLocals(out).map(\.1) == [.fileClosed])
        #expect(m.counts.total == 0)
        #expect(m.fileClosed(F(1)).isEmpty)
        // An idle connection that closes has no local connection to take along.
        proven(&m, F(2))
        #expect(m.fileClosed(F(2)).isEmpty)
    }

    // MARK: Direction rule

    @Test func theHostSpeaksFirstOnAFileConnection() {
        var m = makeMachine()
        proven(&m, F(1))
        // Unbound and silent: the tablet may only PING.
        #expect(closes(m.record(F(1), data, now: 1)).map(\.1) == [.protocolError])

        proven(&m, F(2))
        _ = m.localOpened(L(1), now: 1)
        // Bound, but the host has not sent anything yet: data from the tablet is a protocol error, the local side
        // is closed with it.
        let early = m.record(F(2), data, now: 1)
        #expect(closes(early).map(\.1) == [.protocolError])
        #expect(closedLocals(early).map(\.1) == [.fileClosed])

        proven(&m, F(3))
        _ = m.localOpened(L(2), now: 1)
        m.hostSentData(F(3))
        #expect(m.record(F(3), data, now: 2) == [.dataToLocal(F(3), L(2))])
        #expect(m.record(F(3), data, now: 3) == [.dataToLocal(F(3), L(2))])
        #expect(m.record(F(3), ping, now: 4).isEmpty)
    }

    @Test func hostSentDataOnAnIdleOrUnknownConnectionChangesNothing() {
        var m = makeMachine()
        m.hostSentData(F(99))
        proven(&m, F(1))
        m.hostSentData(F(1))
        #expect(closes(m.record(F(1), data, now: 1)).map(\.1) == [.protocolError])
    }

    @Test func otherKnownTypesAreProtocolErrors() {
        for message in [Message.bye(.normal), .filesNet(.close), .filesHello(hello()), .filesHelloAck(.rejected),
                        .key(KeyEvent(timeUs: 1, scanCode: 1, androidKeyCode: 1, action: .down, capsLockOn: false))] {
            var m = makeMachine()
            proven(&m, F(1))
            #expect(closes(m.record(F(1), message, now: 1)).map(\.1) == [.protocolError])
        }
    }

    @Test func protocolAndAuthFailuresCloseOnlyThatConnection() {
        var m = makeMachine()
        proven(&m, F(1))
        proven(&m, F(2))
        _ = m.localOpened(L(1), now: 0)  // binds F(1)
        let bad = m.protocolError(F(1))
        #expect(closes(bad).map(\.1) == [.protocolError])
        #expect(closedLocals(bad).map(\.1) == [.fileClosed])
        #expect(closes(m.recordAuthFailed(F(2))).map(\.1) == [.authFailed])
        #expect(m.counts.total == 0)
        #expect(m.protocolError(F(2)).isEmpty)
    }

    @Test func keysUnavailableClosesWithoutTouchingOthers() {
        var m = makeMachine()
        proven(&m, F(1))
        _ = m.accepted(F(2), peer: peer, now: 0)
        _ = m.hello(F(2), hello(), now: 0)
        #expect(closes(m.keysUnavailable(F(2))).map(\.1) == [.keysUnavailable])
        #expect(m.counts.idle == 1 && m.counts.total == 1)
    }

    // MARK: Session end

    @Test func closeEndsEveryFileConnectionAndWaitingLocalConnection() {
        var m = makeMachine()
        proven(&m, F(1))
        proven(&m, F(2))
        _ = m.accepted(F(3), peer: peer, now: 0)
        _ = m.localOpened(L(1), now: 0)  // bound to F(1)
        _ = m.localOpened(L(2), now: 0)  // bound to F(2)
        _ = m.localOpened(L(3), now: 0)  // waits
        let out = m.close()
        #expect(Set(closes(out).map(\.0)) == [F(1), F(2), F(3)])
        #expect(closes(out).allSatisfy { $0.1 == .sessionEnded })
        #expect(Set(closedLocals(out).map(\.0)) == [L(1), L(2), L(3)])
        #expect(m.counts.closing == 3)  // flushing, until the transport reports them closed
        for id in [F(1), F(2), F(3)] { _ = m.fileClosed(id) }
        #expect(m.counts == FilesPoolCounts())
        #expect(!m.isOpen)
        #expect(m.tick(now: 100 * sec).isEmpty)
        #expect(m.nextDeadline == nil)
    }

    @Test func reopeningForAnotherSessionClosesTheOldOnes() {
        var m = makeMachine()
        proven(&m, F(1))
        let out = m.open(sessionID: 9, controlPeer: peer, max: 12, pool: 2)
        #expect(closes(out).map(\.0) == [F(1)])
        #expect(m.counts.total == 0)
        // Opening again for the same session keeps the connections and only updates the limits.
        _ = m.accepted(F(2), peer: peer, now: 0)
        _ = m.hello(F(2), hello(session: 9), now: 0)
        _ = m.record(F(2), ping, now: 0)
        #expect(closes(m.open(sessionID: 9, controlPeer: peer, max: 4, pool: 1)).isEmpty)
        #expect(m.counts.idle == 1)
    }

    @Test func nextDeadlineTracksTheEarliestTimer() {
        var m = makeMachine()
        #expect(m.nextDeadline == nil)
        _ = m.accepted(F(1), peer: peer, now: 100)
        #expect(m.nextDeadline == 100 + 5 * sec)
        proven(&m, F(2), now: 100)
        _ = m.localOpened(L(1), now: 50)  // binds F(2)
        _ = m.localOpened(L(2), now: 60)  // waits until 60 + 5 s
        #expect(m.nextDeadline == 60 + 5 * sec)
    }

    // MARK: Logs

    @Test func logFieldsCarryOnlyCountersAndReasonTokens() {
        var m = makeMachine()
        var logs: [String] = []
        func collect(_ actions: [FilesAction]) {
            for case .log(_, let ev, _, let fields) in actions { logs.append("\(ev) \(fields)") }
        }
        collect(m.accepted(F(1), peer: "192.168.1.99", now: 0))
        collect(m.accepted(F(2), peer: peer, now: 0))
        collect(m.hello(F(2), hello(session: 99), now: 0))
        collect(proven(&m, F(3)))
        collect(m.localOpened(L(1), now: 0))
        collect(m.close())
        #expect(!logs.isEmpty)
        for line in logs {
            #expect(!line.contains(peer))
            #expect(!line.contains("192.168"))
            #expect(!line.contains("7070"))  // nonces
            #expect(!line.contains("8080"))
        }
    }
}
