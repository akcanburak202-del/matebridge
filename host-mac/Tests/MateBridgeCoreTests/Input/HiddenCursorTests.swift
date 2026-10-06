import Testing
@testable import MateBridgeCore

// HID-* (T-272): while the Mac's cursor is hidden (a game), relative pointer moves report their delta but leave the
// cursor where it is, so it never runs into the Dock or the menu bar. `testGeometry`: origin (100, 50), 1400 x 920 pt,
// scale 2; center (800, 510).

private func env(cursor: DisplayPoint?, hidden: Bool) -> InjectionEnvironment {
    InjectionEnvironment(canInject: true, geometry: testGeometry, cursor: cursor, cursorHidden: hidden)
}

private func rel(_ dx: Float, _ dy: Float, dragging: MouseButton? = nil) -> InjectAction {
    .mouseMove(.relative(dx: dx, dy: dy), dragging: dragging)
}

@Suite("HID: relative pointer while the cursor is hidden (T-272)")
struct HiddenCursorTests {
    @Test("HID-1 hidden: the position is the live cursor, never moved; the delta is the raw movement")
    func hid1_positionFixed() {
        var p = InjectionPlanner()
        let live = DisplayPoint(x: 1000, y: 700)
        // Far more motion than the display is wide: a visible cursor would have hit the edge long ago.
        for i in 0..<100 {
            let events = p.plan([rel(30, 20)], environment: env(cursor: live, hidden: true), now: UInt64(i) * 8_000)
            #expect(events == [mouseEvent(.moved, at: live, delta: DisplayPoint(x: 30, y: 20))])
        }
        #expect(p.cursor == live)
        #expect(p.counters.hiddenCursorMoves == 100)
    }

    @Test("HID-2 visible behaves as before: the cursor moves and the hidden counter stays zero")
    func hid2_visibleUnchanged() {
        var p = InjectionPlanner()
        let live = DisplayPoint(x: 400, y: 300)
        let events = p.plan([rel(10, -5)], environment: env(cursor: live, hidden: false), now: 0)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 410, y: 295), delta: DisplayPoint(x: 10, y: -5))])
        #expect(p.counters.hiddenCursorMoves == 0)
    }

    @Test("HID-3 fractions are carried across hidden moves; positions stay put")
    func hid3_fractions() {
        var p = InjectionPlanner()
        let live = DisplayPoint(x: 500, y: 400)
        var deltas: [Double] = []
        for _ in 0..<5 {
            let events = p.plan([rel(0.4, 0)], environment: env(cursor: live, hidden: true), now: 0)
            guard events.count == 1, case .mouse(let m) = events[0] else { Issue.record("no mouse event"); return }
            #expect(m.position == live)
            deltas.append(m.deltaX)
        }
        #expect(deltas == [0, 0, 1, 0, 1])
    }

    @Test("HID-4 a drag while hidden keeps the position and the button; down and up land at the live cursor")
    func hid4_drag() {
        var p = InjectionPlanner()
        var model = MacEventModel()
        let live = DisplayPoint(x: 700, y: 500)
        var events = p.plan([.mouseButton(.left, down: true)], environment: env(cursor: live, hidden: true), now: 1_000_000)
        #expect(events == [mouseEvent(.down, at: live, clickState: 1)])
        model.apply(events)
        for i in 0..<20 {
            events = p.plan([rel(25, 0, dragging: .left)], environment: env(cursor: live, hidden: true),
                            now: 1_010_000 + UInt64(i) * 8_000)
            #expect(events == [mouseEvent(.dragged, at: live, delta: DisplayPoint(x: 25, y: 0))])
            model.apply(events)
        }
        events = p.plan([.mouseButton(.left, down: false)], environment: env(cursor: live, hidden: true), now: 1_300_000)
        #expect(events == [mouseEvent(.up, at: live, clickState: 1)])
        model.apply(events)
        #expect(model.violations.isEmpty)
        #expect(model.isIdle)
        #expect(!p.isHoldingInput)
    }

    @Test("HID-5 visible to hidden to visible: only the hidden stretch stays put")
    func hid5_transitions() {
        var p = InjectionPlanner()
        let a = DisplayPoint(x: 300, y: 300)
        var events = p.plan([rel(10, 0)], environment: env(cursor: a, hidden: false), now: 0)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 310, y: 300), delta: DisplayPoint(x: 10, y: 0))])
        // The game hides the cursor and it rests at the last position.
        let rest = DisplayPoint(x: 310, y: 300)
        for i in 1...5 {
            events = p.plan([rel(10, 0)], environment: env(cursor: rest, hidden: true), now: UInt64(i) * 8_000)
            #expect(events == [mouseEvent(.moved, at: rest, delta: DisplayPoint(x: 10, y: 0))])
        }
        // Visible again: movement from the live cursor as usual.
        events = p.plan([rel(10, 0)], environment: env(cursor: rest, hidden: false), now: 1_000_000)
        #expect(events == [mouseEvent(.moved, at: DisplayPoint(x: 320, y: 300), delta: DisplayPoint(x: 10, y: 0))])
    }

    @Test("HID-6 hidden without a usable live sample: the last known position, else the center; never moves")
    func hid6_noSample() {
        var p = InjectionPlanner()
        var events = p.plan([rel(5, 5)], environment: env(cursor: nil, hidden: true), now: 0)
        #expect(events == [mouseEvent(.moved, at: testGeometry.center, delta: DisplayPoint(x: 5, y: 5))])
        // A sample on another display is ignored.
        events = p.plan([rel(5, 5)], environment: env(cursor: DisplayPoint(x: 20, y: 20), hidden: true), now: 8_000)
        #expect(events == [mouseEvent(.moved, at: testGeometry.center, delta: DisplayPoint(x: 5, y: 5))])
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
        // Within the lag window the game hides the cursor and recenters it; the user clicks without moving.
        // Without the fix the sample (the older position) is dropped as lag and the down lands at c + 30.
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
