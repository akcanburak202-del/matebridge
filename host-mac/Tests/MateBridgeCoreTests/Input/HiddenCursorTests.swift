import Testing
@testable import MateBridgeCore

// HID-* (T-272, changed by T-361): while the Mac's cursor is hidden, relative pointer moves still move it (a web page
// shows a `cursor: none` cursor again only when its position changes) but keep it 8 pt inside every display edge, so it
// never reaches the Dock or the menu bar. `testGeometry`: origin (100, 50), 1400 x 920 pt, scale 2; center (800, 510);
// inner rectangle x 108...1491.5, y 58...961.5.

private func env(cursor: DisplayPoint?, hidden: Bool) -> InjectionEnvironment {
    InjectionEnvironment(canInject: true, geometry: testGeometry, cursor: cursor, cursorHidden: hidden)
}

private func rel(_ dx: Float, _ dy: Float, dragging: MouseButton? = nil) -> InjectAction {
    .mouseMove(.relative(dx: dx, dy: dy), dragging: dragging)
}

@Suite("HID: relative pointer while the cursor is hidden (T-272, T-361)")
struct HiddenCursorTests {
    @Test("HID-1 hidden: the cursor moves with the delta (regression: T-272 froze it, so pages never re-showed it)")
    func hid1_moves() {
        var p = InjectionPlanner()
        let live = DisplayPoint(x: 1000, y: 700)
        let events = p.plan([rel(30, 20)], environment: env(cursor: live, hidden: true), now: 0)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 1030, y: 720), delta: DisplayPoint(x: 30, y: 20))])
        #expect(p.cursor == DisplayPoint(x: 1030, y: 720))
        #expect(p.counters.hiddenCursorMoves == 1)
    }

    @Test("HID-1b hidden: a long run is clamped 8 pt inside all four edges; the delta stays raw")
    func hid1b_insetClamp() {
        let live = DisplayPoint(x: 800, y: 510)
        let cases: [(Float, Float, DisplayPoint)] = [
            (-5000, 0, DisplayPoint(x: 108, y: 510)),
            (5000, 0, DisplayPoint(x: 1491.5, y: 510)),
            (0, -5000, DisplayPoint(x: 800, y: 58)),
            (0, 5000, DisplayPoint(x: 800, y: 961.5)),
        ]
        for (dx, dy, want) in cases {
            var p = InjectionPlanner()
            let events = p.plan([rel(dx, dy)], environment: env(cursor: live, hidden: true), now: 0)
            #expect(events == [mouseEvent(.moved, at: want, delta: DisplayPoint(x: Double(dx), y: Double(dy)))])
        }
        // Repeated pushes against the wall stay on the margin.
        var p = InjectionPlanner()
        var at = live
        for i in 0..<50 {
            let events = p.plan([rel(-100, 0)], environment: env(cursor: at, hidden: true), now: UInt64(i) * 8_000)
            guard case .mouse(let m) = events[0] else { Issue.record("no mouse event"); return }
            at = m.position
        }
        #expect(at.x == 108)
    }

    @Test("HID-1c a live cursor resting on the edge is brought in by the first hidden move, by at most 8 pt")
    func hid1c_edgeBroughtIn() {
        var p = InjectionPlanner()
        var events = p.plan([rel(0, 0)], environment: env(cursor: DisplayPoint(x: 100, y: 400), hidden: true), now: 0)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 108, y: 400), delta: .zero)])
        p = InjectionPlanner()
        events = p.plan([rel(-3, 2)], environment: env(cursor: DisplayPoint(x: 100, y: 400), hidden: true), now: 0)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 108, y: 402), delta: DisplayPoint(x: -3, y: 2))])
        p = InjectionPlanner()
        events = p.plan([rel(1, -1)], environment: env(cursor: DisplayPoint(x: 600, y: 50), hidden: true), now: 0)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 601, y: 58), delta: DisplayPoint(x: 1, y: -1))])
        p = InjectionPlanner()
        events = p.plan([rel(0, 0)], environment: env(cursor: DisplayPoint(x: 1499.5, y: 969.5), hidden: true), now: 0)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 1491.5, y: 961.5), delta: .zero)])
    }

    @Test("HID-2 visible behaves as before: the cursor moves and the hidden counter stays zero")
    func hid2_visibleUnchanged() {
        var p = InjectionPlanner()
        let live = DisplayPoint(x: 400, y: 300)
        let events = p.plan([rel(10, -5)], environment: env(cursor: live, hidden: false), now: 0)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 410, y: 295), delta: DisplayPoint(x: 10, y: -5))])
        #expect(p.counters.hiddenCursorMoves == 0)
    }

    @Test("HID-2b visible still runs to the very edge (no margin)")
    func hid2b_visibleEdge() {
        var p = InjectionPlanner()
        let events = p.plan([rel(-5000, 0)], environment: env(cursor: DisplayPoint(x: 800, y: 510), hidden: false), now: 0)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 100, y: 510), delta: DisplayPoint(x: -5000, y: 0))])
    }

    @Test("HID-3 fractions are carried across hidden moves; positions follow the whole-point deltas")
    func hid3_fractions() {
        var p = InjectionPlanner()
        var at = DisplayPoint(x: 500, y: 400)
        var deltas: [Double] = []
        for i in 0..<5 {
            let events = p.plan([rel(0.4, 0)], environment: env(cursor: at, hidden: true), now: UInt64(i) * 8_000)
            guard events.count == 1, case .mouse(let m) = events[0] else { Issue.record("no mouse event"); return }
            #expect(abs(m.position.x - (at.x + 0.4)) < 1e-6)
            deltas.append(m.deltaX)
            at = m.position
        }
        #expect(deltas == [0, 0, 1, 0, 1])
    }

    @Test("HID-4 a drag while hidden moves inside the margin; down and up land at the cursor, none dropped")
    func hid4_drag() {
        var p = InjectionPlanner()
        var model = MacEventModel()
        var at = DisplayPoint(x: 700, y: 500)
        var events = p.plan([.mouseButton(.left, down: true)], environment: env(cursor: at, hidden: true), now: 1_000_000)
        #expect(events == [mouseEvent(.down, at: at, clickState: 1)])
        model.apply(events)
        for i in 0..<200 {
            events = p.plan([rel(-25, 0, dragging: .left)], environment: env(cursor: at, hidden: true),
                            now: 1_010_000 + UInt64(i) * 8_000)
            guard case .mouse(let m) = events[0] else { Issue.record("no mouse event"); return }
            #expect(m.kind == .dragged)
            #expect(m.deltaX == -25)
            #expect(m.position.x >= 108)
            at = m.position
            model.apply(events)
        }
        #expect(at.x == 108)
        events = p.plan([.mouseButton(.left, down: false)], environment: env(cursor: at, hidden: true), now: 3_000_000)
        #expect(events == [mouseEvent(.up, at: at, clickState: 1)])
        model.apply(events)
        #expect(model.violations.isEmpty)
        #expect(model.isIdle)
        #expect(!p.isHoldingInput)
    }

    @Test("HID-5 visible to hidden to visible: the hidden stretch is clamped inside, visible goes to the edge")
    func hid5_transitions() {
        var p = InjectionPlanner()
        var at = DisplayPoint(x: 300, y: 300)
        var events = p.plan([rel(10, 0)], environment: env(cursor: at, hidden: false), now: 0)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 310, y: 300), delta: DisplayPoint(x: 10, y: 0))])
        at = DisplayPoint(x: 310, y: 300)
        for i in 1...5 {
            events = p.plan([rel(-100, 0)], environment: env(cursor: at, hidden: true), now: UInt64(i) * 8_000)
            guard case .mouse(let m) = events[0] else { Issue.record("no mouse event"); return }
            #expect(m.position.x >= 108)
            at = m.position
        }
        #expect(at.x == 108)
        events = p.plan([rel(-100, 0)], environment: env(cursor: at, hidden: false), now: 1_000_000)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 100, y: 300), delta: DisplayPoint(x: -100, y: 0))])
    }

    @Test("HID-6 hidden without a usable live sample: from the last known position, else the center")
    func hid6_noSample() {
        var p = InjectionPlanner()
        var events = p.plan([rel(5, 5)], environment: env(cursor: nil, hidden: true), now: 0)
        let first = DisplayPoint(x: testGeometry.center.x + 5, y: testGeometry.center.y + 5)
        #expect(events == [mouseEvent(.moved, at: first, delta: DisplayPoint(x: 5, y: 5))])
        events = p.plan([rel(5, 5)], environment: env(cursor: DisplayPoint(x: 20, y: 20), hidden: true), now: 8_000)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: first.x + 5, y: first.y + 5),
                                      delta: DisplayPoint(x: 5, y: 5))])
    }

    @Test("HID-7 absolute pointer and the pen are unaffected by the hidden flag")
    func hid7_absoluteUnchanged() {
        var p = InjectionPlanner()
        let hidden = env(cursor: DisplayPoint(x: 400, y: 400), hidden: true)
        let events = p.plan([.mouseMove(.absolute(x: 0, y: 0), dragging: nil)], environment: hidden, now: 0)
        guard events.count == 1, case .mouse(let m) = events[0] else { Issue.record("no mouse event"); return }
        #expect(m.position == DisplayPoint(x: testGeometry.originX, y: testGeometry.originY))
        #expect(p.counters.hiddenCursorMoves == 0)
    }

    @Test("HID-8 a button-only message right after the game recentered the hidden cursor lands at the live cursor (P2)")
    func hid8_clickAfterRecenter() {
        var p = InjectionPlanner()
        var model = MacEventModel()
        let c = testGeometry.center  // (800, 510)
        // A visible move posts a -> a + 30. (T-361: a sample at the very spot of a recent post is lag by design, so
        // the game recenters somewhere else, as it does in practice.)
        let a = DisplayPoint(x: 300, y: 300)
        var events = p.plan([rel(30, 0)], environment: env(cursor: a, hidden: false), now: 0)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 330, y: 300), delta: DisplayPoint(x: 30, y: 0))])
        model.apply(events)
        // Within the lag window the game hides the cursor and recenters it; the user clicks without moving. The
        // sample is far from every recent post, so it is adopted as someone else's move.
        events = p.plan([.mouseButton(.left, down: true)], environment: env(cursor: c, hidden: true), now: 50_000)
        #expect(events == [mouseEvent(.down, at: c, clickState: 1)])
        model.apply(events)
        // The up (still hidden, sample unchanged) is posted at the same place and never dropped.
        events = p.plan([.mouseButton(.left, down: false)], environment: env(cursor: c, hidden: true), now: 100_000)
        #expect(events == [mouseEvent(.up, at: c, clickState: 1)])
        model.apply(events)
        #expect(model.violations.isEmpty)
        #expect(model.isIdle)
        #expect(!p.isHoldingInput)
    }

    @Test("HID-9 the cursor un-hides between a down and its up: the up is still posted, at the cursor's real position")
    func hid9_upAfterUnhide() {
        var p = InjectionPlanner()
        var model = MacEventModel()
        let a = DisplayPoint(x: 600, y: 400)
        var events = p.plan([.mouseButton(.left, down: true)], environment: env(cursor: a, hidden: true), now: 0)
        model.apply(events)
        events = p.plan([.mouseButton(.left, down: false)], environment: env(cursor: a, hidden: false), now: 10_000)
        #expect(events == [mouseEvent(.up, at: a, clickState: 1)])
        model.apply(events)
        #expect(model.violations.isEmpty)
        #expect(model.isIdle)
    }
}
