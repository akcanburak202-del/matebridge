import Testing
@testable import MateBridgeCore

// Local cursor planner, cache, outbox, layout and geometry (decision 0036, PROTOCOL.md 0x0B-0x0D and section 5).

private func snap(_ x: UInt16 = 100, _ y: UInt16 = 200, visible: Bool = true, shape: UInt32 = 7) -> CursorSnapshot {
    CursorSnapshot(x: x, y: y, visible: visible, shapeID: shape)
}

/// A planner that went through `PREFS(1)`, the first sample at `t`, and the successful video change.
private func onPlanner(at t: UInt64 = 1_000_000) -> CursorStreamPlanner {
    var p = CursorStreamPlanner()
    _ = p.prefs(enabled: true)
    _ = p.observe(snap(), nowUs: t)
    _ = p.videoCursorResult(ok: true)
    return p
}

@Suite struct CursorPlannerTests {
    // MARK: Order of enabling and disabling

    @Test func CURPLAN1_prefsOnStartsTrackingAndNothingElseYet() {
        var p = CursorStreamPlanner()
        #expect(p.phase == .off && !p.isTracking)
        #expect(p.prefs(enabled: true) == [.startTracking])
        #expect(p.phase == .enabling && p.isTracking)
    }

    @Test func CURPLAN2_firstSampleIsSentBeforeTheVideoCursorGoes() {
        var p = CursorStreamPlanner()
        _ = p.prefs(enabled: true)
        let o = p.observe(snap(), nowUs: 5_000)
        #expect(o.send == snap())
        #expect(o.commands == [.setVideoCursor(shows: false)])
        #expect(p.phase == .applyingHide)
        #expect(p.videoCursorResult(ok: true).isEmpty)
        #expect(p.phase == .on)
    }

    @Test func CURPLAN3_prefsOffPutsTheVideoCursorBackBeforeStopping() {
        var p = onPlanner()
        #expect(p.prefs(enabled: false) == [.setVideoCursor(shows: true)])
        #expect(p.phase == .applyingShow)
        #expect(p.isTracking)  // states keep flowing until the cursor is back
        #expect(p.videoCursorResult(ok: true) == [.stopTracking])
        #expect(p.phase == .off && !p.isTracking)
    }

    @Test func CURPLAN4_prefsOffBeforeTheFirstSampleTouchesNothing() {
        var p = CursorStreamPlanner()
        _ = p.prefs(enabled: true)
        #expect(p.prefs(enabled: false) == [.stopTracking])
        #expect(p.phase == .off)
    }

    @Test func CURPLAN5_prefsOffWhileHidingWaitsForTheResultThenRestores() {
        var p = CursorStreamPlanner()
        _ = p.prefs(enabled: true)
        _ = p.observe(snap(), nowUs: 0)
        #expect(p.prefs(enabled: false).isEmpty)  // the hide is in flight
        #expect(p.videoCursorResult(ok: true) == [.setVideoCursor(shows: true)])
        #expect(p.phase == .applyingShow)
        #expect(p.videoCursorResult(ok: true) == [.stopTracking])
    }

    @Test func CURPLAN6_prefsOnWhileRestoringStartsAgainAfterTheStop() {
        var p = onPlanner()
        _ = p.prefs(enabled: false)
        #expect(p.prefs(enabled: true).isEmpty)  // the restore is in flight
        #expect(p.videoCursorResult(ok: true) == [.stopTracking, .startTracking])
        #expect(p.phase == .enabling)
    }

    @Test func CURPLAN7_aFailedHideLeavesTheCursorInTheVideoAndStops() {
        var p = CursorStreamPlanner()
        _ = p.prefs(enabled: true)
        _ = p.observe(snap(), nowUs: 0)
        #expect(p.videoCursorResult(ok: false) == [.stopTracking])
        #expect(p.phase == .off && !p.wanted)
        // Nothing is sent afterwards, and the same request is not retried by itself.
        #expect(p.observe(snap(1, 1), nowUs: 1_000_000).send == nil)
    }

    @Test func CURPLAN8_aFailedRestoreStillStops() {
        var p = onPlanner()
        _ = p.prefs(enabled: false)
        #expect(p.videoCursorResult(ok: false) == [.stopTracking])
        #expect(p.phase == .off)
    }

    @Test func CURPLAN9_repeatedAndStaleCallsAreHarmless() {
        var p = CursorStreamPlanner()
        #expect(p.prefs(enabled: false).isEmpty)
        #expect(p.videoCursorResult(ok: true).isEmpty)
        _ = p.prefs(enabled: true)
        #expect(p.prefs(enabled: true).isEmpty)
        _ = p.observe(snap(), nowUs: 0)
        _ = p.videoCursorResult(ok: true)
        #expect(p.prefs(enabled: true).isEmpty)
        #expect(p.videoCursorResult(ok: false).isEmpty)  // stale: nothing is changing
        #expect(p.phase == .on)
    }

    @Test func CURPLAN10_resetForgetsEverything() {
        var p = onPlanner()
        _ = p.prefs(enabled: false)
        p.reset()
        #expect(p.phase == .off && !p.wanted)
        #expect(p.observe(snap(), nowUs: 9).send == nil)
        // A new session starts clean.
        #expect(p.prefs(enabled: true) == [.startTracking])
        #expect(p.observe(snap(), nowUs: 10).send == snap())
    }

    // MARK: Rate

    @Test func CURPLAN11_aChangeWithinTheIntervalIsHeldAndWinsLater() {
        var p = onPlanner(at: 1_000_000)
        let held = p.observe(snap(101), nowUs: 1_003_000)
        #expect(held.send == nil)
        #expect(held.retryAtUs == 1_008_000)
        // A newer sample replaces it: only the newest goes out.
        let later = p.observe(snap(150), nowUs: 1_008_000)
        #expect(later.send == snap(150))
    }

    @Test func CURPLAN12_aChangeAfterTheIntervalGoesOutAtOnce() {
        var p = onPlanner(at: 1_000_000)
        #expect(p.observe(snap(101), nowUs: 1_008_000).send == snap(101))
        #expect(p.observe(snap(102), nowUs: 1_016_000).send == snap(102))
    }

    @Test func CURPLAN13_anUnchangedSampleIsNotSentUntilTheKeepAlive() {
        var p = onPlanner(at: 1_000_000)
        #expect(p.observe(snap(), nowUs: 1_100_000).send == nil)
        #expect(p.observe(snap(), nowUs: 1_100_000).retryAtUs == nil)
        #expect(p.observe(snap(), nowUs: 1_499_999).send == nil)
        #expect(p.observe(snap(), nowUs: 1_500_000).send == snap())
        // The keep-alive restarts the clock.
        #expect(p.observe(snap(), nowUs: 1_600_000).send == nil)
        #expect(p.observe(snap(), nowUs: 2_000_000).send == snap())
    }

    @Test func CURPLAN14_visibilityAndShapeChangesAreChanges() {
        var p = onPlanner(at: 1_000_000)
        #expect(p.observe(snap(visible: false), nowUs: 1_010_000).send == snap(visible: false))
        #expect(p.observe(snap(visible: false, shape: 9), nowUs: 1_020_000).send == snap(visible: false, shape: 9))
    }

    @Test func CURPLAN15_anOldClockReadingNeverUnderflows() {
        var p = onPlanner(at: 1_000_000)
        // A sample stamped before the last send (clock jitter): treated as no time passed.
        #expect(p.observe(snap(5), nowUs: 999_000).send == nil)
    }

    @Test func CURPLAN16_stateKeepsFlowingWhileRestoring() {
        var p = onPlanner(at: 1_000_000)
        _ = p.prefs(enabled: false)
        #expect(p.observe(snap(300), nowUs: 1_010_000).send == snap(300))
    }

    @Test func CURPLAN18_aLostVideoCursorStopsARunningFlow() {
        var p = onPlanner()
        #expect(p.videoCursorLost() == [.stopTracking])
        #expect(p.phase == .off && !p.wanted)
        #expect(p.observe(snap(9), nowUs: 9_000_000).send == nil)
        // The tablet's later request starts over.
        #expect(p.prefs(enabled: true) == [.startTracking])
    }

    @Test func CURPLAN19_aLostVideoCursorIsIgnoredWhenNothingRuns() {
        var p = CursorStreamPlanner()
        #expect(p.videoCursorLost().isEmpty)
        _ = p.prefs(enabled: true)
        #expect(p.videoCursorLost().isEmpty)  // still enabling
        _ = p.observe(snap(), nowUs: 0)
        #expect(p.videoCursorLost().isEmpty)  // the planner's own hide is in flight and answers itself
        #expect(p.phase == .applyingHide)
    }

    @Test func CURPLAN17_customIntervals() {
        var c = CursorStreamPlanner.Configuration()
        c.minIntervalUs = 1_000
        c.keepAliveUs = 10_000
        var p = CursorStreamPlanner(configuration: c)
        _ = p.prefs(enabled: true)
        _ = p.observe(snap(), nowUs: 0)
        _ = p.videoCursorResult(ok: true)
        #expect(p.observe(snap(2), nowUs: 1_000).send == snap(2))
        #expect(p.observe(snap(2), nowUs: 11_000).send == snap(2))
    }
}

@Suite struct CursorShapeCacheTests {
    @Test func CURCACHE1_firstUseIsAMissThenAHit() {
        var c = CursorShapeCache()
        #expect(c.use(5) == false)
        #expect(c.use(5) == true)
        #expect(c.count == 1)
    }

    @Test func CURCACHE2_theBuiltInArrowIsNeverSent() {
        var c = CursorShapeCache()
        #expect(c.use(0) == true)
        #expect(c.count == 0)
    }

    @Test func CURCACHE3_the33rdIdForgetsTheLeastRecentlyUsed() {
        var c = CursorShapeCache()
        for id in 1...32 { #expect(c.use(UInt32(id)) == false) }
        #expect(c.count == 32)
        #expect(c.use(1) == true)  // 1 is now the most recent; 2 is the oldest
        #expect(c.use(33) == false)
        #expect(c.count == 32)
        #expect(!c.contains(2))
        #expect(c.contains(1) && c.contains(3) && c.contains(33))
        #expect(c.use(2) == false)  // forgotten: sent again
    }

    @Test func CURCACHE4_clearForgetsAll() {
        var c = CursorShapeCache()
        _ = c.use(1)
        c.removeAll()
        #expect(c.use(1) == false)
    }

    @Test func CURCACHE5_aStateUseRefreshesLikeAShapeSend() {
        var c = CursorShapeCache(capacity: 2)
        _ = c.use(1)
        _ = c.use(2)
        _ = c.use(1)  // a STATE that names 1
        _ = c.use(3)  // evicts 2, not 1
        #expect(c.contains(1) && c.contains(3) && !c.contains(2))
    }
}

@Suite struct CursorShapeStoreTests {
    private func shape(_ id: UInt32) -> CursorShape {
        CursorShape(shapeID: id, widthPt16: 16, heightPt16: 16, hotXPt16: 0, hotYPt16: 0, data: [UInt8(id & 0xff)])
    }

    @Test func CURSTORE1_putAndUse() {
        var s = CursorShapeStore()
        s.put(shape(5))
        #expect(s.use(5)?.data == [5])
        #expect(s.use(6) == nil)
    }

    @Test func CURSTORE2_theLeastRecentlyUsedIsPushedOutPastTheCapacity() {
        var s = CursorShapeStore(capacity: 3)
        s.put(shape(1)); s.put(shape(2)); s.put(shape(3))
        _ = s.use(1)  // 2 is now the oldest
        s.put(shape(4))
        #expect(s.count == 3)
        #expect(!s.contains(2) && s.contains(1) && s.contains(3) && s.contains(4))
    }

    @Test func CURSTORE3_aReplacedShapeKeepsOneEntry() {
        var s = CursorShapeStore(capacity: 3)
        s.put(shape(1))
        s.put(CursorShape(shapeID: 1, widthPt16: 16, heightPt16: 16, hotXPt16: 0, hotYPt16: 0, data: [9]))
        #expect(s.count == 1)
        #expect(s.use(1)?.data == [9])
    }

    @Test func CURSTORE4_removeAllEmpties() {
        var s = CursorShapeStore()
        s.put(shape(1))
        s.removeAll()
        #expect(s.count == 0 && !s.contains(1))
    }

    @Test func CURCACHE6_forgetMakesTheNextUseAMiss() {
        var c = CursorShapeCache()
        _ = c.use(4)
        c.forget(4)
        #expect(c.use(4) == false)
    }
}

@Suite struct CursorPrefsMailboxTests {
    @Test func CURPREFS1_theNewestWinsAndOnlyOneWakeIsScheduled() {
        var m = CursorPrefsMailbox()
        let token = m.post(session: 5, enabled: true)
        #expect(token != nil)
        #expect(m.post(session: 5, enabled: false) == nil)
        #expect(m.post(session: 5, enabled: true) == nil)
        let t = m.take(token: token!)
        #expect(t?.session == 5 && t?.enabled == true)
        #expect(m.take(token: token!) == nil)
        #expect(m.post(session: 5, enabled: false) != nil)  // the wake was spent
    }

    @Test func CURPREFS2_aSessionBoundaryVoidsWhatWasPostedAndOldWakesAreStale() {
        var m = CursorPrefsMailbox()
        let a = m.post(session: 5, enabled: true)!
        m.clear()  // A ends
        m.clear()  // B starts
        let b = m.post(session: 6, enabled: true)
        #expect(b != nil && b != a)  // the old wake does not count for B: B gets its own
        // The stale wake runs first: it takes nothing and leaves B's message alone.
        #expect(m.take(token: a) == nil)
        let t = m.take(token: b!)
        #expect(t?.session == 6 && t?.enabled == true)
    }

    @Test func CURPREFS3_aStaleWakeThatFindsNothingIsHarmless() {
        var m = CursorPrefsMailbox()
        let a = m.post(session: 5, enabled: true)!
        m.clear()
        #expect(m.take(token: a) == nil)
        #expect(m.post(session: 6, enabled: false) != nil)
    }

    @Test func CURPREFS4_theTakeoverFindingBPrefsIsNeverConsumedByAnOldWake() {
        var m = CursorPrefsMailbox()
        let a = m.post(session: 5, enabled: true)!  // A's wake is queued
        m.clear()  // takeover: A ends...
        m.clear()  // ...B starts
        let b = m.post(session: 6, enabled: true)!  // B's PREFS(1)
        #expect(m.take(token: a) == nil)  // A's wake runs before B's start block would: nothing consumed
        #expect(m.take(token: b)?.session == 6)
    }
}

@Suite struct CursorOutboxTests {
    @Test func CURBOX1_theFirstUnitIsTakenImmediately() {
        var o = CursorOutbox<Int>()
        #expect(o.submit(1) == true)  // kick needed
        #expect(o.take() == 1)
        #expect(o.isWriting)
    }

    @Test func CURBOX2_aNewerUnitReplacesTheWaitingOne() {
        var o = CursorOutbox<Int>()
        _ = o.submit(1)
        let g = o.generation
        #expect(o.take() == 1)
        #expect(o.submit(2) == false)  // nothing to kick: a write is running
        #expect(o.submit(3) == false)
        #expect(o.replaced == 1)  // 2 was replaced by 3 and never written
        #expect(o.take() == nil)  // still writing
        o.completed(generation: g)
        #expect(o.take() == 3)
        #expect(o.take() == nil)
    }

    @Test func CURBOX3_atMostOneKickIsScheduled() {
        var o = CursorOutbox<Int>()
        #expect(o.submit(1) == true)
        #expect(o.submit(2) == false)
        #expect(o.submit(3) == false)
        #expect(o.take() == 3)
        #expect(o.replaced == 2)
    }

    @Test func CURBOX4_aStaleCompletionDoesNotReleaseTheNextSession() {
        var o = CursorOutbox<Int>()
        _ = o.submit(1)
        let old = o.generation
        _ = o.take()
        o.reset()
        _ = o.submit(2)
        _ = o.take()
        o.completed(generation: old)  // the old session's write finishing late
        #expect(o.isWriting)
        o.completed(generation: o.generation)
        #expect(!o.isWriting)
    }

    @Test func CURBOX5_discardPendingKeepsTheWriteRunning() {
        var o = CursorOutbox<Int>()
        _ = o.submit(1)
        _ = o.take()
        _ = o.submit(2)
        o.discardPending()
        #expect(!o.hasPending && o.isWriting)
    }
}

@Suite struct CursorShapeLayoutTests {
    private typealias L = CursorShapeLayout
    private func size(_ w: Int, _ h: Int) -> L.Size { L.Size(width: w, height: h) }

    @Test func CURSHAPE1_theSmallestRepresentationWithTwoPixelsPerPointWins() {
        // A 28 x 40 pt arrow with 1x, 2x and 10x representations: 2x is enough.
        let reps = [size(28, 40), size(280, 400), size(56, 80)]
        #expect(L.chooseRepresentation(reps, pointWidth: 28, pointHeight: 40) == 2)
    }

    @Test func CURSHAPE2_withoutAnyEnoughTheLargestWins() {
        let reps = [size(16, 16), size(20, 20)]
        #expect(L.chooseRepresentation(reps, pointWidth: 16, pointHeight: 16) == 1)
    }

    @Test func CURSHAPE3_aLoneTenTimesRepresentationIsTheOneToUse() {
        #expect(L.chooseRepresentation([size(280, 400)], pointWidth: 28, pointHeight: 40) == 0)
    }

    @Test func CURSHAPE4_emptyOrDegenerateRepresentationsGiveNil() {
        #expect(L.chooseRepresentation([], pointWidth: 10, pointHeight: 10) == nil)
        #expect(L.chooseRepresentation([size(0, 5), size(5, 0)], pointWidth: 10, pointHeight: 10) == nil)
        #expect(L.chooseRepresentation([size(0, 5), size(8, 8)], pointWidth: 4, pointHeight: 4) == 1)
    }

    @Test func CURSHAPE5_sentSizeFitsOneHundredTwentyEightKeepingAspect() {
        #expect(L.sentSize(of: size(18, 36)) == size(18, 36))
        #expect(L.sentSize(of: size(128, 128)) == size(128, 128))
        #expect(L.sentSize(of: size(280, 400)) == size(90, 128))
        #expect(L.sentSize(of: size(512, 256)) == size(128, 64))
        #expect(L.sentSize(of: size(1000, 1)) == size(128, 1))
    }

    @Test func CURSHAPE6_smallerShrinksByAQuarterAndStopsAtEightPixels() {
        #expect(L.smaller(size(128, 128)) == size(96, 96))
        #expect(L.smaller(size(10, 40)) == nil)
        #expect(L.smaller(size(11, 11)) == size(8, 8))
        #expect(L.smaller(size(8, 8)) == nil)
    }

    @Test func CURSHAPE7_pt16RoundsAndClamps() {
        #expect(L.pt16(9) == 144)
        #expect(L.pt16(4.03) == 64)
        #expect(L.pt16(0) == 0)
        #expect(L.pt16(-3) == 0)
        #expect(L.pt16(.nan) == 0)
        #expect(L.pt16(.infinity) == 0)
        #expect(L.pt16(5000) == 65535)
    }

    @Test func CURSHAPE8_shapeIDIsStableNonZeroAndSensitiveToEveryPart() {
        let base = L.shapeID(pixelHash: 0x1234_5678_9abc_def0, widthPt16: 144, heightPt16: 288, hotXPt16: 64,
                             hotYPt16: 144)
        #expect(base != 0)
        #expect(base == L.shapeID(pixelHash: 0x1234_5678_9abc_def0, widthPt16: 144, heightPt16: 288, hotXPt16: 64,
                                  hotYPt16: 144))
        #expect(base != L.shapeID(pixelHash: 0x1234_5678_9abc_def1, widthPt16: 144, heightPt16: 288, hotXPt16: 64,
                                  hotYPt16: 144))
        #expect(base != L.shapeID(pixelHash: 0x1234_5678_9abc_def0, widthPt16: 145, heightPt16: 288, hotXPt16: 64,
                                  hotYPt16: 144))
        #expect(base != L.shapeID(pixelHash: 0x1234_5678_9abc_def0, widthPt16: 144, heightPt16: 288, hotXPt16: 65,
                                  hotYPt16: 144))
        #expect(base != L.shapeID(pixelHash: 0x1234_5678_9abc_def0, widthPt16: 144, heightPt16: 288, hotXPt16: 64,
                                  hotYPt16: 145))
    }

    @Test func CURSHAPE9_pixelHashDependsOnBytesAndLength() {
        let a = [UInt8](repeating: 1, count: 37), b = [UInt8](repeating: 1, count: 38)
        var c = a
        c[36] = 2
        let ha = a.withUnsafeBytes { L.pixelHash($0) }
        #expect(ha == a.withUnsafeBytes { L.pixelHash($0) })
        #expect(ha != b.withUnsafeBytes { L.pixelHash($0) })
        #expect(ha != c.withUnsafeBytes { L.pixelHash($0) })
    }
}

@Suite struct CursorGeometryTests {
    private func display(scale: Double = 2) -> DisplayGeometry {
        DisplayGeometry(originX: 100, originY: -50, widthPt: 1400, heightPt: 920, scale: scale)!
    }

    @Test func CURGEO1_cornersAndCenter() {
        let g = display()
        #expect(g.normalizedPosition(of: DisplayPoint(x: 100, y: -50)) == (0, 0))
        let mid = g.normalizedPosition(of: DisplayPoint(x: 800, y: 410))
        #expect(mid == (32768, 32768))
    }

    @Test func CURGEO2_outsideIsClampedToTheNearestEdge() {
        let g = display()
        #expect(g.normalizedPosition(of: DisplayPoint(x: -5000, y: 99999)) == (0, 65535))
        #expect(g.normalizedPosition(of: DisplayPoint(x: 1500, y: -50)) == (65535, 0))
    }

    @Test func CURGEO3_nonFiniteIsZero() {
        let g = display()
        #expect(g.normalizedPosition(of: DisplayPoint(x: .nan, y: .infinity)) == (0, 0))
    }

    @Test func CURGEO4_theInverseOfTheInputMappingWithinOneStep() {
        let g = display()
        for v in stride(from: 0, through: 65_000, by: 997) {
            let p = g.point(x: UInt16(v), y: UInt16(v))
            let back = g.normalizedPosition(of: p)
            #expect(abs(Int(back.x) - v) <= 1)
            #expect(abs(Int(back.y) - v) <= 1)
        }
    }

    @Test func CURGEO5_theLastPixelStaysInsideAndAGameDisplayAtOneXMapsAlike() {
        let g1 = DisplayGeometry(originX: 0, originY: 0, widthPt: 1848, heightPt: 1214, scale: 1)!
        let last = g1.normalizedPosition(of: DisplayPoint(x: 1847, y: 1213))
        #expect(last.x >= 65_450 && last.x <= 65_535)
        #expect(last.y >= 65_450 && last.y <= 65_535)
        let g2 = display(scale: 2)
        let edge = g2.normalizedPosition(of: g2.point(x: 65535, y: 65535))
        #expect(edge.x >= 65_450 && edge.y >= 65_450)
    }
}

@Suite struct CursorStatsTests {
    @Test func CURSTAT1_nothingHappenedMeansNoLine() {
        var s = CursorStats()
        #expect(s.takeReport(nowUs: 0, replaced: 0) == nil)
        #expect(s.takeReport(nowUs: 1_000_000, replaced: 0) == nil)
    }

    @Test func CURSTAT2_aWindowReportsCountsAndPercentilesOnceAndResets() {
        var s = CursorStats()
        s.restart(nowUs: 0, replaced: 3)
        for i in 1...100 { s.recordSample(costUs: UInt64(i), ok: i != 7) }
        for _ in 0..<40 { s.recordState() }
        s.recordShapeBuilt()
        s.recordShapeSent(bytes: 300)
        s.recordShapeSent(bytes: 200)
        #expect(s.takeReport(nowUs: 999_999, replaced: 5) == nil)  // window still open
        let line = s.takeReport(nowUs: 1_000_000, replaced: 5)
        #expect(line == "states=40 shapes=2 shape_bytes=500 shapes_built=1 shape_failed=0 replaced=2 samples=100 "
            + "sample_failed=1 sample_us_p50=50 sample_us_p95=95")
        // Reset: a quiet second reports nothing.
        #expect(s.takeReport(nowUs: 2_000_000, replaced: 5) == nil)
    }

    @Test func CURSTAT3_neverContainsPositionsOrImages() {
        var s = CursorStats()
        s.restart(nowUs: 0, replaced: 0)
        s.recordState()
        let line = s.takeReport(nowUs: 1_000_000, replaced: 0) ?? ""
        for forbidden in ["x=", "y=", "png", "pos"] { #expect(!line.contains(forbidden)) }
    }
}
