import Testing
@testable import MateBridgeCore

// PIPE-*: session lifecycle and release-all through the whole chain (state machine -> planner), one test per
// PROTOCOL.md section 7 trigger, with the display gone and with the permission missing or revoked.
//
// Trigger -> test map (the Host maps each trigger to `InputController.releaseInput(cause)` / `shutdown()`; that
// mapping is in the Host shell and is not unit-testable, see the T-023 handoff):
//   RELEASE_ALL message   PIPE-2 (`.clientRequest`), PIPE-3
//   BYE (either way)      PIPE-2 (`.bye`), PIPE-3
//   connection loss       PIPE-2 (`.disconnected`)
//   protocol error        PIPE-2 (`.protocolError`)
//   heartbeat silence     PIPE-2 (`.silence`), PIPE-2 (`.timeout`)
//   session takeover      PIPE-9 (`.superseded`, then the next session starts fresh)
//   app shutdown          PIPE-2 (`.shutdown`), PIPE-11
//   display gone          PIPE-4, PIPE-7, PIPE-16     permission missing/revoked   PIPE-5, PIPE-6

/// Where an event is located, if it has a position.
func eventPosition(_ e: MacEvent) -> DisplayPoint? {
    switch e {
    case .tabletProximity: nil
    case .tabletPoint(let p): p.position
    case .mouse(let m): m.position
    case .scroll(let s): s.position
    }
}

/// A pipeline plus a clock, an environment the test changes at will, and an independent model of the Mac.
struct PipeDriver {
    var pipe = InputPipeline()
    var now: UInt64 = 10_000_000
    var env = openEnv
    var model = MacEventModel()
    /// What the most recent call produced.
    var lastEmitted: [MacEvent] = []

    init(session: Bool = true) {
        if session { model.apply(pipe.sessionStarted(environment: env)) }
    }

    @discardableResult
    mutating func send(_ message: Message, after: UInt64 = 1 * msec) -> [MacEvent] {
        now += after
        let events = pipe.handle(message, now: now, environment: env)
        model.apply(events)
        lastEmitted = events
        return events
    }

    @discardableResult
    mutating func tick(after: UInt64) -> [MacEvent] {
        now += after
        let events = pipe.tick(now: now, environment: env)
        model.apply(events)
        lastEmitted = events
        return events
    }

    @discardableResult
    mutating func release(_ cause: ReleaseCause) -> [MacEvent] {
        let events = pipe.release(cause, now: now, environment: env)
        model.apply(events)
        lastEmitted = events
        return events
    }

    @discardableResult
    mutating func endSession() -> [MacEvent] {
        let events = pipe.sessionEnded(now: now, environment: env)
        model.apply(events)
        lastEmitted = events
        return events
    }

    @discardableResult
    mutating func startSession() -> [MacEvent] {
        let events = pipe.sessionStarted(environment: env)
        model.apply(events)
        lastEmitted = events
        return events
    }

    @discardableResult
    mutating func shutdown() -> [MacEvent] {
        let events = pipe.shutdown(now: now, environment: env)
        model.apply(events)
        lastEmitted = events
        return events
    }

    /// Pen touching + right button + an open scroll gesture: three kinds of held state.
    mutating func holdPenRightScroll() {
        send(penMsg(.pen, penSample(1000, 2000, hoverFlags)))
        send(penMsg(.pen, penSample(1010, 2010, startFlags, pressure: 500)))
        send(relMsg(0, 0, .right))
        send(scrollMsg(.began, 0, 3))
        precondition(model.penContact && model.buttons == [.right] && model.scrollOpen && model.proximity == .pen)
    }

    /// A mouse holding the left button + the middle button + an open scroll gesture, pen hovering.
    mutating func holdMouseMiddleScroll() {
        send(absMsg(.mouse, 500, 600, [.left, .middle]))
        send(scrollMsg(.began, 0, 3))
        precondition(model.buttons == [.left, .middle] && model.scrollOpen)
    }
}

@Suite("PIPE: session lifecycle and release-all")
struct InputPipelineTests {
    @Test("PIPE-1 a new session starts with a fresh, latched machine: a stale mid-stroke sample is only a hover")
    func pipe1_freshLatched() {
        var d = PipeDriver()
        let events = d.send(penMsg(.pen, penSample(1, 1, touchFlags, pressure: 300)))
        #expect(events == [proximityEvent(entering: true), tabletEvent(.hover, x: 1, y: 1)])
        #expect(d.model.violations.isEmpty && !d.model.penContact)
        // STROKE_START begins the stroke at once.
        let start = d.send(penMsg(.pen, penSample(2, 2, startFlags, pressure: 400)))
        #expect(start == [tabletEvent(.down, x: 2, y: 2, pressure: 400)])
    }

    @Test("PIPE-2 every release cause releases pen, buttons and scroll, once (idempotent)", arguments: allReleaseCauses)
    func pipe2_everyCause(_ cause: ReleaseCause) {
        var d = PipeDriver()
        d.holdPenRightScroll()
        let events = d.release(cause)
        #expect(!events.isEmpty)
        #expect(d.model.isIdle && d.model.violations.isEmpty)
        #expect(!d.pipe.isHoldingInput)
        #expect(d.pipe.lastReleaseCause == cause)
        #expect(d.release(cause).isEmpty)

        var m = PipeDriver()
        m.holdMouseMiddleScroll()
        m.release(cause)
        #expect(m.model.isIdle && m.model.violations.isEmpty && !m.pipe.isHoldingInput)
    }

    @Test("PIPE-3 RELEASE_ALL and BYE messages that reach the pipeline release everything as well")
    func pipe3_messages() {
        for message in [Message.releaseAll(.background), .releaseAll(.deviceDetached), .bye(.normal)] {
            var d = PipeDriver()
            d.holdPenRightScroll()
            let events = d.send(message)
            #expect(!events.isEmpty)
            #expect(d.model.isIdle && d.model.violations.isEmpty && !d.pipe.isHoldingInput)
        }
    }

    @Test("PIPE-4 the virtual display is gone: release-all still posts every up and the leave, where the pen was")
    func pipe4_releaseWithoutDisplay() {
        var d = PipeDriver()
        d.holdPenRightScroll()
        d.env = noDisplayEnv
        let events = d.release(.silence)
        let penAt = testGeometry.point(x: 1010, y: 2010)
        #expect(events.first == tabletEvent(.up, x: 1010, y: 2010))
        #expect(events.contains(proximityEvent(entering: false)))
        #expect(events.contains(mouseEvent(.up, .right, at: penAt, clickState: 1)))
        #expect(events.last == scrollEvent(.ended, at: penAt))
        #expect(d.model.isIdle && d.model.violations.isEmpty && !d.pipe.isHoldingInput)
    }

    @Test("PIPE-5 Accessibility permission missing at release time: the events are still produced and the state cleared")
    func pipe5_releaseWithoutPermission() {
        var d = PipeDriver()
        d.holdPenRightScroll()
        d.env = noPermissionEnv
        #expect(d.release(.bye).count == 4)  // up, leave, right up, scroll end
        #expect(d.model.isIdle && d.model.violations.isEmpty && !d.pipe.isHoldingInput)

        var m = PipeDriver()
        m.holdMouseMiddleScroll()
        m.env = closedEnv
        m.release(.disconnected)
        #expect(m.model.isIdle && !m.pipe.isHoldingInput)
    }

    @Test("PIPE-6 permission revoked mid stroke: the next message releases first, then input is dropped; a stale sample after the grant is a hover")
    func pipe6_permissionRevokedMidStroke() {
        var d = PipeDriver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        d.send(penMsg(.pen, penSample(2, 2, startFlags, pressure: 400)))
        d.env = noPermissionEnv
        let events = d.send(penMsg(.pen, penSample(3, 3, touchFlags, pressure: 500)))
        #expect(events == [tabletEvent(.up, x: 2, y: 2), proximityEvent(entering: false)])
        // The machine follows the tablet (the pen hovers again there), but nothing is held on the Mac.
        #expect(d.model.isIdle && !d.pipe.planner.isHoldingInput)
        #expect(d.send(penMsg(.pen, penSample(4, 4, touchFlags, pressure: 500))).isEmpty)

        d.env = openEnv  // granted again, the stroke is still going on in the tablet's samples
        let stale = d.send(penMsg(.pen, penSample(5, 5, touchFlags, pressure: 500)))
        #expect(stale == [proximityEvent(entering: true), tabletEvent(.hover, x: 5, y: 5)])
        #expect(!d.model.penContact)
        #expect(d.send(penMsg(.pen, penSample(6, 6, startFlags, pressure: 500))) == [tabletEvent(.down, x: 6, y: 6, pressure: 500)])
        #expect(d.model.violations.isEmpty)
    }

    @Test("PIPE-7 the display disappears while the pen touches: the next watchdog tick releases it")
    func pipe7_displayLostThenTick() {
        var d = PipeDriver()
        d.send(penMsg(.pen, penSample(7, 8, hoverFlags)))
        d.send(penMsg(.pen, penSample(9, 10, startFlags, pressure: 300)))
        d.env = noDisplayEnv
        let events = d.tick(after: 1 * msec)
        #expect(events == [tabletEvent(.up, x: 9, y: 10), proximityEvent(entering: false)])
        #expect(d.model.isIdle && !d.pipe.isHoldingInput)
        #expect(d.tick(after: 5_000 * msec).isEmpty)
    }

    @Test("PIPE-8 the pen watchdog runs through the pipeline, exactly at nextDeadline")
    func pipe8_watchdog() {
        var d = PipeDriver()
        #expect(d.pipe.nextDeadline(now: d.now) == nil)
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        let deadline = d.pipe.nextDeadline(now: d.now)
        #expect(deadline == d.now + 500_000)
        d.now = deadline! - 1
        #expect(d.pipe.tick(now: d.now, environment: d.env).isEmpty)
        d.now = deadline!
        let events = d.pipe.tick(now: d.now, environment: d.env)
        d.model.apply(events)
        #expect(events == [proximityEvent(entering: false)])
        #expect(d.model.isIdle)
        #expect(d.pipe.nextDeadline(now: d.now) == nil)
    }

    @Test("PIPE-9 takeover: the old session is released first; the new one starts with a fresh machine (no eraser mode, latched)")
    func pipe9_takeover() {
        var d = PipeDriver()
        d.send(doubleTap)
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        d.send(penMsg(.pen, penSample(2, 2, startFlags, pressure: 400)))
        #expect(d.pipe.machine?.isEraserMode == true && d.model.proximity == .eraser && d.model.penContact)

        // The order SessionMachine produces: releaseInput(.superseded), ..., sessionEnded, then sessionStarted.
        d.release(.superseded)
        #expect(d.model.isIdle)
        d.endSession()
        #expect(!d.pipe.hasSession)
        d.startSession()
        #expect(d.pipe.machine?.isEraserMode == false)

        let events = d.send(penMsg(.pen, penSample(3, 3, touchFlags, pressure: 400)))
        #expect(events == [proximityEvent(.pen, entering: true), tabletEvent(.hover, .pen, x: 3, y: 3)])  // latched: no down
        #expect(d.model.violations.isEmpty)
    }

    @Test("PIPE-10 a session that ends without an explicit release still releases everything; input after that is ignored")
    func pipe10_sessionEnded() {
        var d = PipeDriver()
        d.holdPenRightScroll()
        let events = d.endSession()
        #expect(!events.isEmpty)
        #expect(d.model.isIdle && !d.pipe.hasSession && !d.pipe.isHoldingInput)
        #expect(d.send(penMsg(.pen, penSample(1, 1, hoverFlags))).isEmpty)
        #expect(d.tick(after: 5_000 * msec).isEmpty)
        #expect(d.pipe.nextDeadline(now: d.now) == nil)
    }

    @Test("PIPE-11 app shutdown releases everything, ends the session, and is idempotent")
    func pipe11_shutdown() {
        var d = PipeDriver()
        d.holdPenRightScroll()
        #expect(!d.shutdown().isEmpty)
        #expect(d.model.isIdle && !d.pipe.hasSession && !d.pipe.isHoldingInput)
        #expect(d.pipe.lastReleaseCause == .shutdown)
        #expect(d.shutdown().isEmpty)
    }

    @Test("PIPE-12 a session start while something is still held releases the leftovers and starts fresh")
    func pipe12_startReleasesLeftovers() {
        var d = PipeDriver()
        d.holdPenRightScroll()
        let events = d.startSession()
        #expect(!events.isEmpty)
        #expect(d.model.isIdle && d.model.violations.isEmpty && !d.pipe.isHoldingInput)
        #expect(d.pipe.machine?.hasHeldInput == false)
    }

    @Test("PIPE-13 without a session nothing is handled, ticked or released")
    func pipe13_noSession() {
        var d = PipeDriver(session: false)
        #expect(d.send(penMsg(.pen, penSample(1, 1, hoverFlags))).isEmpty)
        #expect(d.send(relMsg(0, 0, .left)).isEmpty)
        #expect(d.tick(after: 1_000 * msec).isEmpty)
        #expect(d.release(.shutdown).isEmpty)
        #expect(d.pipe.nextDeadline(now: d.now) == nil)
    }

    @Test("PIPE-14 input that arrives before the display exists is ignored; the pen appears once it does")
    func pipe14_displayAppearsLater() {
        var d = PipeDriver()
        d.env = noDisplayEnv
        #expect(d.send(penMsg(.pen, penSample(1, 1, hoverFlags))).isEmpty)
        #expect(d.send(absMsg(.touch, 5, 5, .left)).isEmpty)
        #expect(d.send(absMsg(.touch, 5, 5, [])).isEmpty)
        d.env = openEnv
        let events = d.send(penMsg(.pen, penSample(2, 2, hoverFlags)))
        #expect(events == [proximityEvent(entering: true), tabletEvent(.hover, x: 2, y: 2)])
    }

    @Test("PIPE-15 a touch tap through the pipeline: move, down, (drag), up at the finger position, click state 1; a second tap is 2")
    func pipe15_touchTap() {
        var d = PipeDriver()
        let down = d.send(absMsg(.touch, 700, 800, .left))
        let at = testGeometry.point(x: 700, y: 800)
        #expect(down == [mouseEvent(.moved, at: at), mouseEvent(.down, at: at, clickState: 1)])
        let up = d.send(absMsg(.touch, 700, 800, []))
        #expect(up == [mouseEvent(.dragged, .left, at: at), mouseEvent(.up, at: at, clickState: 1)])
        // A second tap at the same place 150 ms later is a double click.
        let again = d.send(absMsg(.touch, 700, 800, .left), after: 150 * msec)
        #expect(again.last == mouseEvent(.down, at: at, clickState: 2))
        #expect(d.send(absMsg(.touch, 700, 800, [])).last == mouseEvent(.up, at: at, clickState: 2))
        #expect(d.model.violations.isEmpty && d.model.isIdle)
    }

    @Test("PIPE-16 the display goes away while the pen only hovers: the leave is posted at once, and it comes back cleanly")
    func pipe16_displayLostWhileHovering() {
        var d = PipeDriver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        d.env = noDisplayEnv
        #expect(d.send(penMsg(.pen, penSample(2, 2, hoverFlags))) == [proximityEvent(entering: false)])
        d.env = openEnv
        #expect(d.send(penMsg(.pen, penSample(3, 3, hoverFlags))) == [proximityEvent(entering: true), tabletEvent(.hover, x: 3, y: 3)])
        #expect(d.model.violations.isEmpty)
    }

    @Test("PIPE-18 safety net: whatever the planner holds and the machine does not is released (fault injection)")
    func pipe18_safetyNet() {
        // A left button the machine knows nothing about, pressed behind its back.
        func injectLeftDown(_ d: inout PipeDriver) {
            d.model.apply(d.pipe.planner.plan([moveAbs(5, 5), .mouseButton(.left, down: true)], environment: openEnv, now: d.now))
            precondition(d.pipe.planner.isHoldingInput && d.pipe.machine?.hasHeldInput == false)
        }

        var a = PipeDriver()
        injectLeftDown(&a)
        let events = a.send(.ping(Ping(seq: 1, senderTimeUs: 0)))
        #expect(events == [mouseEvent(.up, at: testGeometry.point(x: 5, y: 5), clickState: 1)])
        #expect(a.pipe.reconciliations == 1 && a.model.isIdle)

        var b = PipeDriver()
        injectLeftDown(&b)
        #expect(b.release(.bye).count == 1)
        #expect(b.model.isIdle && !b.pipe.isHoldingInput)

        var c = PipeDriver()
        injectLeftDown(&c)
        #expect(c.tick(after: 1 * msec).count == 1)  // tick reconciles too
        #expect(c.model.isIdle)

        var e = PipeDriver()
        injectLeftDown(&e)
        e.endSession()
        #expect(e.model.isIdle && !e.pipe.hasSession)
    }

    @Test("PIPE-17 the protocol fixture pen_hover_to_contact turns into enter, hover, down, drag, up on the display")
    func pipe17_fixture() throws {
        var decoder = FrameDecoder(connection: .control)
        decoder.append(Fixtures.bytes("pen_hover_to_contact"))
        let message = try #require(try decoder.nextMessage())
        var d = PipeDriver()
        let events = d.send(message)
        #expect(events.count == 5)
        #expect(events.first == proximityEvent(entering: true))
        let kinds = events.compactMap { e -> MacTabletPoint.Kind? in
            if case .tabletPoint(let p) = e { return p.kind }
            return nil
        }
        #expect(kinds == [.hover, .down, .drag, .up])
        guard case .tabletPoint(let down) = events[2] else { Issue.record("expected the down third"); return }
        #expect(down.position == testGeometry.point(x: 22380, y: 12750))
        #expect(down.pressure == PressureCodec.decode(288))
        #expect(down.tiltX == TiltCodec.decode(3000) && down.tiltY == TiltCodec.decode(2500))
        #expect(d.model.violations.isEmpty && d.model.proximity == .pen && !d.model.penContact)
    }
}

// MARK: - Fuzz

private func fuzzMessage(_ g: inout InputFuzzRNG) -> Message {
    func buttons() -> PointerButtons {
        switch Int.random(in: 0..<8, using: &g) {
        case 0, 1, 2: return []
        case 3, 4: return .left
        case 5: return .right
        case 6: return [.left, .right]
        default: return PointerButtons(rawValue: UInt8.random(in: 0...0x1F, using: &g))
        }
    }
    switch Int.random(in: 0..<100, using: &g) {
    case 0..<38:
        let tool: PenTool = Int.random(in: 0..<10, using: &g) < 7 ? .pen : .eraser
        var samples: [PenSample] = []
        for i in 0..<Int.random(in: 1...4, using: &g) {
            let flags: PenFlags
            switch Int.random(in: 0..<12, using: &g) {
            case 0, 1: flags = []
            case 2, 3, 4: flags = .inRange
            case 5, 6, 7: flags = [.inRange, .contact]
            case 8, 9: flags = [.inRange, .contact, .strokeStart]
            default: flags = PenFlags(rawValue: UInt8.random(in: 0...0x0F, using: &g))
            }
            samples.append(PenSample(dtUs: UInt32(i) * 3000, x: UInt16.random(in: 0...65535, using: &g),
                                     y: UInt16.random(in: 0...65535, using: &g),
                                     pressure: UInt16.random(in: 0...65535, using: &g),
                                     tiltX: Int16.random(in: -32768...32767, using: &g),
                                     tiltY: Int16.random(in: -32768...32767, using: &g), flags: flags))
        }
        return .pen(PenBatch(tool: tool, baseTimeUs: 0, samples: samples))
    case 38..<50:
        return relMsg(Float(Int.random(in: -300...300, using: &g)), Float(Int.random(in: -300...300, using: &g)), buttons())
    case 50..<60: return absMsg(.touch, UInt16.random(in: 0...65535, using: &g), UInt16.random(in: 0...65535, using: &g), buttons())
    case 60..<68: return absMsg(.mouse, UInt16.random(in: 0...65535, using: &g), UInt16.random(in: 0...65535, using: &g), buttons())
    case 68..<80:
        let phase = ScrollPhase(rawValue: UInt8.random(in: 0...4, using: &g))!
        let zero = Int.random(in: 0..<3, using: &g) == 0
        return scrollMsg(phase, zero ? 0 : Float.random(in: -40...40, using: &g), zero ? 0 : Float.random(in: -40...40, using: &g))
    case 80..<85: return doubleTap
    case 85..<89: return .releaseAll(ReleaseReason(rawValue: UInt8.random(in: 0...4, using: &g)))
    case 89..<90: return .bye(.normal)
    default: return .stats(Stats(intervalMs: 1000, framesReceived: 0, framesDecoded: 0, framesRendered: 0, framesDropped: 0,
                                 decodeTimeAvgUs: 0, latencyAvgUs: 0, bytesReceived: 0))
    }
}

private func fuzzDelta(_ g: inout InputFuzzRNG) -> Int64 {
    switch Int.random(in: 0..<100, using: &g) {
    case 0..<4: return 0
    case 4..<8: return -Int64.random(in: 1...800, using: &g) * Int64(msec)
    case 8..<78: return Int64.random(in: 1...30, using: &g) * Int64(msec)
    case 78..<95: return Int64.random(in: 100...700, using: &g) * Int64(msec)
    default: return Int64.random(in: 1_000...3_000, using: &g) * Int64(msec)
    }
}

private let fuzzGeometries: [DisplayGeometry] = [
    testGeometry,
    DisplayGeometry(originX: 0, originY: 0, widthPt: 1400, heightPt: 920, scale: 2)!,
    DisplayGeometry(originX: -1400, originY: -100, widthPt: 1400, heightPt: 920, scale: 2)!,
    DisplayGeometry(originX: 1920, originY: 0, widthPt: 700, heightPt: 460, scale: 1)!,
]

private func fuzzEnvironment(_ g: inout InputFuzzRNG, flaky: Bool) -> InjectionEnvironment {
    guard flaky else { return openEnv }
    let canInject = Int.random(in: 0..<10, using: &g) < 8
    let geometry = Int.random(in: 0..<10, using: &g) < 8 ? fuzzGeometries.randomElement(using: &g) : nil
    return InjectionEnvironment(canInject: canInject, geometry: geometry)
}

/// One random run. `flaky` toggles the permission and the display at random; otherwise the gate is always open.
private func runPipeline(seed: UInt64, steps: Int, flaky: Bool) -> [String] {
    var g = InputFuzzRNG(seed: seed)
    var d = PipeDriver()
    var failures: [String] = []
    var alwaysOpen = true

    func check(_ step: Int, _ label: String, releaseExpected: Bool = false) {
        func fail(_ text: String) { failures.append("seed \(seed) step \(step) \(label): \(text)") }
        if !d.model.violations.isEmpty { fail("violations \(d.model.violations)") }
        // Every positioned event lies on the display that is current now (closing events with no display excepted).
        if let g = d.env.geometry {
            for e in d.lastEmitted {
                if let p = eventPosition(e), !g.contains(p) { fail("event outside the current display: \(e)") }
            }
        }
        if d.pipe.reconciliations != 0 { fail("planner held what the machine did not") }
        if d.pipe.machine?.hasHeldInput != true && !d.model.isIdle { fail("Mac holds input the machine does not") }
        if !d.env.isOpen && !d.model.isIdle { fail("Mac holds input while the gate is closed") }
        if alwaysOpen, let m = d.pipe.machine {
            if m.hasHeldInput == d.model.isIdle { fail("machine held=\(m.hasHeldInput) model idle=\(d.model.isIdle)") }
            if m.isPenInRange != (d.model.proximity != nil) || m.isPenInContact != d.model.penContact {
                fail("pen state mismatch")
            }
        }
        if releaseExpected && (!d.model.isIdle || d.pipe.isHoldingInput) { fail("still holding after release") }
    }

    for i in 0..<steps {
        if Int.random(in: 0..<4, using: &g) == 0 { d.env = fuzzEnvironment(&g, flaky: flaky) }
        if !d.env.isOpen { alwaysOpen = false }
        let delta = fuzzDelta(&g)
        d.now = delta >= 0 ? d.now &+ UInt64(delta) : d.now - Swift.min(d.now, UInt64(-delta))
        switch Int.random(in: 0..<100, using: &g) {
        case 0..<70:
            let m = fuzzMessage(&g)
            d.send(m, after: 0)
            var isRelease = false
            switch m {
            case .releaseAll, .bye: isRelease = true
            default: break
            }
            check(i, "message \(m.type)", releaseExpected: isRelease)
        case 70..<85:
            d.tick(after: 0)
            check(i, "tick")
        case 85..<95:
            let cause = allReleaseCauses.randomElement(using: &g)!
            d.release(cause)
            check(i, "release \(cause)", releaseExpected: true)
            if !d.release(cause).isEmpty { failures.append("seed \(seed) step \(i): second release produced events") }
        default:
            d.endSession()
            check(i, "session end", releaseExpected: true)
            d.startSession()
            check(i, "session start", releaseExpected: true)
        }
    }
    d.shutdown()
    check(steps, "shutdown", releaseExpected: true)
    return failures
}

@Suite("PIPE-F: random sequences keep the Mac consistent")
struct InputPipelineFuzzTests {
    @Test("PIPE-F1 gate always open: the Mac mirrors the state machine exactly, nothing is ever stuck")
    func pipeF1_alwaysOpen() {
        var failures: [String] = []
        for seed in 1...400 { failures += runPipeline(seed: UInt64(seed), steps: 250, flaky: false) }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    @Test("PIPE-F2 permission and display come and go: no violations, nothing held while the gate is closed, released at once")
    func pipeF2_flakyGate() {
        var failures: [String] = []
        for seed in 1...600 { failures += runPipeline(seed: UInt64(seed) &+ 10_000, steps: 250, flaky: true) }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }
}
