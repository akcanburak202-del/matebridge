import Testing
@testable import MateBridgeCore

// PLAN-*: InjectAction -> MacEvent, gating, shadow state, click state, scroll. No CGEvent, nothing is posted.

/// The virtual display: HiDPI, not at the origin (positions must add it).
let testGeometry = DisplayGeometry(originX: 100, originY: 50, widthPt: 1400, heightPt: 920, scale: 2)!
let openEnv = InjectionEnvironment(canInject: true, geometry: testGeometry)
let noPermissionEnv = InjectionEnvironment(canInject: false, geometry: testGeometry)
let noDisplayEnv = InjectionEnvironment(canInject: true, geometry: nil)
let closedEnv = InjectionEnvironment(canInject: false, geometry: nil)

/// The `MacEvent` a pen `InjectAction` at `penPt(x, y, pressure)` must turn into.
func tabletEvent(_ kind: MacTabletPoint.Kind, _ tool: PenTool = .pen, x: UInt16 = 1000, y: UInt16 = 2000,
                 pressure: UInt16 = 0, geometry: DisplayGeometry = testGeometry) -> MacEvent {
    .tabletPoint(MacTabletPoint(kind: kind, tool: tool, position: geometry.point(x: x, y: y),
                                pressure: PressureCodec.decode(pressure), tiltX: TiltCodec.decode(defaultTiltX),
                                tiltY: TiltCodec.decode(defaultTiltY),
                                clickState: (kind == .down || kind == .up) ? 1 : 0))
}

/// A scroll `MacEvent`; the position defaults to the center of `testGeometry` (a planner with no cursor yet).
func scrollEvent(_ phase: MacScroll.Phase, _ dx: Int32 = 0, _ dy: Int32 = 0, at p: DisplayPoint = testGeometry.center) -> MacEvent {
    .scroll(MacScroll(phase: phase, dx: dx, dy: dy, position: p))
}

func proximityEvent(_ tool: PenTool = .pen, entering: Bool) -> MacEvent { .tabletProximity(tool: tool, entering: entering) }

func mouseEvent(_ kind: MacMouse.Kind, _ button: MouseButton = .left, at p: DisplayPoint, delta: DisplayPoint = .zero,
                clickState: Int = 0) -> MacEvent {
    .mouse(MacMouse(kind: kind, button: button, position: p, deltaX: delta.x, deltaY: delta.y, clickState: clickState))
}

/// Independent model of the Mac built only from the `MacEvent` stream. Anything a real Mac could not have happen
/// (second down, up without down, drag without contact, ...) is a violation.
struct MacEventModel {
    var proximity: PenTool?
    var penContact = false
    var buttons: Set<MouseButton> = []
    var scrollOpen = false
    var magnifyOpen = false
    var keys: Set<UInt16> = []
    var modifiers: Set<ModifierKey> = []
    private(set) var violations: [String] = []

    var isIdle: Bool { proximity == nil && !penContact && buttons.isEmpty && !scrollOpen && !magnifyOpen && keys.isEmpty && modifiers.isEmpty }

    private mutating func fail(_ text: String, _ e: MacEvent) { violations.append("\(text): \(e)") }

    mutating func apply(_ events: [MacEvent]) { for e in events { apply(e) } }

    mutating func apply(_ event: MacEvent) {
        switch event {
        case .tabletProximity(let tool, let entering):
            if entering {
                if proximity != nil { fail("enter while in proximity", event) }
                proximity = tool
            } else {
                if proximity != tool { fail("leave without matching enter", event) }
                if penContact { fail("leave while touching", event) }
                proximity = nil
            }
        case .tabletPoint(let p):
            if proximity != p.tool { fail("tablet event outside proximity of its tool", event) }
            switch p.kind {
            case .hover:
                if penContact { fail("hover while touching", event) }
                if buttons.contains(.left) { fail("pen hover while a pointer owns the left button", event) }
                if p.pressure != 0 { fail("hover with pressure", event) }
            case .down:
                if penContact || buttons.contains(.left) { fail("pen down while left is down", event) }
                penContact = true
            case .drag:
                if !penContact { fail("drag without contact", event) }
            case .up:
                if !penContact { fail("up without contact", event) }
                if p.pressure != 0 { fail("up with pressure", event) }
                penContact = false
            }
        case .mouse(let m):
            switch m.kind {
            case .moved:
                if penContact { fail("mouse move during pen contact", event) }
            case .dragged:
                if !buttons.contains(m.button) { fail("drag of a button that is not down", event) }
            case .down:
                if buttons.contains(m.button) { fail("button already down", event) }
                if m.button == .left && penContact { fail("left down during pen contact", event) }
                if m.clickState < 1 { fail("down without a click count", event) }
                buttons.insert(m.button)
            case .up:
                if !buttons.contains(m.button) { fail("button up without down", event) }
                buttons.remove(m.button)
            }
        case .scroll(let s):
            switch s.phase {
            case .none: break
            case .began:
                if scrollOpen { fail("scroll began while open", event) }
                if magnifyOpen { fail("scroll began while a magnify gesture is open", event) }
                scrollOpen = true
            case .changed:
                if !scrollOpen { fail("scroll changed while closed", event) }
            case .ended, .cancelled:
                if !scrollOpen { fail("scroll end while closed", event) }
                scrollOpen = false
            }
        case .magnify(let g):
            switch g.phase {
            case .began:
                if magnifyOpen { fail("magnify began while open", event) }
                if scrollOpen { fail("magnify began while a scroll gesture is open", event) }
                if g.value != 0 { fail("magnify began with a value", event) }
                magnifyOpen = true
            case .changed:
                if !magnifyOpen { fail("magnify changed while closed", event) }
                if g.value == 0 { fail("zero magnify change reached the Mac", event) }
            case .ended:
                if !magnifyOpen { fail("magnify end while closed", event) }
                if g.value != 0 { fail("magnify end with a value", event) }
                magnifyOpen = false
            }
        case .capsLock:
            break
        case .key(let k):
            switch k.kind {
            case .keyDown:
                if k.isRepeat {
                    if !keys.contains(k.keyCode) { fail("repeat of a key that is not down", event) }
                } else {
                    if keys.contains(k.keyCode) { fail("key already down", event) }
                    keys.insert(k.keyCode)
                }
            case .keyUp:
                if !keys.contains(k.keyCode) { fail("key up without down", event) }
                keys.remove(k.keyCode)
            case .modifierDown:
                guard let m = ModifierKey(rawValue: k.keyCode) else { fail("not a modifier", event); return }
                if modifiers.contains(m) { fail("modifier already down", event) }
                modifiers.insert(m)
            case .modifierUp:
                guard let m = ModifierKey(rawValue: k.keyCode) else { fail("not a modifier", event); return }
                if !modifiers.contains(m) { fail("modifier up without down", event) }
                modifiers.remove(m)
            }
            // The flags are exactly the modifiers the Mac holds after the event (Caps Lock aside).
            var flags = k.flags
            flags.remove(.capsLock)
            if flags != KeyFlags(holding: modifiers) { fail("flags do not match the held modifiers", event) }
        }
    }
}

private func planOnce(_ planner: inout InjectionPlanner, _ actions: [InjectAction], _ env: InjectionEnvironment = openEnv,
                      now: UInt64 = 1_000_000) -> [MacEvent] {
    planner.plan(actions, environment: env, now: now)
}

@Suite("PLAN: pen events")
struct PlannerPenTests {
    @Test("PLAN-1 a whole pen stroke: enter, hover, down, drag, up, leave with converted positions, pressure and tilt")
    func plan1_stroke() {
        var p = InjectionPlanner()
        let events = planOnce(&p, [
            penEnter(), .penHover(tool: .pen, penPt(1000, 2000)),
            .penDown(tool: .pen, penPt(1010, 2010, 30000)),
            .penDrag(tool: .pen, penPt(1020, 2020, 40000)),
            .penUp(tool: .pen, penPt(1030, 2030)), penLeave(),
        ])
        #expect(events == [
            proximityEvent(entering: true),
            tabletEvent(.hover, x: 1000, y: 2000),
            tabletEvent(.down, x: 1010, y: 2010, pressure: 30000),
            tabletEvent(.drag, x: 1020, y: 2020, pressure: 40000),
            tabletEvent(.up, x: 1030, y: 2030),
            proximityEvent(entering: false),
        ])
        #expect(!p.isHoldingInput)
    }

    @Test("PLAN-2 positions are global points of the display (origin added), pressure 0...1, tilt -1...1")
    func plan2_units() {
        var p = InjectionPlanner()
        let point = PenPoint(x: 65535, y: 0, pressure: 65535, tiltX: 32767, tiltY: -32768)
        let events = planOnce(&p, [penEnter(), .penDown(tool: .pen, point)])
        guard case .tabletPoint(let down) = events[1] else { Issue.record("expected a tablet point"); return }
        #expect(down.position == DisplayPoint(x: 100 + 1399.5, y: 50))
        #expect(down.pressure == 1)
        #expect(down.tiltX == 1)
        #expect(down.tiltY == -1)  // -32768 counts as -32767
    }

    @Test("PLAN-3 the eraser tool is carried on the proximity and on every point")
    func plan3_eraser() {
        var p = InjectionPlanner()
        let events = planOnce(&p, [
            penEnter(.eraser), .penDown(tool: .eraser, penPt(5, 6, 100)), .penUp(tool: .eraser, penPt(5, 6)),
            penLeave(.eraser),
        ])
        #expect(events == [
            proximityEvent(.eraser, entering: true), tabletEvent(.down, .eraser, x: 5, y: 6, pressure: 100),
            tabletEvent(.up, .eraser, x: 5, y: 6), proximityEvent(.eraser, entering: false),
        ])
    }

    @Test("PLAN-4 a pen down is always click state 1, however fast the taps follow each other")
    func plan4_penClickState() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [penEnter()], now: 0)
        for i in 0..<3 {
            let now = UInt64(i) * 50_000
            let events = planOnce(&p, [.penDown(tool: .pen, penPt(1, 1, 500)), .penUp(tool: .pen, penPt(1, 1))], now: now)
            #expect(events == [tabletEvent(.down, x: 1, y: 1, pressure: 500), tabletEvent(.up, x: 1, y: 1)])
        }
    }

    @Test("PLAN-5 closing the pen while touching lifts it at the last pen position, then leaves")
    func plan5_closeWhileTouching() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [penEnter(), .penDown(tool: .pen, penPt(70, 80, 900))])
        let events = planOnce(&p, [penLeave()])
        guard case .tabletPoint(let up) = events[0] else { Issue.record("expected an up first"); return }
        #expect(up.kind == .up && up.pressure == 0 && up.position == testGeometry.point(x: 70, y: 80))
        #expect(events[1] == proximityEvent(entering: false))
        #expect(!p.isHoldingInput)
    }

    @Test("PLAN-6 a different tool entering while another is in range closes the old one first")
    func plan6_toolChange() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [penEnter(.pen), .penDown(tool: .pen, penPt(1, 1, 5))])
        let events = planOnce(&p, [penEnter(.eraser)])
        #expect(events.count == 3)
        #expect(events[1] == proximityEvent(.pen, entering: false))
        #expect(events[2] == proximityEvent(.eraser, entering: true))
        #expect(p.isPenInRange && !p.isPenInContact)
    }

    @Test("PLAN-7 a second enter for the same tool, or a second down while touching, is not posted twice")
    func plan7_duplicates() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [penEnter(), .penDown(tool: .pen, penPt(1, 1, 5))])
        #expect(planOnce(&p, [penEnter()]).isEmpty)
        #expect(planOnce(&p, [.penDown(tool: .pen, penPt(2, 2, 5))]).isEmpty)
        #expect(p.counters.droppedNotHeld == 1)
    }

    @Test("PLAN-8 a hover or down without a posted enter (the gate was closed) enters first, once")
    func plan8_autoEnter() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [penEnter()], noDisplayEnv)
        let hover = planOnce(&p, [.penHover(tool: .pen, penPt(3, 4))])
        #expect(hover == [proximityEvent(entering: true), tabletEvent(.hover, x: 3, y: 4)])
        #expect(planOnce(&p, [.penHover(tool: .pen, penPt(5, 6))]) == [tabletEvent(.hover, x: 5, y: 6)])

        var q = InjectionPlanner()
        let down = planOnce(&q, [.penDown(tool: .pen, penPt(3, 4, 700))])
        #expect(down == [proximityEvent(entering: true), tabletEvent(.down, x: 3, y: 4, pressure: 700)])
    }
    @Test("PLAN-9 the pen lifts (CONTACT 1->0) while the display or the permission is gone: the up is still posted, the pen stays in range")
    func plan9_upWithoutGate() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [penEnter(), .penDown(tool: .pen, penPt(70, 80, 900))])
        // No display: it lifts where it last was.
        #expect(planOnce(&p, [.penUp(tool: .pen, penPt(71, 81))], noDisplayEnv) == [tabletEvent(.up, x: 70, y: 80)])
        #expect(p.isPenInRange && !p.isPenInContact)

        var q = InjectionPlanner()
        _ = planOnce(&q, [penEnter(), .penDown(tool: .pen, penPt(70, 80, 900))])
        // No permission: the display is known, so it lifts at the position the sample says.
        #expect(planOnce(&q, [.penUp(tool: .pen, penPt(71, 81))], noPermissionEnv) == [tabletEvent(.up, x: 71, y: 81)])
        #expect(q.isPenInRange && !q.isPenInContact)
    }
}

@Suite("PLAN: mouse, touch and click state")
struct PlannerMouseTests {
    @Test("PLAN-10 an absolute move converts the position; a button applies at the last injected position")
    func plan10_buttonAtCursor() {
        var p = InjectionPlanner()
        let events = planOnce(&p, [moveAbs(500, 600), .mouseButton(.left, down: true)])
        let at = testGeometry.point(x: 500, y: 600)
        #expect(events == [mouseEvent(.moved, at: at), mouseEvent(.down, at: at, clickState: 1)])
        #expect(p.cursor == at)
        // A later release with no move in between happens where the cursor is.
        #expect(planOnce(&p, [.mouseButton(.left, down: false)]) == [mouseEvent(.up, at: at, clickState: 1)])
    }

    @Test("PLAN-11 the cursor also follows the pen, so a following button click is where the pen last was")
    func plan11_cursorFollowsPen() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [penEnter(), .penHover(tool: .pen, penPt(900, 800))])
        let events = planOnce(&p, [.mouseButton(.right, down: true)])
        #expect(events == [mouseEvent(.down, .right, at: testGeometry.point(x: 900, y: 800), clickState: 1)])
    }

    @Test("PLAN-12 dragging: a move while a button is held is that button's drag, with the movement as delta")
    func plan12_drag() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [moveAbs(500, 600), .mouseButton(.left, down: true)])
        let events = planOnce(&p, [moveAbs(510, 620, dragging: .left)])
        let a = testGeometry.point(x: 500, y: 600), b = testGeometry.point(x: 510, y: 620)
        #expect(events == [mouseEvent(.dragged, .left, at: b, delta: DisplayPoint(x: b.x - a.x, y: b.y - a.y))])
    }

    @Test("PLAN-13 a drag of a button whose down was never posted is a plain move")
    func plan13_dragWithoutDown() {
        var p = InjectionPlanner()
        let events = planOnce(&p, [moveAbs(500, 600, dragging: .left)])
        #expect(events == [mouseEvent(.moved, at: testGeometry.point(x: 500, y: 600))])
    }

    @Test("PLAN-14 relative movement starts at the display center, is clamped to the display and reports its delta")
    func plan14_relative() {
        var p = InjectionPlanner()
        let first = planOnce(&p, [.mouseMove(.relative(dx: 10, dy: -5), dragging: nil)])
        let c = testGeometry.center
        #expect(first == [mouseEvent(.moved, at: DisplayPoint(x: c.x + 10, y: c.y - 5), delta: DisplayPoint(x: 10, y: -5))])
        let second = planOnce(&p, [.mouseMove(.relative(dx: -100_000, dy: 100_000), dragging: nil)])
        guard case .mouse(let m) = second[0] else { Issue.record("expected a mouse event"); return }
        #expect(m.position == DisplayPoint(x: 100, y: 50 + 920 - 0.5))
        #expect(m.deltaX == 100 - (c.x + 10))
    }

    @Test("PLAN-15 double click: clicks close in time and place count up, and an up repeats its down's count")
    func plan15_doubleClick() {
        var p = InjectionPlanner()
        var states: [Int] = []
        var t: UInt64 = 1_000_000
        for _ in 0..<3 {
            let events = planOnce(&p, [moveAbs(500, 600), .mouseButton(.left, down: true), .mouseButton(.left, down: false)],
                                  now: t)
            for case .mouse(let m) in events where m.kind == .down || m.kind == .up { states.append(m.clickState) }
            t += 150_000
        }
        #expect(states == [1, 1, 2, 2, 3, 3])
    }

    @Test("PLAN-16 too slow, too far, or after a release-all: back to a single click")
    func plan16_singleClicks() {
        var p = InjectionPlanner()
        func click(_ x: UInt16, at t: UInt64) -> Int {
            let events = planOnce(&p, [moveAbs(x, 600), .mouseButton(.left, down: true), .mouseButton(.left, down: false)], now: t)
            for case .mouse(let m) in events where m.kind == .down { return m.clickState }
            return -1
        }
        #expect(click(500, at: 0) == 1)
        #expect(click(500, at: 600_000) == 1)      // 600 ms later
        #expect(click(20_000, at: 700_000) == 1)   // far away
        #expect(click(20_000, at: 800_000) == 2)
        _ = p.releaseAll(environment: openEnv)
        #expect(click(20_000, at: 850_000) == 1)   // history cleared
    }

    @Test("PLAN-17 the same button is not pressed twice; an up for a button that is not held is dropped")
    func plan17_buttonDuplicates() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [moveAbs(1, 1), .mouseButton(.right, down: true)])
        #expect(planOnce(&p, [.mouseButton(.right, down: true)]).isEmpty)
        #expect(planOnce(&p, [.mouseButton(.middle, down: false)]).isEmpty)
        #expect(p.heldMouseButtons == [.right])
    }

    @Test("PLAN-18 pen priority: the machine's up on behalf of the pointer then the pen down keep left exclusive")
    func plan18_penPriority() {
        var p = InjectionPlanner()
        var model = MacEventModel()
        model.apply(planOnce(&p, [moveAbs(500, 600), .mouseButton(.left, down: true)]))
        model.apply(planOnce(&p, [penEnter(), .mouseButton(.left, down: false), .penDown(tool: .pen, penPt(1, 1, 50))]))
        #expect(model.violations.isEmpty)
        #expect(model.penContact && model.buttons.isEmpty)
    }
}

@Suite("PLAN: gating, shadow state and release")
struct PlannerGateTests {
    private let openingActions: [InjectAction] = [
        penEnter(), .penHover(tool: .pen, penPt(1, 1)), .penDown(tool: .pen, penPt(1, 1, 10)),
        moveAbs(1, 1), .mouseMove(.relative(dx: 1, dy: 1), dragging: nil), .mouseButton(.left, down: true),
        .scroll(.began, dx: 1, dy: 1), .scrollWheel(dx: 20, dy: 20),
    ]

    @Test("PLAN-20 without a virtual display every opening action is dropped and counted; nothing is held")
    func plan20_noDisplay() {
        var p = InjectionPlanner()
        #expect(planOnce(&p, openingActions, noDisplayEnv).isEmpty)
        #expect(!p.isHoldingInput)
        #expect(p.counters.droppedNoDisplay == openingActions.count)
        #expect(p.counters.droppedNoPermission == 0)
        #expect(p.counters.events == 0)
    }

    @Test("PLAN-21 without Accessibility permission every opening action is dropped and counted; nothing is held")
    func plan21_noPermission() {
        var p = InjectionPlanner()
        #expect(planOnce(&p, openingActions, noPermissionEnv).isEmpty)
        #expect(!p.isHoldingInput)
        #expect(p.counters.droppedNoPermission == openingActions.count)
        var q = InjectionPlanner()
        #expect(planOnce(&q, openingActions, closedEnv).isEmpty)  // permission is checked first
        #expect(q.counters.droppedNoPermission == openingActions.count)
    }

    @Test("PLAN-22 when the opening was dropped, the continuing and closing actions of that stroke are dropped too")
    func plan22_orphans() {
        var p = InjectionPlanner()
        let events = planOnce(&p, [
            penEnter(), .penDown(tool: .pen, penPt(1, 1, 10)), .penDrag(tool: .pen, penPt(2, 2, 10)),
            .penUp(tool: .pen, penPt(3, 3)), penLeave(),
            moveAbs(4, 4), .mouseButton(.left, down: true), moveAbs(5, 5, dragging: .left),
            .mouseButton(.left, down: false),
            .scroll(.began, dx: 1, dy: 1), .scroll(.changed, dx: 1, dy: 1), .scroll(.ended, dx: 0, dy: 0),
        ], noDisplayEnv)
        #expect(events.isEmpty)
        // Now the gate opens in the middle of all of that: none of it may leak out half-way.
        var q = InjectionPlanner()
        _ = planOnce(&q, [penEnter(), .penDown(tool: .pen, penPt(1, 1, 10))], noDisplayEnv)
        let later = planOnce(&q, [.penDrag(tool: .pen, penPt(2, 2, 10)), .penUp(tool: .pen, penPt(3, 3)), penLeave()])
        #expect(later.isEmpty)
        #expect(!q.isHoldingInput)
    }

    @Test("PLAN-23 the display disappears mid stroke: drags are dropped, but the up and the leave are still posted")
    func plan23_displayLostMidStroke() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [penEnter(), .penDown(tool: .pen, penPt(70, 80, 900)), .penDrag(tool: .pen, penPt(71, 81, 900))])
        #expect(planOnce(&p, [.penDrag(tool: .pen, penPt(72, 82, 900))], noDisplayEnv).isEmpty)
        let events = planOnce(&p, [.penUp(tool: .pen, penPt(73, 83)), penLeave()], noDisplayEnv)
        // Without a display the pen lifts where it last was (the last posted drag).
        #expect(events == [tabletEvent(.up, x: 71, y: 81), proximityEvent(entering: false)])
        #expect(!p.isHoldingInput)
    }

    @Test("PLAN-24 permission is lost mid hold: the button up and the scroll end are still produced")
    func plan24_permissionLostMidHold() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [moveAbs(500, 600), .mouseButton(.left, down: true), .scroll(.began, dx: 0, dy: 3)])
        #expect(planOnce(&p, [moveAbs(510, 610, dragging: .left), .scroll(.changed, dx: 0, dy: 3)], noPermissionEnv).isEmpty)
        let events = planOnce(&p, [.mouseButton(.left, down: false), .scroll(.ended, dx: 0, dy: 2)], noPermissionEnv)
        #expect(events == [mouseEvent(.up, at: testGeometry.point(x: 500, y: 600), clickState: 1),
                           scrollEvent(.ended, at: testGeometry.point(x: 500, y: 600))])
        #expect(!p.isHoldingInput)
    }

    @Test("PLAN-25 releaseAll: contact up, left up, leave, other buttons up, scroll end; then idle; idempotent")
    func plan25_releaseAll() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [moveAbs(500, 600), .mouseButton(.right, down: true), .mouseButton(.back, down: true),
                          .scroll(.began, dx: 0, dy: 1)])
        _ = planOnce(&p, [penEnter(), .penDown(tool: .pen, penPt(9, 9, 100))])
        let at = testGeometry.point(x: 9, y: 9)
        let events = p.releaseAll(environment: openEnv)
        #expect(events == [
            tabletEvent(.up, x: 9, y: 9), proximityEvent(entering: false),
            mouseEvent(.up, .right, at: at, clickState: 1), mouseEvent(.up, .back, at: at, clickState: 1),
            scrollEvent(.ended, at: at),
        ])
        #expect(!p.isHoldingInput)
        #expect(p.releaseAll(environment: openEnv).isEmpty)
    }

    @Test("PLAN-26 releaseAll releases a pointer-held left button before the pen leaves")
    func plan26_releaseAllLeftFirst() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [penEnter(), .penHover(tool: .pen, penPt(1, 1))])
        _ = planOnce(&p, [.mouseButton(.left, down: true)])
        let events = p.releaseAll(environment: openEnv)
        #expect(events.count == 2)
        guard case .mouse(let up) = events[0] else { Issue.record("expected the left up first"); return }
        #expect(up.kind == .up && up.button == .left)
        #expect(events[1] == proximityEvent(entering: false))
    }

    @Test("PLAN-27 the gate opening later lets the next stroke through cleanly")
    func plan27_gateReopens() {
        var p = InjectionPlanner()
        var model = MacEventModel()
        model.apply(planOnce(&p, [penEnter(), .penDown(tool: .pen, penPt(1, 1, 10))], noPermissionEnv))
        #expect(model.isIdle)
        model.apply(planOnce(&p, [.penUp(tool: .pen, penPt(1, 1)), .penHover(tool: .pen, penPt(2, 2))]))
        model.apply(planOnce(&p, [.penDown(tool: .pen, penPt(3, 3, 10)), .penUp(tool: .pen, penPt(3, 3))]))
        #expect(model.violations.isEmpty)
        #expect(model.proximity == .pen && !model.penContact)
    }
}

@Suite("PLAN: the shadow state follows what was really posted")
struct PlannerNotPostedTests {
    @Test("PLAN-50 opening events that were not posted are forgotten; closing ones are not touched")
    func plan50_notPosted() {
        var p = InjectionPlanner()
        let events = planOnce(&p, [penEnter(), .penDown(tool: .pen, penPt(1, 1, 200)), moveAbs(5, 5), .mouseButton(.right, down: true),
                                   .scroll(.began, dx: 0, dy: 1)])
        #expect(p.isPenInRange && p.isPenInContact && p.heldMouseButtons == [.right] && p.isScrollOpen)
        p.notPosted(events)
        #expect(!p.isHoldingInput)  // none of it reached the Mac

        // A release that failed was already released in the shadow state: reporting it changes nothing.
        var q = InjectionPlanner()
        _ = planOnce(&q, [penEnter(), .penDown(tool: .pen, penPt(1, 1, 200))])
        let up = planOnce(&q, [.penUp(tool: .pen, penPt(1, 1)), penLeave()])
        q.notPosted(up)
        #expect(!q.isHoldingInput)
    }

    @Test("PLAN-51 after a failed press the machine's later samples of that stroke draw nothing")
    func plan51_restOfStrokeDropped() {
        var p = InjectionPlanner()
        p.notPosted(planOnce(&p, [penEnter(), .penDown(tool: .pen, penPt(1, 1, 200))]))
        #expect(planOnce(&p, [.penDrag(tool: .pen, penPt(2, 2, 200))]).isEmpty)
        #expect(planOnce(&p, [.penUp(tool: .pen, penPt(3, 3))]).isEmpty)
        // The next hover enters again.
        #expect(planOnce(&p, [.penHover(tool: .pen, penPt(4, 4))]) == [proximityEvent(entering: true), tabletEvent(.hover, x: 4, y: 4)])
    }
}

@Suite("PLAN: scroll")
struct PlannerScrollTests {
    private func scroll(_ phase: MacScroll.Phase, _ dx: Int32 = 0, _ dy: Int32 = 0) -> MacEvent {
        scrollEvent(phase, dx, dy)
    }

    @Test("PLAN-30 a gesture: began, changed, ended in pixel units, no momentum")
    func plan30_gesture() {
        var p = InjectionPlanner()
        let events = planOnce(&p, [.scroll(.began, dx: 0, dy: 4), .scroll(.changed, dx: 2, dy: 6),
                                   .scroll(.ended, dx: 0, dy: 1)])
        #expect(events == [scroll(.began, 0, 4), scroll(.changed, 2, 6), scroll(.ended, 0, 1)])
        #expect(!p.isScrollOpen)
    }

    @Test("PLAN-31 zero-delta CHANGED (the client's keepalive) is never injected, and keeps the gesture open")
    func plan31_keepalive() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [.scroll(.began, dx: 0, dy: 4)])
        for _ in 0..<5 { #expect(planOnce(&p, [.scroll(.changed, dx: 0, dy: 0)]).isEmpty) }
        #expect(p.counters.droppedKeepalive == 5)
        #expect(p.isScrollOpen)
    }

    @Test("PLAN-32 a forced end reaches the Mac as ENDED with no movement, and no momentum event follows")
    func plan32_forcedEnd() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [.scroll(.began, dx: 0, dy: 4), .scroll(.changed, dx: 0, dy: 9)])
        let events = planOnce(&p, [.scroll(.forcedEnd, dx: 0, dy: 0)])
        #expect(events == [scroll(.ended, 0, 0)])
        #expect(!p.isScrollOpen)
        #expect(planOnce(&p, [.scroll(.forcedEnd, dx: 0, dy: 0)]).isEmpty)
    }

    @Test("PLAN-33 a client CANCELLED reaches the Mac as cancelled")
    func plan33_cancelled() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [.scroll(.began, dx: 0, dy: 4)])
        #expect(planOnce(&p, [.scroll(.cancelled, dx: 0, dy: 0)]) == [scroll(.cancelled, 0, 0)])
    }

    @Test("PLAN-34 fractions below one pixel are carried over instead of lost")
    func plan34_carry() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [.scroll(.began, dx: 0, dy: 0)])
        var total: Int32 = 0
        var events = 0
        for _ in 0..<10 {
            for case .scroll(let s) in planOnce(&p, [.scroll(.changed, dx: 0, dy: 0.3)]) {
                total += s.dy
                events += 1
            }
        }
        #expect(total == 3)   // 10 x 0.3
        #expect(events == 3)  // the sub-pixel steps produced no event of their own
    }

    @Test("PLAN-34b the horizontal remainder is carried over as well")
    func plan34b_carryX() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [.scroll(.began, dx: 0, dy: 0)])
        var total: Int32 = 0
        for _ in 0..<10 {
            for case .scroll(let s) in planOnce(&p, [.scroll(.changed, dx: -0.3, dy: 0)]) { total += s.dx }
        }
        #expect(total == -3)
    }

    @Test("PLAN-35 CHANGED without an open gesture is dropped; BEGAN over an open one ends the old one first")
    func plan35_orderRules() {
        var p = InjectionPlanner()
        #expect(planOnce(&p, [.scroll(.changed, dx: 1, dy: 1), .scroll(.ended, dx: 0, dy: 0)]).isEmpty)
        _ = planOnce(&p, [.scroll(.began, dx: 0, dy: 1)])
        #expect(planOnce(&p, [.scroll(.began, dx: 0, dy: 2)]) == [scroll(.ended), scroll(.began, 0, 2)])
    }

    @Test("PLAN-36 a wheel step is a single event without a gesture; sub-pixel or zero steps are dropped")
    func plan36_wheel() {
        var p = InjectionPlanner()
        #expect(planOnce(&p, [.scrollWheel(dx: 0, dy: 10)]) == [scroll(.none, 0, 10)])
        #expect(planOnce(&p, [.scrollWheel(dx: -10, dy: 0)]) == [scroll(.none, -10, 0)])
        #expect(planOnce(&p, [.scrollWheel(dx: 0, dy: 0)]).isEmpty)
        #expect(!p.isHoldingInput)
    }

    @Test("PLAN-37 the end of a gesture is posted without permission, but its last movement is not")
    func plan37_endWithoutPermission() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [.scroll(.began, dx: 0, dy: 1)])
        #expect(planOnce(&p, [.scroll(.ended, dx: 5, dy: 5)], noPermissionEnv) == [scroll(.ended, 0, 0)])
    }
}

@Suite("PLAN: positions follow the current display")
struct PlannerGeometryChangeTests {
    /// The display came back at another origin (negative y) and a smaller size, scale 1.
    private let moved = DisplayGeometry(originX: 2000, originY: -300, widthPt: 700, heightPt: 460, scale: 1)!
    private var movedEnv: InjectionEnvironment { InjectionEnvironment(canInject: true, geometry: moved) }

    @Test("PLAN-40 a button-only press after the display came back elsewhere hits the middle of the new display, not the old point")
    func plan40_buttonAfterChange() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [moveAbs(500, 600)])  // the cached cursor is on the old display
        let events = planOnce(&p, [.mouseButton(.left, down: true)], movedEnv)
        #expect(events == [mouseEvent(.down, at: moved.center, clickState: 1)])
        #expect(p.cursor == moved.center)
    }

    @Test("PLAN-41 relative movement and an absolute move's delta start from the new display, not from the stale cursor")
    func plan41_moveAfterChange() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [moveAbs(500, 600)])
        let relative = planOnce(&p, [.mouseMove(.relative(dx: 10, dy: -5), dragging: nil)], movedEnv)
        let c = moved.center
        #expect(relative == [mouseEvent(.moved, at: DisplayPoint(x: c.x + 10, y: c.y - 5), delta: DisplayPoint(x: 10, y: -5))])

        var q = InjectionPlanner()
        _ = planOnce(&q, [moveAbs(500, 600)])
        let absolute = planOnce(&q, [moveAbs(0, 0)], movedEnv)
        #expect(absolute == [mouseEvent(.moved, at: DisplayPoint(x: 2000, y: -300))])  // no delta from a point on another display
    }

    @Test("PLAN-42 a release after the change is inside the new display; with no display it is where the button went down")
    func plan42_releaseAfterChange() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [moveAbs(500, 600), .mouseButton(.right, down: true)])
        #expect(planOnce(&p, [.mouseButton(.right, down: false)], movedEnv) == [mouseEvent(.up, .right, at: moved.center, clickState: 1)])

        var q = InjectionPlanner()
        _ = planOnce(&q, [moveAbs(500, 600), .mouseButton(.right, down: true)])
        let at = testGeometry.point(x: 500, y: 600)
        #expect(planOnce(&q, [.mouseButton(.right, down: false)], noDisplayEnv) == [mouseEvent(.up, .right, at: at, clickState: 1)])
    }

    @Test("PLAN-43 a pen lifted or released after the change lifts inside the new display")
    func plan43_penAfterChange() {
        var p = InjectionPlanner()
        _ = planOnce(&p, [penEnter(), .penDown(tool: .pen, penPt(70, 80, 900))])
        guard case .tabletPoint(let up) = p.releaseAll(environment: movedEnv)[0] else { Issue.record("expected the up first"); return }
        #expect(up.kind == .up && up.position == moved.center)

        var q = InjectionPlanner()
        _ = planOnce(&q, [penEnter(), .penDown(tool: .pen, penPt(70, 80, 900))])
        let events = planOnce(&q, [penLeave()], movedEnv)
        guard case .tabletPoint(let lift) = events[0] else { Issue.record("expected the up first"); return }
        #expect(lift.position == moved.center)
    }

    @Test("PLAN-44 a cached cursor that is still on the display is kept")
    func plan44_stillValid() {
        // An origin change that keeps the old point inside: same size, shifted by a few points.
        let shifted = DisplayGeometry(originX: 90, originY: 40, widthPt: 1400, heightPt: 920, scale: 2)!
        var p = InjectionPlanner()
        _ = planOnce(&p, [moveAbs(500, 600)])
        let old = testGeometry.point(x: 500, y: 600)
        #expect(shifted.contains(old))
        let events = planOnce(&p, [.mouseButton(.left, down: true)], InjectionEnvironment(canInject: true, geometry: shifted))
        #expect(events == [mouseEvent(.down, at: old, clickState: 1)])
    }

    @Test("PLAN-45 scroll events are located on the display: the cursor while valid, the center otherwise, the last place without a display")
    func plan45_scrollPositions() {
        var p = InjectionPlanner()
        #expect(planOnce(&p, [.scroll(.began, dx: 0, dy: 3)]) == [scrollEvent(.began, 0, 3, at: testGeometry.center)])
        _ = planOnce(&p, [.scroll(.ended, dx: 0, dy: 0)])

        _ = planOnce(&p, [moveAbs(500, 600)])
        let at = testGeometry.point(x: 500, y: 600)
        #expect(planOnce(&p, [.scroll(.began, dx: 0, dy: 3)]) == [scrollEvent(.began, 0, 3, at: at)])
        #expect(planOnce(&p, [.scrollWheel(dx: 0, dy: 10)]) == [scrollEvent(.none, 0, 10, at: at)])
        // The display comes back elsewhere while the gesture is open: the next step is on the new display.
        #expect(planOnce(&p, [.scroll(.changed, dx: 0, dy: 4)], movedEnv) == [scrollEvent(.changed, 0, 4, at: moved.center)])
        #expect(planOnce(&p, [.scrollWheel(dx: 0, dy: 10)], movedEnv) == [scrollEvent(.none, 0, 10, at: moved.center)])
        // No display: only the closing event, at the last known place.
        #expect(planOnce(&p, [.scroll(.ended, dx: 0, dy: 0)], noDisplayEnv) == [scrollEvent(.ended, at: moved.center)])
    }
}
