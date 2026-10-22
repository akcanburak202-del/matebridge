import Testing
@testable import MateBridgeCore

// HID-* (T-272, changed by T-361 and T-363): while the Mac's cursor is hidden, relative pointer moves still move it (a web page
// shows a `cursor: none` cursor again only when its position changes) but keep it 8 pt inside every display edge, so it
// never reaches the Dock or the menu bar. `testGeometry`: origin (100, 50), 1400 x 920 pt, scale 2; center (800, 510);
// inner rectangle x 108...1491.5, y 58...961.5.

private func env(cursor: DisplayPoint?, hidden: Bool) -> InjectionEnvironment {
    InjectionEnvironment(canInject: true, geometry: testGeometry, cursor: cursor, cursorHidden: hidden)
}

/// T-363: a hidden relative move is two events: (a) at the base with the delta, (b) at the inset target with delta 0.
private func pair(_ kind: MacMouse.Kind = .moved, base: DisplayPoint, target: DisplayPoint, delta: DisplayPoint) -> [MacEvent] {
    [mouseEvent(kind, at: base, delta: delta), mouseEvent(kind, at: target, delta: .zero)]
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
        #expect(events == pair(base: live, target: DisplayPoint(x: 1030, y: 720), delta: DisplayPoint(x: 30, y: 20)))
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
            #expect(events == pair(base: live, target: want, delta: DisplayPoint(x: Double(dx), y: Double(dy))))
        }
        // Repeated pushes against the wall stay on the margin.
        var p = InjectionPlanner()
        var at = live
        for i in 0..<50 {
            let events = p.plan([rel(-100, 0)], environment: env(cursor: at, hidden: true), now: UInt64(i) * 8_000)
            guard events.count == 2, case .mouse(let m) = events[1] else { Issue.record("no mouse pair"); return }
            at = m.position
        }
        // At the wall the 1 pt inward step alternates 108 / 109 (see HID-1d).
        #expect(at.x == 108 || at.x == 109)
    }

    @Test("HID-1c a live cursor resting on the edge is brought in by the first hidden move, by at most 8 pt")
    func hid1c_edgeBroughtIn() {
        var p = InjectionPlanner()
        var events = p.plan([rel(0, 0)], environment: env(cursor: DisplayPoint(x: 100, y: 400), hidden: true), now: 0)
        #expect(events == pair(base: DisplayPoint(x: 100, y: 400), target: DisplayPoint(x: 108, y: 400), delta: .zero))
        p = InjectionPlanner()
        events = p.plan([rel(-3, 2)], environment: env(cursor: DisplayPoint(x: 100, y: 400), hidden: true), now: 0)
        #expect(events == pair(base: DisplayPoint(x: 100, y: 400), target: DisplayPoint(x: 108, y: 402),
                               delta: DisplayPoint(x: -3, y: 2)))
        p = InjectionPlanner()
        events = p.plan([rel(1, -1)], environment: env(cursor: DisplayPoint(x: 600, y: 50), hidden: true), now: 0)
        #expect(events == pair(base: DisplayPoint(x: 600, y: 50), target: DisplayPoint(x: 601, y: 58),
                               delta: DisplayPoint(x: 1, y: -1)))
        p = InjectionPlanner()
        events = p.plan([rel(0, 0)], environment: env(cursor: DisplayPoint(x: 1499.5, y: 969.5), hidden: true), now: 0)
        #expect(events == pair(base: DisplayPoint(x: 1499.5, y: 969.5), target: DisplayPoint(x: 1491.5, y: 961.5),
                               delta: .zero))
    }

    @Test("HID-1d hidden: moving outward from each inset boundary still changes the position (1 pt inward)")
    func hid1d_boundaryStillMoves() {
        let cases: [(DisplayPoint, Float, Float, DisplayPoint)] = [
            (DisplayPoint(x: 108, y: 400), -10, 0, DisplayPoint(x: 109, y: 400)),
            (DisplayPoint(x: 1491.5, y: 400), 10, 0, DisplayPoint(x: 1490.5, y: 400)),
            (DisplayPoint(x: 600, y: 58), 0, -10, DisplayPoint(x: 600, y: 59)),
            (DisplayPoint(x: 600, y: 961.5), 0, 10, DisplayPoint(x: 600, y: 960.5)),
        ]
        for (live, dx, dy, want) in cases {
            var p = InjectionPlanner()
            let events = p.plan([rel(dx, dy)], environment: env(cursor: live, hidden: true), now: 0)
            #expect(events == pair(base: live, target: want, delta: DisplayPoint(x: Double(dx), y: Double(dy))))
        }
        // Repeated pushes into the left wall: every post differs from the live position and stays inside.
        var p = InjectionPlanner()
        var at = DisplayPoint(x: 108, y: 400)
        for i in 0..<10 {
            let events = p.plan([rel(-10, 0)], environment: env(cursor: at, hidden: true), now: UInt64(i) * 8_000)
            guard events.count == 2, case .mouse(let m) = events[1] else { Issue.record("no mouse pair"); return }
            #expect(m.position != at)
            #expect(m.position.x >= 108)
            at = m.position
        }
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
            guard events.count == 2, case .mouse(let a) = events[0], case .mouse(let m) = events[1] else {
                Issue.record("no mouse pair"); return
            }
            #expect(a.position == at)
            #expect(m.deltaX == 0)
            #expect(abs(m.position.x - (at.x + 0.4)) < 1e-6)
            deltas.append(a.deltaX)
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
            guard events.count == 2, case .mouse(let a) = events[0], case .mouse(let m) = events[1] else {
                Issue.record("no mouse pair"); return
            }
            #expect(a.kind == .dragged && m.kind == .dragged)
            #expect(a.deltaX == -25 && m.deltaX == 0)
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

    @Test("HID-1e hidden: a move into the wall is still two events; the first stays at the base, the second steps in")
    func hid1e_wallPair() {
        var p = InjectionPlanner()
        let live = DisplayPoint(x: 108, y: 400)
        let events = p.plan([rel(-10, 0)], environment: env(cursor: live, hidden: true), now: 0)
        #expect(events == pair(base: live, target: DisplayPoint(x: 109, y: 400), delta: DisplayPoint(x: -10, y: 0)))
        #expect(p.counters.hiddenCursorMoves == 1)  // per message, not per event
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
            guard events.count == 2, case .mouse(let m) = events[1] else { Issue.record("no mouse pair"); return }
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
        #expect(events == pair(base: testGeometry.center, target: first, delta: DisplayPoint(x: 5, y: 5)))
        events = p.plan([rel(5, 5)], environment: env(cursor: DisplayPoint(x: 20, y: 20), hidden: true), now: 8_000)
        #expect(events == pair(base: first, target: DisplayPoint(x: first.x + 5, y: first.y + 5),
                               delta: DisplayPoint(x: 5, y: 5)))
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
        // A visible move posts c -> c + 30.
        var events = p.plan([rel(30, 0)], environment: env(cursor: c, hidden: false), now: 0)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: c.x + 30, y: c.y), delta: DisplayPoint(x: 30, y: 0))])
        model.apply(events)
        // Within the lag window the game hides the cursor and recenters it to the start point; the user clicks
        // without moving. The hidden sample is the base directly (not lag), so the down lands at c.
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
