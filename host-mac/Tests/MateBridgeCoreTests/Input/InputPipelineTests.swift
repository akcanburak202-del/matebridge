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
///
/// The model sees only what the Mac RECEIVES, like the real thing: events posted while the Accessibility permission
/// is there (`env.canInject`, or `permissionTruth` when a test wants the pipeline's cached view to be stale) and that
/// the poster manages to build (`failing` decides which events it cannot). macOS drops the rest silently. The driver
/// reports failures back to the pipeline (`postFailed`) the way `InputController` does.
struct PipeDriver {
    var pipe = InputPipeline()
    var now: UInt64 = 10_000_000
    var env = openEnv
    var model = MacEventModel()
    /// What the most recent call produced.
    var lastEmitted: [MacEvent] = []
    /// The permission as macOS sees it, when it differs from what the pipeline was told (a stale cache).
    var permissionTruth: Bool?
    /// Events the poster cannot build.
    var failing: (MacEvent) -> Bool = { _ in false }

    init(session: Bool = true) {
        if session { deliver(pipe.sessionStarted(now: now, environment: env)) }
    }

    private var trusted: Bool { permissionTruth ?? env.canInject }

    mutating func deliver(_ events: [MacEvent]) {
        lastEmitted = events
        // InputController: a batch that closes something gets a fresh permission check; without it nothing is posted.
        if events.contains(where: \.isClosing), !trusted {
            pipe.postFailed(events, now: now, permitted: false)
            return
        }
        var failed: [MacEvent] = []
        for event in events {
            guard trusted else { continue }
            if failing(event) { failed.append(event); continue }
            model.apply(event)
        }
        if !failed.isEmpty { pipe.postFailed(failed, now: now, permitted: true) }
    }

    @discardableResult
    mutating func send(_ message: Message, after: UInt64 = 1 * msec) -> [MacEvent] {
        now += after
        let events = pipe.handle(message, now: now, environment: env)
        deliver(events)
        return events
    }

    @discardableResult
    mutating func tick(after: UInt64) -> [MacEvent] {
        now += after
        let events = pipe.tick(now: now, environment: env)
        deliver(events)
        return events
    }

    @discardableResult
    mutating func release(_ cause: ReleaseCause) -> [MacEvent] {
        let events = pipe.release(cause, now: now, environment: env)
        deliver(events)
        return events
    }

    @discardableResult
    mutating func endSession() -> [MacEvent] {
        let events = pipe.sessionEnded(now: now, environment: env)
        deliver(events)
        return events
    }

    @discardableResult
    mutating func startSession() -> [MacEvent] {
        let events = pipe.sessionStarted(now: now, environment: env)
        deliver(events)
        return events
    }

    @discardableResult
    mutating func shutdown() -> [MacEvent] {
        let events = pipe.shutdown(now: now, environment: env)
        deliver(events)
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

    @Test("PIPE-5 Accessibility permission missing at release time: the events are produced but cannot be posted; they are owed and go out first when the permission returns")
    func pipe5_releaseWithoutPermission() {
        var d = PipeDriver()
        d.holdPenRightScroll()
        d.env = noPermissionEnv
        #expect(d.release(.bye).count == 4)  // up, leave, right up, scroll end
        // Honest limit: the Mac never got them. Nothing can be released while the permission is missing.
        #expect(!d.model.isIdle && d.model.violations.isEmpty)
        #expect(d.pipe.owed.count == 4 && !d.pipe.isHoldingInput)
        #expect(d.tick(after: 1 * msec).isEmpty)  // still nothing to do without the permission
        d.env = openEnv
        #expect(d.tick(after: 1 * msec).count == 4)
        #expect(d.model.isIdle && d.model.violations.isEmpty && d.pipe.owed.isEmpty)

        // No permission and no display, then only the permission comes back: released where it was.
        var m = PipeDriver()
        m.holdMouseMiddleScroll()
        m.env = closedEnv
        m.release(.disconnected)
        #expect(!m.model.isIdle && m.pipe.owed.count == 3)  // left up, middle up, scroll end
        m.env = noDisplayEnv
        m.tick(after: 1 * msec)
        #expect(m.model.isIdle && m.pipe.owed.isEmpty)
    }

    @Test("PIPE-6 permission revoked mid stroke: the gate-loss release is owed, input is dropped, and the owed release goes out before anything new once the permission is back")
    func pipe6_permissionRevokedMidStroke() {
        var d = PipeDriver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        d.send(penMsg(.pen, penSample(2, 2, startFlags, pressure: 400)))
        d.env = noPermissionEnv
        let events = d.send(penMsg(.pen, penSample(3, 3, touchFlags, pressure: 500)))
        #expect(events == [tabletEvent(.up, x: 2, y: 2), proximityEvent(entering: false)])
        #expect(d.pipe.lastReleaseCause == .gateLost)
        // The machine follows the tablet (the pen hovers again there); the Mac never received the up and still holds
        // the contact, which is exactly what is owed.
        #expect(!d.pipe.planner.isHoldingInput && d.model.penContact && d.pipe.owed.count == 2)
        #expect(d.send(penMsg(.pen, penSample(4, 4, touchFlags, pressure: 500))).isEmpty)

        d.env = openEnv  // granted again, the stroke is still going on in the tablet's samples
        let back = d.send(penMsg(.pen, penSample(5, 5, touchFlags, pressure: 500)))
        #expect(back == [tabletEvent(.up, x: 2, y: 2), proximityEvent(entering: false),
                         proximityEvent(entering: true), tabletEvent(.hover, x: 5, y: 5)])
        #expect(!d.model.penContact && d.pipe.owed.isEmpty)
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

    @Test("PIPE-19 every release is recorded with its cause and what it released; a gate loss has its own cause")
    func pipe19_releaseRecords() {
        var d = PipeDriver()
        d.holdPenRightScroll()
        _ = d.pipe.takeReleaseRecords()
        d.env = noDisplayEnv
        d.tick(after: 1 * msec)  // the display went away with the pen down: released by itself
        let gate = d.pipe.takeReleaseRecords()
        #expect(d.pipe.lastReleaseCause == .gateLost)
        #expect(gate.count == 1 && gate[0].cause == .gateLost && gate[0].reason == "gate_lost")
        #expect(gate[0].events == 4 && gate[0].penUps == 1 && gate[0].penLeaves == 1 && gate[0].buttonUps == 1 && gate[0].scrollEnds == 1)
        #expect(gate[0].logFields == "cause=gate_lost events=4 pen_up=1 pen_leave=1 buttons=1 scroll=1")
        #expect(d.pipe.takeReleaseRecords().isEmpty)

        d.env = openEnv
        var e = PipeDriver()
        e.holdMouseMiddleScroll()
        _ = e.pipe.takeReleaseRecords()
        e.release(.silence)
        e.release(.silence)  // idempotent: recorded again, with nothing released
        let records = e.pipe.takeReleaseRecords()
        #expect(records.map(\.reason) == ["silence", "silence"])
        #expect(records.map(\.events) == [3, 0])
        #expect(records[0].buttonUps == 2 && records[0].scrollEnds == 1)
    }

    @Test("PIPE-20 a closing event the poster could not build is retried, not forgotten: after the retry interval, in order")
    func pipe20_failedCloseIsRetried() {
        var d = PipeDriver()
        d.holdPenRightScroll()
        d.failing = { $0.isClosing }  // the poster cannot build any release
        d.release(.bye)
        #expect(!d.model.isIdle && d.pipe.owed.count == 4)
        #expect(d.tick(after: 100 * msec).isEmpty)  // inside the retry interval
        d.failing = { _ in false }
        let retry = d.tick(after: 200 * msec)
        #expect(retry == [tabletEvent(.up, x: 1010, y: 2010), proximityEvent(entering: false),
                          mouseEvent(.up, .right, at: testGeometry.point(x: 1010, y: 2010), clickState: 1),
                          scrollEvent(.ended, at: testGeometry.point(x: 1010, y: 2010))])
        #expect(d.model.isIdle && d.pipe.owed.isEmpty)
        #expect(d.pipe.takeReleaseRecords().contains { $0.reason == "owed_replay" && $0.events == 4 })
    }

    @Test("PIPE-21 retries are bounded: six attempts, then the release is given up, counted and recorded")
    func pipe21_boundedRetries() {
        var d = PipeDriver()
        d.holdPenRightScroll()
        d.failing = { $0.isClosing }
        d.release(.bye)
        var replays = 0
        for _ in 0..<30 where !d.pipe.owed.isEmpty {
            if !d.tick(after: 300 * msec).isEmpty { replays += 1 }
        }
        #expect(replays == OwedRelease.maxAttempts)
        #expect(d.pipe.owed.isEmpty && d.pipe.owed.gaveUp == 4)
        #expect(d.pipe.takeReleaseRecords().contains { $0.reason == "owed_giveup" && $0.gaveUp == 4 })
        #expect(d.tick(after: 300 * msec).isEmpty)
    }

    @Test("PIPE-22 a release trigger, a session start and shutdown retry at once, ignoring the retry interval")
    func pipe22_triggersForceRetry() {
        for trigger in 0..<3 {
            var d = PipeDriver()
            d.holdPenRightScroll()
            d.failing = { $0.isClosing }
            d.release(.bye)
            d.failing = { _ in false }
            let events: [MacEvent]
            switch trigger {
            case 0: events = d.release(.silence)
            case 1:
                d.endSession()  // itself a release: retries at once
                events = d.lastEmitted
            default: events = d.shutdown()
            }
            #expect(events.count == 4, "trigger \(trigger)")
            #expect(d.model.isIdle && d.pipe.owed.isEmpty, "trigger \(trigger)")
        }
        var d = PipeDriver()
        d.holdPenRightScroll()
        d.failing = { $0.isClosing }
        d.release(.bye)
        d.failing = { _ in false }
        #expect(d.startSession().count == 4)  // a new session starts clean
        #expect(d.model.isIdle && d.pipe.owed.isEmpty)
    }

    @Test("PIPE-23 owed releases survive a session end and a shutdown without permission, and go out at the next start or once it is back")
    func pipe23_owedAcrossSessions() {
        var d = PipeDriver()
        d.holdPenRightScroll()
        d.env = noPermissionEnv
        d.release(.silence)
        d.endSession()
        d.shutdown()
        d.release(.shutdown)
        #expect(d.pipe.owed.count == 4)  // a fixed set of slots: repeated releases do not add up
        #expect(!d.model.isIdle)
        d.env = openEnv
        #expect(d.startSession().count == 4)  // the next session start replays first
        #expect(d.model.isIdle && d.pipe.owed.isEmpty && d.model.violations.isEmpty)

        var e = PipeDriver()
        e.holdPenRightScroll()
        e.env = noPermissionEnv
        e.release(.silence)
        e.env = openEnv
        #expect(e.shutdown().count == 4)  // shutdown replays too
        #expect(e.model.isIdle && e.pipe.owed.isEmpty)
    }

    @Test("PIPE-24 a permission cache that is stale at release time does not lose the release: nothing counts as an attempt while the permission is gone")
    func pipe24_stalePermission() {
        var d = PipeDriver()
        d.holdPenRightScroll()
        d.permissionTruth = false  // revoked a moment ago; the pipeline was still told it was there
        d.release(.bye)
        #expect(!d.model.isIdle && d.pipe.owed.count == 4)
        for _ in 0..<12 { d.tick(after: 300 * msec) }  // it is tried again and again, each try refused
        #expect(d.pipe.owed.count == 4 && d.pipe.owed.gaveUp == 0)
        d.permissionTruth = nil
        #expect(d.tick(after: 300 * msec).count == 4)
        #expect(d.model.isIdle && d.pipe.owed.isEmpty)
    }

    @Test("PIPE-25 zero-delta scroll CHANGED (the client's keepalive) through the whole chain injects nothing")
    func pipe25_keepalive() {
        var d = PipeDriver()
        d.send(scrollMsg(.began, 0, 3))
        for _ in 0..<5 { #expect(d.send(scrollMsg(.changed, 0, 0), after: 200 * msec).isEmpty) }
        #expect(d.model.scrollOpen && d.model.violations.isEmpty)
        // The 500 ms watchdog is fed by those messages, so the gesture is still open after 1 s of keepalives.
        #expect(d.pipe.machine?.hasHeldInput == true)
        #expect(d.send(scrollMsg(.ended, 0, 0)) == [scrollEvent(.ended, at: testGeometry.center)])
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

/// Which events the poster cannot build: at random, but never more than three in a row per slot, so a bounded retry
/// always gets through in the end.
private final class PosterFaults {
    var rng: InputFuzzRNG
    var streak: [OwedRelease.Slot: Int] = [:]
    init(seed: UInt64) { rng = InputFuzzRNG(seed: seed) }

    func fails(_ e: MacEvent) -> Bool {
        guard e.isClosing, let slot = OwedRelease.Slot(e) else { return false }
        if Int.random(in: 0..<10, using: &rng) < 3, streak[slot, default: 0] < 3 {
            streak[slot, default: 0] += 1
            return true
        }
        streak[slot] = 0
        return false
    }
}

private func fuzzEnvironment(_ g: inout InputFuzzRNG, flaky: Bool) -> InjectionEnvironment {
    guard flaky else { return openEnv }
    let canInject = Int.random(in: 0..<10, using: &g) < 8
    let geometry = Int.random(in: 0..<10, using: &g) < 8 ? fuzzGeometries.randomElement(using: &g) : nil
    return InjectionEnvironment(canInject: canInject, geometry: geometry)
}

/// One random run. `flaky` toggles the permission and the display at random (otherwise the gate is always open);
/// `faults` makes the poster fail to build closing events at random and lets the pipeline's view of the permission go
/// stale. The Mac model sees only what is really delivered (see `PipeDriver`).
private func runPipeline(seed: UInt64, steps: Int, flaky: Bool, faults: Bool = false) -> [String] {
    var g = InputFuzzRNG(seed: seed)
    var d = PipeDriver()
    let plan = PosterFaults(seed: seed &+ 77)
    if faults { d.failing = { plan.fails($0) } }
    var failures: [String] = []
    var alwaysOpen = !faults

    func check(_ step: Int, _ label: String, releaseExpected: Bool = false) {
        func fail(_ text: String) { failures.append("seed \(seed) step \(step) \(label): \(text)") }
        // With faults a lost up can be followed by a new down before the retry: the Mac sees a double down.
        if !faults && !d.model.violations.isEmpty { fail("violations \(d.model.violations)") }
        // Every positioned event lies on the display that is current now (closing events with no display excepted).
        if let g = d.env.geometry {
            for e in d.lastEmitted {
                if let p = eventPosition(e), !g.contains(p) { fail("event outside the current display: \(e)") }
            }
        }
        if d.pipe.reconciliations != 0 { fail("planner held what the machine did not") }
        let gaveUp = d.pipe.owed.gaveUp > 0
        // Whatever the Mac holds is known to someone: the planner, or the owed releases.
        if !d.model.isIdle && !d.pipe.planner.isHoldingInput && d.pipe.owed.isEmpty && !gaveUp {
            fail("the Mac holds input nobody remembers")
        }
        // With the permission there and nothing owed, the Mac and the planner agree exactly (not with faults: a stale cache
        // lets macOS drop an opening event unnoticed, which is harmless but leaves the planner ahead of the Mac).
        if !faults && d.env.canInject && d.pipe.owed.isEmpty && !gaveUp {
            let p = d.pipe.planner
            if (d.model.proximity != nil) != p.isPenInRange || d.model.penContact != p.isPenInContact
                || d.model.buttons != p.heldMouseButtons || d.model.scrollOpen != p.isScrollOpen {
                fail("Mac and planner disagree")
            }
        }
        // The display gone (permission there): everything was released at once.
        if d.env.canInject && !d.env.isOpen && d.permissionTruth == nil && d.pipe.owed.isEmpty && !gaveUp && !d.model.isIdle {
            fail("Mac holds input while the display is gone")
        }
        if alwaysOpen, let m = d.pipe.machine {
            if m.hasHeldInput == d.model.isIdle { fail("machine held=\(m.hasHeldInput) model idle=\(d.model.isIdle)") }
            if m.isPenInRange != (d.model.proximity != nil) || m.isPenInContact != d.model.penContact {
                fail("pen state mismatch")
            }
        }
        if releaseExpected && (d.pipe.isHoldingInput || (!d.model.isIdle && d.pipe.owed.isEmpty && !gaveUp)) {
            fail("still holding after release")
        }
    }

    for i in 0..<steps {
        if Int.random(in: 0..<4, using: &g) == 0 { d.env = fuzzEnvironment(&g, flaky: flaky) }
        // A stale permission cache: the pipeline is told the permission is there for a step when it is not.
        d.permissionTruth = faults && d.env.canInject && Int.random(in: 0..<12, using: &g) == 0 ? false : nil
        if !d.env.isOpen || d.permissionTruth != nil { alwaysOpen = false }
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
            // Idempotent, unless something is still owed (then the trigger retries it).
            if d.pipe.owed.isEmpty, !d.release(cause).isEmpty { failures.append("seed \(seed) step \(i): second release produced events") }
        default:
            d.endSession()
            check(i, "session end", releaseExpected: true)
            d.startSession()
            check(i, "session start", releaseExpected: true)
        }
    }
    // Quiescence: the permission and the display are back and the poster works. A few retry intervals later nothing
    // is owed and the Mac is idle, unless a release had to be given up on.
    d.env = openEnv
    d.permissionTruth = nil
    d.failing = { _ in false }
    for _ in 0..<10 { d.tick(after: 300 * msec) }
    d.shutdown()
    check(steps, "shutdown", releaseExpected: true)
    if !d.pipe.owed.isEmpty { failures.append("seed \(seed): releases still owed after the quiescence") }
    if d.pipe.owed.gaveUp == 0 && !d.model.isIdle { failures.append("seed \(seed): the Mac is not idle after the quiescence") }
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

    @Test("PIPE-F2 permission and display come and go: no violations, every release that was refused is replayed, positions stay on the display")
    func pipeF2_flakyGate() {
        var failures: [String] = []
        for seed in 1...600 { failures += runPipeline(seed: UInt64(seed) &+ 10_000, steps: 250, flaky: true) }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    @Test("PIPE-F3 on top of that the poster fails to build releases and the permission cache goes stale: bounded retries, nothing owed at the end")
    func pipeF3_faults() {
        var failures: [String] = []
        for seed in 1...600 { failures += runPipeline(seed: UInt64(seed) &+ 20_000, steps: 250, flaky: true, faults: true) }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }
}
