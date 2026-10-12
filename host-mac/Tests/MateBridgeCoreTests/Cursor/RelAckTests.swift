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

extension RelAckBoard {
    /// What the input side does for one POINTER_REL: note what was posted (if anything), then the message.
    fileprivate func rel(_ posted: DisplayPoint?, at nowUs: UInt64) {
        beginWrite()
        if let posted { notePosted(posted, nowUs: nowUs) }
        notePointerRel()
        endWrite()
    }

    /// A post that is not a POINTER_REL (pen, absolute pointer, release batch).
    fileprivate func post(_ location: DisplayPoint, at nowUs: UInt64) {
        beginWrite()
        notePosted(location, nowUs: nowUs)
        endWrite()
    }
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
            board.rel(pt(Double(i)), at: UInt64(i))
            let c = board.read(nowUs: UInt64(i)).count
            #expect(c == last + 1)
            last = c
        }
        board.reset()
        #expect(board.read(nowUs: 100) == RelAckBoard.Reading(count: 0, target: nil))
    }

    @Test func CURACK_droppedMessageIsAcknowledgedWithoutATarget() {
        let board = RelAckBoard()
        board.rel(nil, at: 10)  // dropped as stale (0025) or by a gate: nothing was posted
        #expect(board.read(nowUs: 11) == RelAckBoard.Reading(count: 1, target: nil))
    }

    @Test func CURACK_aMessageStillQueuedIsNotCounted() {
        let board = RelAckBoard()
        board.rel(pt(1), at: 1)
        board.rel(pt(2), at: 2)
        // message 3 sits in the queue: no call yet
        #expect(board.read(nowUs: 3).count == 2)
    }

    @Test func CURACK_targetExpiresWithTheLagWindow() {
        let board = RelAckBoard(lagWindowUs: 100_000)
        board.rel(pt(5), at: 1_000)
        #expect(board.read(nowUs: 101_000).target == pt(5))
        #expect(board.read(nowUs: 101_001).target == nil)
        #expect(board.read(nowUs: 101_001).count == 1)  // the count never expires
    }

    @Test func CURACK_aLaterPostOverwritesTheLocationNothingClearsIt() {
        let board = RelAckBoard()
        board.rel(pt(5), at: 1)
        board.post(pt(9), at: 2)  // e.g. a pen point or an absolute move
        #expect(board.read(nowUs: 3) == RelAckBoard.Reading(count: 1, target: pt(9)))
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
        board.rel(pt(110), at: 1_000)  // move #1 posted at 110, live still shows 100
        board.rel(nil, at: 2_000)  // #2 posts nothing
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
                board.rel(noOp ? nil : target, at: UInt64(step))
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
        board.rel(pt(10), at: 1)
        var live = pt(10)
        var calls = 0
        let (reading, position) = try! #require(board.coherentPosition(nowUs: { 2 }, locate: {
            calls += 1
            if calls == 1 {  // the input queue handles move 2 and WindowServer applies it, mid-sample
                board.rel(pt(20), at: 2)
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
            board.rel(pt(Double(n) * 10), at: UInt64(n))
            return before
        })
        #expect(result == nil)
        #expect(calls == 4)  // first try + 3 retries
    }

    /// Codex P2 (a6f35eda): last try reads 130, move #14 (to 140) is posted, the board changes during the try.
    /// Count 14 with position 130 must never come out.
    @Test func CURACK_moveOnTheLastTryDefers() {
        let board = RelAckBoard()
        var tries = 0
        var count = 0
        let result = board.coherentPosition(retries: 3, nowUs: { 1 }, locate: {
            tries += 1
            if tries < 4 {  // earlier tries are disturbed by other moves so the retries run out
                count += 1
                board.rel(pt(Double(count) * 10), at: 1)
                return pt(Double(count - 1) * 10)
            }
            count += 1
            board.rel(pt(140), at: 1)  // move #14 posted, WindowServer not there yet
            return pt(130)
        })
        #expect(result == nil)
    }

    /// A post that lands between the reads of a try (any source) forces a retry.
    @Test func CURACK_postBetweenTheReadsRetries() {
        let board = RelAckBoard()
        board.rel(pt(10), at: 1)
        var calls = 0
        let result = board.coherentPosition(nowUs: { 1 }, locate: {
            calls += 1
            if calls == 1 { board.post(pt(10), at: 1) }
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

@Suite struct RelAckLastPostedLocationTests {
    /// Codex P2 (c3e9d19f): a held-button rel drag posts 140 (live still 130, ack 1); a later gated KEY DOWN yields a
    /// release batch with a mouse-up at 140. The up is just another post at 140: the location stays 140.
    @Test func CURACK_releaseBatchMouseUpKeepsTheLocation() {
        let board = RelAckBoard()
        board.rel(pt(140), at: 1_000)
        board.post(pt(140), at: 2_000)  // the synthesized mouse-up
        let result = board.coherentPosition(nowUs: { 3_000 }, locate: { pt(130) })
        #expect(result?.reading.count == 1)
        #expect(result?.position == pt(140))
    }

    /// PINCH, scroll, keys: they post no location, so nothing on the board changes (unchanged results).
    @Test func CURACK_nonMovingInjectionsLeaveTheBoardAlone() {
        let board = RelAckBoard()
        board.rel(pt(140), at: 1)
        let before = board.read(nowUs: 2)
        var calls = 0
        let result = board.coherentPosition(nowUs: { 2 }, locate: {
            calls += 1  // a zero-scale PINCH is handled here: InputController notes nothing
            return pt(130)
        })
        #expect(calls == 1)
        #expect(result?.reading.count == 1)
        #expect(result?.position == pt(140))
        #expect(board.read(nowUs: 2) == before)
    }

    /// An absolute or pen post reports its own location (live still shows the old place).
    @Test func CURACK_absoluteOrPenPostReportsItsOwnLocation() {
        let board = RelAckBoard()
        board.rel(pt(140), at: 1)
        board.post(pt(300), at: 2)  // pen / POINTER_ABS
        let result = board.coherentPosition(nowUs: { 3 }, locate: { pt(130) })
        #expect(result?.position == pt(300))
        #expect(result?.reading.count == 1)
    }

    /// A physical mouse moves the cursor with no post: within the lag window the last posted location still wins,
    /// after 100 ms the live position is reported.
    @Test func CURACK_liveMoveWithoutAPostWinsAfterTheLagWindow() {
        let board = RelAckBoard(lagWindowUs: 100_000)
        board.rel(pt(140), at: 1_000)
        #expect(board.coherentPosition(nowUs: { 50_000 }, locate: { pt(500) })?.position == pt(140))
        let late = board.coherentPosition(nowUs: { 101_001 }, locate: { pt(500) })
        #expect(late?.position == pt(500))
        #expect(late?.reading.count == 1)
    }
}

@Suite struct RelAckSeqlockTests {
    /// Codex P2a: a sample whose live read happens inside a write (the input queue is posting move #2) never produces a
    /// pair, however many tries it gets while the write stays open.
    @Test func CURACK_sampleInsideAWriteDefers() {
        let board = RelAckBoard()
        board.rel(pt(110), at: 1)
        board.beginWrite()  // message #2 starts: nothing is posted or counted yet
        let result = board.coherentPosition(nowUs: { 2 }, locate: { pt(120) })
        #expect(result == nil)
        board.notePosted(pt(120), nowUs: 2)
        board.notePointerRel()
        #expect(board.coherentPosition(nowUs: { 2 }, locate: { pt(120) }) == nil)  // still open until endWrite
        board.endWrite()
        let done = board.coherentPosition(nowUs: { 2 }, locate: { pt(120) })
        #expect(done?.reading.count == 2)
        #expect(done?.position == pt(120))
    }

    /// The exact interleaving: from (ack 1, x 110) move #2 posts 120. (ack 1, x 120) must be impossible whatever the
    /// moment of the sample, including WindowServer applying the post before the board is updated.
    @Test func CURACK_ackOneWithMoveTwoPositionCannotBeProduced() {
        // Sample start points relative to the write's steps; the live position is 120 from step 2 on.
        for startStep in 0...4 {
            let board = RelAckBoard()
            board.rel(pt(110), at: 1)
            var step = 0
            func advance() {
                step += 1
                switch step {
                case 1: board.beginWrite()
                case 2: break  // CGEvents posted; WindowServer applies at once (live = 120)
                case 3: board.notePosted(pt(120), nowUs: 2)
                case 4: board.notePointerRel()
                case 5: board.endWrite()
                default: break
                }
            }
            for _ in 0..<startStep { advance() }
            let result = board.coherentPosition(nowUs: { 2 }, locate: {
                advance()  // the write proceeds one step during the live read
                return step >= 2 ? pt(120) : pt(110)
            })
            if let result {
                let ok = (result.reading.count == 1 && result.position == pt(110))
                    || (result.reading.count == 2 && result.position == pt(120))
                #expect(ok, "start \(startStep): ack \(result.reading.count) x \(result.position?.x ?? -1)")
            }
        }
    }

    /// A live location that moves during a write is never paired with the old count.
    @Test func CURACK_liveMovingDuringAWriteIsNotPairedWithTheOldCount() {
        let board = RelAckBoard()
        board.rel(pt(110), at: 1)
        var calls = 0
        let result = board.coherentPosition(nowUs: { 2 }, locate: {
            calls += 1
            if calls == 1 {
                board.beginWrite()
                board.notePosted(pt(120), nowUs: 2)
                board.notePointerRel()
                board.endWrite()
            }
            return pt(120)  // WindowServer already shows move #2
        })
        #expect(result?.reading.count == 2)  // the first try was thrown away; the retry sees count 2 with 120
        #expect(result?.position == pt(120))
    }

    @Test func CURACK_writesNest() {
        let board = RelAckBoard()
        board.beginWrite()
        board.beginWrite()
        board.endWrite()
        #expect(board.coherentPosition(nowUs: { 1 }, locate: { pt(1) }) == nil)  // the outer write is still open
        board.endWrite()
        #expect(board.coherentPosition(nowUs: { 1 }, locate: { pt(1) }) != nil)
    }
}

@Suite struct PostSummaryTests {
    private func mouse(_ kind: MacMouse.Kind, _ x: Double) -> MacEvent {
        .mouse(MacMouse(kind: kind, button: .left, position: pt(x), deltaX: 0, deltaY: 0, clickState: 0))
    }

    /// Codex P2b: the T-323 inject-to-frame hook still arms from a posted press edge (key, mouse down, pen contact),
    /// and never from a failed one or from moves.
    @Test func CURACK_pressEdgeStillArmsInjectToFrame() {
        let down = mouse(.down, 5)
        #expect(PostSummary(events: [mouse(.moved, 1), down], failed: []).pressEdge)
        #expect(!PostSummary(events: [mouse(.moved, 1), mouse(.up, 2)], failed: []).pressEdge)
        #expect(!PostSummary(events: [down], failed: [down]).pressEdge)
        #expect(PostSummary(events: [.key(MacKey(kind: .keyDown, keyCode: 4, flags: []))], failed: []).pressEdge)
    }

    @Test func CURACK_lastLocationIsTheLastPostedOne() {
        let a = mouse(.moved, 1), b = mouse(.up, 7), c = mouse(.moved, 9)
        #expect(PostSummary(events: [a, b], failed: []).lastLocation == pt(7))
        #expect(PostSummary(events: [a, b, c], failed: [c]).lastLocation == pt(7))
        #expect(PostSummary(events: [.capsLock(on: true)], failed: []).lastLocation == nil)
    }
}
