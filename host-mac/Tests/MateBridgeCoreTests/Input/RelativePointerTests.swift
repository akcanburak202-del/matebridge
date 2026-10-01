import Testing
@testable import MateBridgeCore

// REL-* (T-103): relative pointer moves start at the live cursor the Host samples (`InjectionEnvironment.cursor`) and
// report the client's raw movement as their delta, so games that warp or detach the cursor see no invisible walls.
// No CGEvent, nothing is posted. `testGeometry`: origin (100, 50), 1400 x 920 pt, scale 2; center (800, 510); the
// last point is (1499.5, 969.5).

/// The Double a protocol f32 delta becomes (0.4 as f32 is not 0.4).
private func f(_ v: Float) -> Double { Double(v) }

private func env(cursor: DisplayPoint?) -> InjectionEnvironment {
    InjectionEnvironment(canInject: true, geometry: testGeometry, cursor: cursor)
}

private func rel(_ dx: Float, _ dy: Float, dragging: MouseButton? = nil) -> InjectAction {
    .mouseMove(.relative(dx: dx, dy: dy), dragging: dragging)
}

/// The single mouse event of a planner call.
private func mouse(_ events: [MacEvent]) -> MacMouse? {
    guard events.count == 1, case .mouse(let m) = events[0] else { return nil }
    return m
}

@Suite("REL: relative pointer from the live cursor (T-103)")
struct RelativePointerTests {
    @Test("REL-1 a game warps the cursor back to the center after every move: each move starts there, no wall")
    func rel1_warpedCursor() throws {
        var p = InjectionPlanner()
        let c = testGeometry.center
        // 100 moves of +30 pt would be 3000 pt: far beyond the right edge for a model of our own.
        for i in 0..<100 {
            let m = try #require(mouse(p.plan([rel(30, -7)], environment: env(cursor: c), now: UInt64(i) * 1000)))
            #expect(m.position == DisplayPoint(x: c.x + 30, y: c.y - 7))
            #expect(m.deltaX == 30)
            #expect(m.deltaY == -7)
        }
    }

    @Test("REL-2 pushing on at the display edge keeps reporting the raw delta while the position stays clamped")
    func rel2_edge() throws {
        var p = InjectionPlanner()
        // The system follows the injected cursor: the live sample is where the previous event put it.
        var live: DisplayPoint? = nil
        for i in 0..<60 {
            let m = try #require(mouse(p.plan([rel(50, 40)], environment: env(cursor: live), now: UInt64(i) * 1000)))
            #expect(m.deltaX == 50)
            #expect(m.deltaY == 40)
            #expect(testGeometry.contains(m.position))
            live = m.position
        }
        #expect(live == DisplayPoint(x: 1499.5, y: 969.5))
        // Without a live sample at all (query failing) the same holds.
        for _ in 0..<5 {
            let m = try #require(mouse(p.plan([rel(-50, 0)], environment: env(cursor: nil), now: 0)))
            #expect(m.deltaX == -50)
        }
        var q = InjectionPlanner()
        for _ in 0..<40 { _ = q.plan([rel(-100, 0)], environment: openEnv, now: 0) }
        let m = try #require(mouse(q.plan([rel(-100, 0)], environment: openEnv, now: 0)))
        #expect(m.position.x == testGeometry.originX)
        #expect(m.deltaX == -100)
    }

    @Test("REL-3 fractional movement is carried into whole-point deltas in both directions; positions keep fractions")
    func rel3_fractions() throws {
        var p = InjectionPlanner()
        var deltas: [Double] = []
        var positions: [Double] = []
        for _ in 0..<5 {
            let m = try #require(mouse(p.plan([rel(0.4, -0.4)], environment: openEnv, now: 0)))
            deltas.append(m.deltaX)
            #expect(m.deltaY == -m.deltaX)
            positions.append(m.position.x)
        }
        #expect(deltas == [0, 0, 1, 0, 1])
        let c = testGeometry.center
        for (i, x) in positions.enumerated() { #expect(abs(x - (c.x + f(0.4) * Double(i + 1))) < 1e-9) }
        // Back the other way: the carry (+0.0 after 2.0 of 2.0) goes negative and whole points come out negative.
        var back: [Double] = []
        for _ in 0..<5 { back.append(try #require(mouse(p.plan([rel(-0.4, 0)], environment: openEnv, now: 0))).deltaX) }
        #expect(back == [0, 0, -1, 0, -1])
        // Every delta is a whole number, and no motion is lost or invented over a long run.
        var q = InjectionPlanner()
        var sum = 0.0
        for _ in 0..<1000 {
            let d = try #require(mouse(q.plan([rel(0.37, 0)], environment: openEnv, now: 0))).deltaX
            #expect(d == d.rounded())
            sum += d
        }
        #expect(sum == 370)
    }

    @Test("REL-4 a live sample within a point of the cached position keeps the cached fraction (the system may round)")
    func rel4_roundedLiveKeepsFraction() throws {
        var p = InjectionPlanner()
        let c = testGeometry.center
        let first = try #require(mouse(p.plan([rel(0.4, 0.3)], environment: env(cursor: c), now: 0)))
        #expect(first.position == DisplayPoint(x: c.x + f(0.4), y: c.y + f(0.3)))
        // The system reports the cursor rounded to whole points.
        let rounded = DisplayPoint(x: first.position.x.rounded(.down), y: first.position.y.rounded(.down))
        let second = try #require(mouse(p.plan([rel(0.4, 0.3)], environment: env(cursor: rounded), now: 0)))
        #expect(abs(second.position.x - (c.x + 2 * f(0.4))) < 1e-9)
        #expect(abs(second.position.y - (c.y + 2 * f(0.3))) < 1e-9)
        // A sample a whole point or more away on either axis is someone else's move and wins.
        let moved = DisplayPoint(x: second.position.x, y: second.position.y + 1)
        let third = try #require(mouse(p.plan([rel(1, 0)], environment: env(cursor: moved), now: 0)))
        #expect(third.position == DisplayPoint(x: moved.x + 1, y: moved.y))
    }

    @Test("REL-5 a live cursor on another display is ignored: the move goes on from the last position on the display")
    func rel5_offDisplay() throws {
        var p = InjectionPlanner()
        let start = DisplayPoint(x: 300, y: 200)
        let first = try #require(mouse(p.plan([rel(5, 5)], environment: env(cursor: start), now: 0)))
        #expect(first.position == DisplayPoint(x: 305, y: 205))
        // The user moved the Mac's own mouse to the main display (left of and above the virtual one), or to the point
        // right after the virtual display's last one (that belongs to a neighbor).
        for elsewhere in [DisplayPoint(x: 50, y: 20), DisplayPoint(x: 1500, y: 300), DisplayPoint(x: 300, y: 970)] {
            var q = p
            let m = try #require(mouse(q.plan([rel(5, 5)], environment: env(cursor: elsewhere), now: 0)))
            #expect(m.position == DisplayPoint(x: 310, y: 210))
            #expect(m.deltaX == 5)
        }
        // A failed query (nil) also uses the last known position.
        let m = try #require(mouse(p.plan([rel(5, 5)], environment: env(cursor: nil), now: 0)))
        #expect(m.position == DisplayPoint(x: 310, y: 210))
        // Before any position at all an off-display sample falls back to the center.
        var fresh = InjectionPlanner()
        let f = try #require(mouse(fresh.plan([rel(1, 1)], environment: env(cursor: DisplayPoint(x: 0, y: 0)), now: 0)))
        #expect(f.position == DisplayPoint(x: testGeometry.center.x + 1, y: testGeometry.center.y + 1))
    }

    @Test("REL-6 the last fractional point of the display is a valid live sample (clamped), not another display")
    func rel6_lastPoint() throws {
        var p = InjectionPlanner()
        let m = try #require(mouse(p.plan([rel(-1, -1)], environment: env(cursor: DisplayPoint(x: 1499.9, y: 969.9)),
                                          now: 0)))
        #expect(m.position == DisplayPoint(x: 1498.5, y: 968.5))
    }

    @Test("REL-7 buttons press and release at the live cursor; drags start there; double clicks still count")
    func rel7_buttonsAtLiveCursor() {
        var p = InjectionPlanner()
        var model = MacEventModel()
        let a = DisplayPoint(x: 400, y: 300)
        var events = p.plan([.mouseButton(.left, down: true)], environment: env(cursor: a), now: 1_000_000)
        #expect(events == [mouseEvent(.down, at: a, clickState: 1)])
        model.apply(events)
        events = p.plan([.mouseButton(.left, down: false)], environment: env(cursor: a), now: 1_050_000)
        #expect(events == [mouseEvent(.up, at: a, clickState: 1)])
        model.apply(events)
        // Second press close in time and place: a double click, at the live cursor.
        let a2 = DisplayPoint(x: 401, y: 300)
        events = p.plan([.mouseButton(.left, down: true)], environment: env(cursor: a2), now: 1_100_000)
        #expect(events == [mouseEvent(.down, at: a2, clickState: 2)])
        model.apply(events)
        // The game warps the cursor while the button is held: the drag starts at the warped position, raw delta.
        let warped = DisplayPoint(x: 800, y: 510)
        events = p.plan([rel(6, -2, dragging: .left)], environment: env(cursor: warped), now: 1_120_000)
        #expect(events == [mouseEvent(.dragged, at: DisplayPoint(x: 806, y: 508), delta: DisplayPoint(x: 6, y: -2))])
        model.apply(events)
        // The release lands where the cursor really is.
        events = p.plan([.mouseButton(.left, down: false)], environment: env(cursor: warped), now: 1_140_000)
        #expect(events == [mouseEvent(.up, at: warped, clickState: 2)])
        model.apply(events)
        #expect(model.violations.isEmpty)
        #expect(model.isIdle)
        #expect(!p.isHoldingInput)
    }

    @Test("REL-8 within one message the button applies where the move put the cursor, not at the stale live sample")
    func rel8_moveThenButton() {
        var p = InjectionPlanner()
        let live = DisplayPoint(x: 500, y: 500)
        let events = p.plan([rel(10, 0), .mouseButton(.right, down: true)], environment: env(cursor: live), now: 0)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 510, y: 500), delta: DisplayPoint(x: 10, y: 0)),
                           mouseEvent(.down, .right, at: DisplayPoint(x: 510, y: 500), clickState: 1)])
    }

    /// The Host samples the live cursor for `POINTER_REL` only, so absolute input never carries one; even if it did,
    /// an absolute move still lands on its own target and the pen is untouched.
    @Test("REL-9 absolute moves and the pen keep their positions whatever the live cursor says")
    func rel9_absoluteUnchanged() {
        var p = InjectionPlanner()
        var q = InjectionPlanner()
        let target = testGeometry.point(x: 500, y: 600)
        let a = p.plan([moveAbs(500, 600)], environment: env(cursor: DisplayPoint(x: 300, y: 300)), now: 0)
        let b = q.plan([moveAbs(500, 600)], environment: openEnv, now: 0)
        #expect(a.map(eventPosition) == [target])
        #expect(b == [mouseEvent(.moved, at: target)])  // without a sample: exactly as before T-103
        let pen: [InjectAction] = [penEnter(), .penHover(tool: .pen, penPt(1000, 2000)), .penDown(tool: .pen, penPt(1000, 2000, 500))]
        #expect(p.plan(pen, environment: env(cursor: DisplayPoint(x: 300, y: 300)), now: 0)
            == q.plan(pen, environment: openEnv, now: 0))
    }

    @Test("REL-10 release-all with a button held releases it at the last on-display position and drops the carry")
    func rel10_releaseNeverStuck() throws {
        var p = InjectionPlanner()
        var model = MacEventModel()
        let a = DisplayPoint(x: 400, y: 300)
        model.apply(p.plan([rel(0.7, 0), .mouseButton(.left, down: true)], environment: env(cursor: a), now: 0))
        // The live cursor leaves for another display; the release does not follow it there.
        let released = p.releaseAll(environment: env(cursor: DisplayPoint(x: 0, y: 0)))
        #expect(released == [mouseEvent(.up, at: DisplayPoint(x: 400 + f(0.7), y: 300), clickState: 1)])
        model.apply(released)
        #expect(model.isIdle)
        #expect(model.violations.isEmpty)
        // The 0.7 carried before the release is gone: 0.7 more is still less than a point.
        let m = try #require(mouse(p.plan([rel(0.7, 0)], environment: openEnv, now: 0)))
        #expect(m.deltaX == 0)
    }

    @Test("REL-11 the pipeline carries the live cursor from POINTER_REL messages to the planner")
    func rel11_pipeline() {
        var pipe = InputPipeline()
        _ = pipe.sessionStarted(now: 1_000, environment: openEnv)
        let c = testGeometry.center
        var events: [MacEvent] = []
        for i in 0..<50 { events = pipe.handle(relMsg(40, 0), now: 2_000 + UInt64(i) * 1_000, environment: env(cursor: c)) }
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: c.x + 40, y: c.y), delta: DisplayPoint(x: 40, y: 0))])
    }
}

@Suite("REL: WindowServer lag versus someone else moving the cursor (T-103)")
struct RelativePointerLagTests {
    @Test("REL-12 a fast burst whose live samples lag one to three posts behind loses no movement")
    func rel12_lagNoLostSteps() throws {
        var p = InjectionPlanner()
        let start = DisplayPoint(x: 300, y: 300)
        var posted: [DisplayPoint] = []
        for i in 0..<40 {
            // WindowServer has applied only the post `lag` steps ago, or the oldest one when fewer exist (the first
            // sample is the real starting point).
            let lag = 1 + i % 3
            let sample = posted.isEmpty ? start : posted[Swift.max(0, posted.count - lag)]
            let m = try #require(mouse(p.plan([rel(20, 10)], environment: env(cursor: sample), now: UInt64(i) * 8_000)))
            #expect(m.position == DisplayPoint(x: 300 + 20 * Double(i + 1), y: 300 + 10 * Double(i + 1)))
            #expect(m.deltaX == 20)
            posted.append(m.position)
        }
        #expect(p.counters.liveCursorAdopted == 1)  // the starting point only
        // A one-post lag is the planner's own cursor ("current"); older ones match the ring ("lag ignored").
        #expect(p.counters.liveCursorCurrent == 14)
        #expect(p.counters.liveCursorLagIgnored == 25)
    }

    @Test("REL-13 a warp to a position that is none of our recent posts is adopted, even in the middle of a burst")
    func rel13_warpAdopted() throws {
        var p = InjectionPlanner()
        var posted: [DisplayPoint] = []
        for i in 0..<5 {
            let sample = posted.last ?? DisplayPoint(x: 300, y: 300)
            posted.append(try #require(mouse(p.plan([rel(20, 0)], environment: env(cursor: sample), now: UInt64(i)))).position)
        }
        let warp = DisplayPoint(x: 800, y: 510)
        let m = try #require(mouse(p.plan([rel(20, 0)], environment: env(cursor: warp), now: 10)))
        #expect(m.position == DisplayPoint(x: 820, y: 510))
        #expect(m.deltaX == 20)
        #expect(p.counters.liveCursorAdopted == 2)
    }

    @Test("REL-14 the ring holds only the last 8 relative targets")
    func rel14_ringBounded() throws {
        var p = InjectionPlanner()
        var posted: [DisplayPoint] = []
        for i in 0..<10 {
            let sample = posted.last ?? DisplayPoint(x: 300, y: 300)
            posted.append(try #require(mouse(p.plan([rel(20, 0)], environment: env(cursor: sample), now: UInt64(i)))).position)
        }
        var q = p
        _ = try #require(mouse(q.plan([rel(1, 0)], environment: env(cursor: posted[2]), now: 20)))  // 8th newest
        #expect(q.counters.liveCursorLagIgnored == p.counters.liveCursorLagIgnored + 1)
        let m = try #require(mouse(p.plan([rel(1, 0)], environment: env(cursor: posted[1]), now: 20)))  // 9th newest
        #expect(m.position == DisplayPoint(x: posted[1].x + 1, y: posted[1].y))
    }

    @Test("REL-15 release-all clears the ring: an old posted position is then someone else's move")
    func rel15_ringClearedOnRelease() throws {
        var p = InjectionPlanner()
        var posted: [DisplayPoint] = []
        for i in 0..<4 {
            let sample = posted.last ?? DisplayPoint(x: 300, y: 300)
            posted.append(try #require(mouse(p.plan([rel(20, 0)], environment: env(cursor: sample), now: UInt64(i)))).position)
        }
        let old = posted[0]
        var before = p
        let lagged = try #require(mouse(before.plan([rel(1, 0)], environment: env(cursor: old), now: 10)))
        #expect(lagged.position == DisplayPoint(x: posted[3].x + 1, y: posted[3].y))  // still a lag: model kept
        _ = p.releaseAll(environment: openEnv)
        let after = try #require(mouse(p.plan([rel(1, 0)], environment: env(cursor: old), now: 10)))
        #expect(after.position == DisplayPoint(x: old.x + 1, y: old.y))  // adopted
    }

    @Test("REL-16 the pipeline's session end releases through the planner and so clears the ring")
    func rel16_sessionEndClearsRing() throws {
        var pipe = InputPipeline()
        _ = pipe.sessionStarted(now: 1_000, environment: openEnv)
        let first = pipe.handle(relMsg(20, 0), now: 2_000, environment: env(cursor: DisplayPoint(x: 300, y: 300)))
        _ = pipe.handle(relMsg(20, 0), now: 3_000, environment: env(cursor: DisplayPoint(x: 320, y: 300)))
        _ = pipe.sessionEnded(now: 4_000, environment: openEnv)
        _ = pipe.sessionStarted(now: 5_000, environment: openEnv)
        let old = try #require(first.first.flatMap(eventPosition))
        let events = pipe.handle(relMsg(1, 0), now: 6_000, environment: env(cursor: old))
        #expect(events.first.flatMap(eventPosition) == DisplayPoint(x: old.x + 1, y: old.y))
    }
}

@Suite("GEO: live cursor on the display (T-103)")
struct LiveCursorGeometryTests {
    @Test("GEO-8 onDisplay accepts the half-open bounds, clamps the last fraction and refuses other displays")
    func geo8_onDisplay() {
        let g = testGeometry
        #expect(g.onDisplay(DisplayPoint(x: 100, y: 50)) == DisplayPoint(x: 100, y: 50))
        #expect(g.onDisplay(DisplayPoint(x: 800, y: 510)) == DisplayPoint(x: 800, y: 510))
        #expect(g.onDisplay(DisplayPoint(x: 1499.75, y: 969.75)) == DisplayPoint(x: 1499.5, y: 969.5))
        #expect(g.onDisplay(DisplayPoint(x: 1500, y: 500)) == nil)
        #expect(g.onDisplay(DisplayPoint(x: 800, y: 970)) == nil)
        #expect(g.onDisplay(DisplayPoint(x: 99.9, y: 500)) == nil)
        #expect(g.onDisplay(DisplayPoint(x: 800, y: 49.9)) == nil)
        #expect(g.onDisplay(DisplayPoint(x: .nan, y: 500)) == nil)
        #expect(g.onDisplay(DisplayPoint(x: 800, y: .infinity)) == nil)
    }
}
