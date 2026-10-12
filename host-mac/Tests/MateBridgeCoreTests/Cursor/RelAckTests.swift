import Testing
@testable import MateBridgeCore

// CUR-ACK-*: the rel_ack_count of CURSOR_STATE (decision 0036 v3, T-344). The wire format is also covered by the golden
// fixtures `cursor_state_ack` and `invalid_cursor_state_ack_partial` (FixtureTests).

private func frame(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [type]
    for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: UInt32(payload.count) >> (8 * UInt32(i)))) }
    return out + payload
}

private func decodeOne(_ bytes: [UInt8]) throws -> Message? {
    var d = FrameDecoder(connection: .control)
    d.append(bytes)
    return try d.nextMessage()
}

private func pt(_ x: Double, _ y: Double = 0) -> DisplayPoint { DisplayPoint(x: x, y: y) }

@Suite struct RelAckCodecTests {
    private func state(ack: UInt64) -> CursorState {
        CursorState(seq: 7, x: 1, y: 2, visible: true, shapeID: 3, hostTimeUs: 4, relAckCount: ack)
    }

    @Test func CURACK_zeroIsNotWritten() {
        #expect(Message.cursorState(state(ack: 0)).encodePayload().count == 22)
        #expect(Message.cursorState(state(ack: 1)).encodePayload().count == 30)
    }

    @Test func CURACK_roundTripsLargeCounts() throws {
        for ack: UInt64 in [1, 255, 1 << 32, UInt64.max] {
            let payload = Message.cursorState(state(ack: ack)).encodePayload()
            #expect(try decodeOne(frame(0x0D, payload)) == .cursorState(state(ack: ack)))
        }
    }

    @Test func CURACK_withoutGroupDecodesAsZero() throws {
        let payload = Message.cursorState(state(ack: 0)).encodePayload()
        guard case .cursorState(let s)? = try decodeOne(frame(0x0D, payload)) else { Issue.record("not state"); return }
        #expect(s.relAckCount == 0)
    }

    @Test func CURACK_partialGroupIsAProtocolError() {
        let full = Message.cursorState(state(ack: 9)).encodePayload()
        for length in 23...29 {
            #expect(throws: ProtocolError.payloadTooShort(type: 0x0D)) {
                try decodeOne(frame(0x0D, Array(full.prefix(length))))
            }
        }
    }

    @Test func CURACK_longerPayloadKeepsTheGroupAndIgnoresTheRest() throws {
        let payload = Message.cursorState(state(ack: 5)).encodePayload() + [9, 9, 9]
        #expect(try decodeOne(frame(0x0D, payload)) == .cursorState(state(ack: 5)))
    }
}

@Suite struct RelAckBoardTests {
    @Test func CURACK_countIsMonotonicAndResets() {
        let board = RelAckBoard()
        var last: UInt64 = 0
        for i in 0..<50 {
            board.notePointerRel(target: pt(Double(i)), nowUs: UInt64(i))
            let c = board.read(nowUs: UInt64(i)).count
            #expect(c == last + 1)
            last = c
        }
        board.reset()
        #expect(board.read(nowUs: 100) == RelAckBoard.Reading(count: 0, target: nil))
    }

    @Test func CURACK_droppedMessageIsAcknowledgedWithoutATarget() {
        let board = RelAckBoard()
        board.notePointerRel(target: nil, nowUs: 10)  // dropped as stale (0025) or by a gate: nothing was posted
        #expect(board.read(nowUs: 11) == RelAckBoard.Reading(count: 1, target: nil))
    }

    @Test func CURACK_aMessageStillQueuedIsNotCounted() {
        let board = RelAckBoard()
        board.notePointerRel(target: pt(1), nowUs: 1)
        board.notePointerRel(target: pt(2), nowUs: 2)
        // message 3 sits in the queue: no call yet
        #expect(board.read(nowUs: 3).count == 2)
    }

    @Test func CURACK_targetExpiresWithTheLagWindow() {
        let board = RelAckBoard(lagWindowUs: 100_000)
        board.notePointerRel(target: pt(5), nowUs: 1_000)
        #expect(board.read(nowUs: 101_000).target == pt(5))
        #expect(board.read(nowUs: 101_001).target == nil)
        #expect(board.read(nowUs: 101_001).count == 1)  // the count never expires
    }

    @Test func CURACK_anotherInjectionClearsTheTarget() {
        let board = RelAckBoard()
        board.notePointerRel(target: pt(5), nowUs: 1)
        board.noteOtherInjection()
        #expect(board.read(nowUs: 2) == RelAckBoard.Reading(count: 1, target: nil))
    }

    @Test func CURACK_positionPrefersTheTargetOnlyWhileLiveLags() {
        let reading = RelAckBoard.Reading(count: 3, target: pt(100, 50))
        #expect(RelAckBoard.position(live: pt(90, 50), reading: reading) == pt(100, 50))
        #expect(RelAckBoard.position(live: pt(100.4, 50.4), reading: reading) == pt(100.4, 50.4))
        #expect(RelAckBoard.position(live: pt(90, 50), reading: .init(count: 3, target: nil)) == pt(90, 50))
    }

    /// Codex P1: a no-op message after a move that WindowServer has not shown yet must not wipe the pending target.
    @Test func CURACK_noOpAfterAMoveKeepsThePendingTarget() {
        let board = RelAckBoard()
        board.notePointerRel(target: pt(110), nowUs: 1_000)  // move #1 posted at 110, live still shows 100
        board.notePointerRel(target: nil, nowUs: 2_000)  // #2 posts nothing
        let r = board.read(nowUs: 3_000)
        #expect(r.count == 2)
        #expect(RelAckBoard.position(live: pt(100), reading: r) == pt(110))
        // the kept target keeps the age of move #1
        #expect(board.read(nowUs: 1_000 + InjectionPlanner.defaultLagWindowUs + 1).target == nil)
    }

    /// A fake injector in front of a WindowServer that applies a post `lag` steps after it (CGEventPost is
    /// asynchronous): the count and the position must agree.
    @Test func CURACK_ackNeverClaimsAMoveThePositionLacks() {
        for lag in 0...4 {
            let board = RelAckBoard()
            var pending: [(applyAt: Int, point: DisplayPoint)] = []
            var live = pt(0)
            var posted: [DisplayPoint] = [pt(0)]  // posted[k] = position after k moves
            for step in 1...40 {
                let noOp = step % 5 == 0  // some messages post nothing
                let target = noOp ? posted[step - 1] : pt(Double(step) * 3)
                if !noOp { pending.append((step + lag, target)) }
                posted.append(target)
                board.notePointerRel(target: noOp ? nil : target, nowUs: UInt64(step))
                while let first = pending.first, first.applyAt <= step { live = first.point; pending.removeFirst() }
                let (reading, position) = try! #require(board.coherentPosition(nowUs: { UInt64(step) }, locate: { live }))
                #expect(position == posted[Int(reading.count)], "lag \(lag) step \(step)")
            }
        }
    }

    /// Codex P2: move N+1 is handled and applied between the count read and the location read. The pair must not be
    /// (count N, position of N+1).
    @Test func CURACK_moveBetweenTheReadsRetriesToACoherentPair() {
        let board = RelAckBoard()
        board.notePointerRel(target: pt(10), nowUs: 1)
        var live = pt(10)
        var calls = 0
        let (reading, position) = try! #require(board.coherentPosition(nowUs: { 2 }, locate: {
            calls += 1
            if calls == 1 {  // the input queue handles move 2 and WindowServer applies it, mid-sample
                board.notePointerRel(target: pt(20), nowUs: 2)
                live = pt(20)
            }
            return live
        }))
        #expect(reading.count == 2)
        #expect(position == pt(20))
        #expect(calls == 2)  // one retry
    }

    /// Moves keep arriving on every try: after the bounded retries there is no pair, the sample is deferred.
    @Test func CURACK_endlessMovesDeferTheSample() {
        let board = RelAckBoard()
        var n = 0
        var calls = 0
        let result = board.coherentPosition(retries: 3, nowUs: { UInt64(n) }, locate: {
            calls += 1
            let before = pt(Double(n) * 10)
            n += 1
            board.notePointerRel(target: pt(Double(n) * 10), nowUs: UInt64(n))
            return before
        })
        #expect(result == nil)
        #expect(calls == 4)  // first try + 3 retries
    }

    /// Codex P2 (a6f35eda): last try reads 130, move #14 (to 140) is posted, then a zero-scale pinch clears the target
    /// without moving the cursor. Count 14 with position 130 must never come out.
    @Test func CURACK_moveThenTargetClearingInjectionOnTheLastTryDefers() {
        let board = RelAckBoard()
        var tries = 0
        var count = 0
        let result = board.coherentPosition(retries: 3, nowUs: { 1 }, locate: {
            tries += 1
            if tries < 4 {  // earlier tries are disturbed by other moves so the retries run out
                count += 1
                board.notePointerRel(target: pt(Double(count) * 10), nowUs: 1)
                return pt(Double(count - 1) * 10)
            }
            count += 1
            board.notePointerRel(target: pt(140), nowUs: 1)  // move #14 posted, WindowServer not there yet
            board.noteOtherInjection()  // zero-scale PINCH: clears the target, moves nothing
            return pt(130)
        })
        #expect(result == nil)
    }

    /// A target-clearing injection that lands between the reads of a try also forces a retry (no count paired with a
    /// target that vanished mid-sample).
    @Test func CURACK_otherInjectionBetweenTheReadsRetries() {
        let board = RelAckBoard()
        board.notePointerRel(target: pt(10), nowUs: 1)
        var calls = 0
        let result = board.coherentPosition(nowUs: { 1 }, locate: {
            calls += 1
            if calls == 1 { board.noteOtherInjection() }
            return pt(10)
        })
        #expect(calls == 2)
        #expect(result?.reading.count == 1)
    }
}

@Suite struct RelAckPlannerTests {
    @Test func CURACK_anAckChangeAloneIsASendableChange() {
        var planner = CursorStreamPlanner()
        _ = planner.prefs(enabled: true)
        let first = CursorSnapshot(x: 10, y: 10, visible: true, shapeID: 1, relAck: 0)
        _ = planner.observe(first, nowUs: 1_000)
        _ = planner.videoCursorResult(ok: true)
        let same = planner.observe(first, nowUs: 20_000)
        #expect(same.send == nil)
        var acked = first
        acked.relAck = 1
        #expect(planner.observe(acked, nowUs: 20_000).send == acked)
    }
}

@Suite struct RelAckNonMovingInjectionTests {
    /// Codex P2 (dfccfbe3): rel move #1 to 140 (live still 130), a non-moving injection (pinch: the input side does not
    /// call the board at all) lands during the first locate. The pair keeps the target: ack 1 with 140, never 130.
    @Test func CURACK_nonMovingInjectionDuringTheSampleKeepsTheTarget() {
        let board = RelAckBoard()
        board.notePointerRel(target: pt(140), nowUs: 1)
        var calls = 0
        let result = board.coherentPosition(nowUs: { 2 }, locate: {
            calls += 1
            // a zero-scale PINCH is handled here: InputController posts no positioning event, so nothing is noted
            return pt(130)
        })
        #expect(calls == 1)
        #expect(result?.reading.count == 1)
        #expect(result?.position == pt(140))
    }

    /// The same, with the non-moving injection handled before the sample started.
    @Test func CURACK_nonMovingInjectionBeforeTheSampleKeepsTheTarget() {
        let board = RelAckBoard()
        board.notePointerRel(target: pt(140), nowUs: 1)
        let generation = board.read(nowUs: 2)
        // pinch / scroll / key / button-only: no board call
        let result = board.coherentPosition(nowUs: { 3 }, locate: { pt(130) })
        #expect(result?.position == pt(140))
        #expect(board.read(nowUs: 3) == generation)
    }

    /// A positioning injection (pen point, absolute pointer) still supersedes the target: the live position is the truth.
    @Test func CURACK_positioningInjectionStillClearsTheTarget() {
        let board = RelAckBoard()
        board.notePointerRel(target: pt(140), nowUs: 1)
        board.noteOtherInjection()
        let result = board.coherentPosition(nowUs: { 2 }, locate: { pt(300) })
        #expect(result?.position == pt(300))
        #expect(result?.reading.target == nil)
    }
}
