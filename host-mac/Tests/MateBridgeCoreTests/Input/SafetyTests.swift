import Testing
@testable import MateBridgeCore

// PROTOCOL.md section 7: watchdogs (WD-*), release-all (REL-*); section 4 SCROLL host rules (SCROLL-*).

private func holdPenContact(_ d: inout Driver) {
    d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
    d.send(penMsg(.pen, penSample(2, 2, startFlags, pressure: 100)))
}

@Suite("WD: input watchdogs")
struct WatchdogTests {
    @Test("WD-PEN-1 IN_RANGE without a PEN message for 500 ms: leave (not one microsecond earlier)")
    func wdPen1_hoverTimeout() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.tick(after: 499_999).isEmpty)
        #expect(d.tick(after: 1) == [penLeave(.pen)])
        #expect(!d.machine.isPenInRange)
        #expect(d.tick(after: 1_000 * msec).isEmpty)
    }

    @Test("WD-PEN-2 while touching the watchdog issues up (pressure 0, last position) then leave, and frees the button")
    func wdPen2_contactTimeout() {
        var d = Driver()
        holdPenContact(&d)
        #expect(d.tick(after: 500 * msec) == [.penUp(tool: .pen, penPt(2, 2, 0)), penLeave(.pen)])
        #expect(!d.machine.hasHeldInput)
        #expect(d.send(relMsg(0, 0, .left)) == [.mouseButton(.left, down: true)])
    }

    @Test("WD-PEN-3 every PEN message restarts the timer")
    func wdPen3_sampleRestartsTimer() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        d.send(penMsg(.pen, penSample(2, 2, hoverFlags)), after: 400 * msec)
        #expect(d.tick(after: 400 * msec).isEmpty)
        #expect(d.tick(after: 100 * msec) == [penLeave(.pen)])
    }

    @Test("WD-PEN-4 nothing to do when the pen is out of range")
    func wdPen4_idle() {
        var d = Driver()
        #expect(d.tick(after: 5_000 * msec).isEmpty)
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        d.send(penMsg(.pen, penSample(1, 1, [])))
        #expect(d.tick(after: 5_000 * msec).isEmpty)
    }

    @Test("WD-PEN-5 after the watchdog closed the pen, the next sample enters again")
    func wdPen5_reenter() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        d.tick(after: 500 * msec)
        #expect(d.send(penMsg(.pen, penSample(3, 3, hoverFlags))) == [penEnter(.pen), .penHover(tool: .pen, penPt(3, 3))])
    }

    @Test("WD-PEN-6 the timeout is configurable")
    func wdPen6_config() {
        var config = InputStateMachine.Configuration()
        config.penWatchdogUs = 100_000
        var d = Driver(configuration: config)
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.tick(after: 99_999).isEmpty)
        #expect(d.tick(after: 1) == [penLeave(.pen)])
    }

    @Test("WD-SCROLL-1 an open scroll gesture without SCROLL for 500 ms is ended (cancelled, no momentum)")
    func wdScroll1_timeout() {
        var d = Driver()
        d.send(scrollMsg(.began, 1, 2))
        #expect(d.tick(after: 499_999).isEmpty)
        #expect(d.tick(after: 1) == [.scroll(.cancelled, dx: 0, dy: 0)])
        #expect(!d.machine.hasHeldInput)
        #expect(d.tick(after: 1_000 * msec).isEmpty)
    }

    @Test("WD-SCROLL-2 SCROLL CHANGED restarts the timer; CHANGED after the watchdog is ignored")
    func wdScroll2_changedRestarts() {
        var d = Driver()
        d.send(scrollMsg(.began))
        d.send(scrollMsg(.changed, 0, 3), after: 400 * msec)
        #expect(d.tick(after: 400 * msec).isEmpty)
        #expect(d.tick(after: 100 * msec) == [.scroll(.cancelled, dx: 0, dy: 0)])
        #expect(d.send(scrollMsg(.changed, 0, 3)).isEmpty)
    }

    @Test("WD-3 both watchdogs can fire in one tick: pen first, then scroll")
    func wd3_both() {
        var d = Driver()
        holdPenContact(&d)
        d.send(scrollMsg(.began))
        #expect(d.tick(after: 500 * msec) == [
            .penUp(tool: .pen, penPt(2, 2, 0)), penLeave(.pen), .scroll(.cancelled, dx: 0, dy: 0),
        ])
    }

    @Test("WD-5 nextDeadline is the earliest armed watchdog and tick fires exactly there")
    func wd5_nextDeadline() {
        var d = Driver()
        #expect(d.machine.nextDeadline == nil)
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        let penDue = d.now + 500_000
        #expect(d.machine.nextDeadline == penDue)
        d.send(scrollMsg(.began), after: 100 * msec)
        #expect(d.machine.nextDeadline == penDue)          // pen fires first
        d.send(penMsg(.pen, penSample(1, 1, []), penSample(1, 1, [])), after: 10 * msec)  // pen leaves
        #expect(d.machine.nextDeadline == d.now - 10 * msec + 500_000)  // scroll timer
        let due = d.machine.nextDeadline!
        d.now = due - 1
        #expect(d.machine.tick(now: d.now).isEmpty)
        #expect(d.machine.tick(now: due) == [.scroll(.cancelled, dx: 0, dy: 0)])
        #expect(d.machine.nextDeadline == nil)
        d.release()
        #expect(d.machine.nextDeadline == nil)
    }

    @Test("WD-4 a clock that goes backwards never fires or crashes")
    func wd4_backwardsClock() {
        var m = InputStateMachine()
        _ = m.handle(penMsg(.pen, penSample(1, 1, hoverFlags)), now: 5_000_000)
        _ = m.handle(scrollMsg(.began), now: 5_000_000)
        #expect(m.tick(now: 1_000).isEmpty)
        #expect(m.hasHeldInput)
        #expect(m.isTouchGateActive(at: 1_000))
    }
}

@Suite("REL: release-all")
struct ReleaseAllTests {
    /// Pen touching, right (trackpad) and back (mouse) held, scroll open.
    private func everythingHeld() -> Driver {
        var d = Driver()
        holdPenContact(&d)
        d.send(relMsg(0, 0, .right))
        d.send(absMsg(.mouse, 5, 5, .back))
        d.send(scrollMsg(.began))
        return d
    }

    @Test("REL-1 releases everything, in order, for every trigger", arguments: allReleaseCauses)
    func rel1_everythingEveryCause(cause: ReleaseCause) {
        var d = everythingHeld()
        #expect(d.machine.hasHeldInput)
        #expect(d.release(cause) == [
            .penUp(tool: .pen, penPt(2, 2, 0)), penLeave(.pen),
            .mouseButton(.right, down: false), .mouseButton(.back, down: false),
            .scroll(.cancelled, dx: 0, dy: 0),
        ])
        #expect(!d.machine.hasHeldInput)
        #expect(d.machine.lastReleaseCause == cause)
        // Idempotent.
        #expect(d.release(cause).isEmpty)
        #expect(!d.machine.hasHeldInput)
    }

    @Test("REL-2 a pointer owner of the left button is released with the rest")
    func rel2_pointerOwner() {
        var d = Driver()
        d.send(absMsg(.mouse, 5, 5, .left))
        d.send(relMsg(0, 0, .middle))
        d.send(scrollMsg(.began))
        #expect(d.release(.disconnected) == [
            .mouseButton(.left, down: false), .mouseButton(.middle, down: false), .scroll(.cancelled, dx: 0, dy: 0),
        ])
        #expect(!d.machine.hasHeldInput)
    }

    @Test("REL-3 a hovering pen is left: the left owner's up comes before the leave")
    func rel3_hoverAndOwner() {
        var d = Driver()
        d.send(absMsg(.touch, 5, 5, .left))
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.release(.timeout) == [.mouseButton(.left, down: false), penLeave(.pen)])
        var e = Driver()
        e.send(penMsg(.eraser, penSample(1, 1, hoverFlags)))
        #expect(e.release(.silence) == [penLeave(.eraser)])
    }

    @Test("REL-4 RELEASE_ALL and BYE messages are release triggers")
    func rel4_messages() {
        var d = everythingHeld()
        let out = d.send(.releaseAll(.focusLost))
        #expect(out.count == 5)
        #expect(d.machine.lastReleaseCause == .clientRequest(.focusLost))
        #expect(!d.machine.hasHeldInput)

        var e = everythingHeld()
        #expect(e.send(.bye(.normal)).count == 5)
        #expect(e.machine.lastReleaseCause == .bye)
        #expect(!e.machine.hasHeldInput)
        #expect(e.send(.bye(.normal)).isEmpty)
    }

    @Test("REL-5 a stale 'left still held' message after release-all is not a new press",
          arguments: PtrSource.allCases)
    func rel5_stalePointerMessage(source: PtrSource) {
        var d = Driver()
        d.send(source.msg(.left))
        #expect(d.release(.silence) == [.mouseButton(.left, down: false)])
        let stale = d.send(source.msg(.left, x: 700, y: 800))
        #expect(!stale.contains(.mouseButton(.left, down: true)))
        #expect(!d.machine.hasHeldInput)
        // After the source reports the release and presses again, the press counts.
        d.send(source.msg([]))
        #expect(d.send(source.msg(.left)) == source.move() + [.mouseButton(.left, down: true)])
    }

    @Test("REL-6 the same holds for the OR buttons: a stale right is not a new press")
    func rel6_staleRight() {
        var d = Driver()
        d.send(relMsg(0, 0, .right))
        #expect(d.release(.superseded) == [.mouseButton(.right, down: false)])
        #expect(d.send(relMsg(0, 0, .right)).isEmpty)
        #expect(!d.machine.hasHeldInput)
        #expect(d.send(relMsg(0, 0, [])).isEmpty)
        #expect(d.send(relMsg(0, 0, .right)) == [.mouseButton(.right, down: true)])
        // Another source's right is a fresh press too.
        var e = Driver()
        e.send(relMsg(0, 0, .right))
        e.release(.shutdown)
        #expect(e.send(absMsg(.mouse, 1, 1, .right)) == [moveAbs(1, 1), .mouseButton(.right, down: true)])
    }

    @Test("REL-7 a new stroke (STROKE_START) works immediately after release-all")
    func rel7_newStrokeAfterRelease() {
        var d = everythingHeld()
        d.release(.clientRequest(.background))
        #expect(d.send(penMsg(.pen, penSample(9, 9, startFlags, pressure: 33))) == [
            penEnter(.pen), .penDown(tool: .pen, penPt(9, 9, 33)),
        ])
    }

    @Test("REL-8 scroll after release-all needs a fresh BEGAN")
    func rel8_scrollAfterRelease() {
        var d = Driver()
        d.send(scrollMsg(.began))
        d.release(.silence)
        #expect(d.send(scrollMsg(.changed, 1, 1)).isEmpty)
        #expect(d.send(scrollMsg(.ended)).isEmpty)
        #expect(d.send(scrollMsg(.began)) == [.scroll(.began, dx: 0, dy: 0)])
    }

    @Test("REL-9 the pen up at release-all uses the last position with pressure 0 and keeps tilt")
    func rel9_penUpAtLastPosition() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        d.send(penMsg(.pen, penSample(4000, 5000, startFlags, pressure: 60000)))
        let out = d.release(.disconnected)
        guard case .penUp(.pen, let up)? = out.first else { Issue.record("expected pen up first"); return }
        #expect(up.x == 4000 && up.y == 5000 && up.pressure == 0)
        #expect(up.tiltX == defaultTiltX && up.tiltY == defaultTiltY)
    }

    @Test("REL-10 a release-all on an idle machine emits nothing and holds nothing")
    func rel10_idle() {
        var d = Driver()
        for cause in allReleaseCauses { #expect(d.release(cause).isEmpty) }
        #expect(!d.machine.hasHeldInput)
    }
}

@Suite("SCROLL: section 4 SCROLL host rules")
struct ScrollTests {
    @Test("SCROLL-1 BEGAN, CHANGED, ENDED map to began, changed, ended with their deltas")
    func scroll1_normalGesture() {
        var d = Driver()
        #expect(d.send(scrollMsg(.began, 1, 2)) == [.scroll(.began, dx: 1, dy: 2)])
        #expect(d.machine.hasHeldInput)
        #expect(d.send(scrollMsg(.changed, 3, 4)) == [.scroll(.changed, dx: 3, dy: 4)])
        #expect(d.send(scrollMsg(.ended, 5, 6)) == [.scroll(.ended, dx: 5, dy: 6)])
        #expect(!d.machine.hasHeldInput)
    }

    @Test("SCROLL-2 CHANGED, ENDED and CANCELLED without BEGAN are ignored")
    func scroll2_withoutBegan() {
        var d = Driver()
        #expect(d.send(scrollMsg(.changed, 1, 1)).isEmpty)
        #expect(d.send(scrollMsg(.ended, 1, 1)).isEmpty)
        #expect(d.send(scrollMsg(.cancelled, 1, 1)).isEmpty)
        d.send(scrollMsg(.began))
        d.send(scrollMsg(.ended))
        #expect(d.send(scrollMsg(.changed, 1, 1)).isEmpty)
        #expect(d.send(scrollMsg(.ended, 1, 1)).isEmpty)
    }

    @Test("SCROLL-3 a BEGAN over an open gesture ends the old one first")
    func scroll3_beganOverOpen() {
        var d = Driver()
        d.send(scrollMsg(.began))
        #expect(d.send(scrollMsg(.began, 7, 8)) == [.scroll(.cancelled, dx: 0, dy: 0), .scroll(.began, dx: 7, dy: 8)])
        #expect(d.send(scrollMsg(.ended)) == [.scroll(.ended, dx: 0, dy: 0)])
        #expect(!d.machine.hasHeldInput)
    }

    @Test("SCROLL-4 a wheel step (phase NONE) is a single event and touches no gesture state")
    func scroll4_wheel() {
        var d = Driver()
        #expect(d.send(scrollMsg(.none, 0, 10)) == [.scrollWheel(dx: 0, dy: 10)])
        #expect(!d.machine.hasHeldInput)
        d.send(scrollMsg(.began))
        #expect(d.send(scrollMsg(.none, 0, -10)) == [.scrollWheel(dx: 0, dy: -10)])
        #expect(d.machine.hasHeldInput)
        #expect(d.send(scrollMsg(.changed, 1, 1)) == [.scroll(.changed, dx: 1, dy: 1)])
    }

    @Test("SCROLL-5 CANCELLED closes the gesture as cancelled")
    func scroll5_cancelled() {
        var d = Driver()
        d.send(scrollMsg(.began))
        #expect(d.send(scrollMsg(.cancelled, 1, 1)) == [.scroll(.cancelled, dx: 1, dy: 1)])
        #expect(!d.machine.hasHeldInput)
    }
}

@Suite("MISC: scope")
struct ScopeTests {
    @Test("MISC-1 messages that are not pen, pointer or scroll input produce no actions (keyboard is phase 3)")
    func misc1_ignoredMessages() {
        var d = Driver()
        let key = Message.key(KeyEvent(timeUs: 0, scanCode: 30, androidKeyCode: 29, action: .down, capsLockOn: false))
        #expect(d.send(key).isEmpty)
        #expect(d.send(.ping(Ping(seq: 1, senderTimeUs: 0))).isEmpty)
        #expect(d.send(.keyframeRequest(.startup)).isEmpty)
        #expect(!d.machine.hasHeldInput)
    }

    @Test("MISC-2 a movement-only POINTER_REL with buttons 0 is a plain move; zero movement is nothing")
    func misc2_relativeMoves() {
        var d = Driver()
        #expect(d.send(relMsg(2, -3, [])) == [.mouseMove(.relative(dx: 2, dy: -3), dragging: nil)])
        #expect(d.send(relMsg(0, 0, [])).isEmpty)
    }

    @Test("MISC-3 a touch tap and drag produce move, down, drags and up at the finger's positions")
    func misc3_touchTapAndDrag() {
        var d = Driver()
        #expect(d.send(absMsg(.touch, 100, 200, .left)) == [moveAbs(100, 200), .mouseButton(.left, down: true)])
        #expect(d.send(absMsg(.touch, 110, 210, .left)) == [moveAbs(110, 210, dragging: .left)])
        #expect(d.send(absMsg(.touch, 120, 220, [])) == [
            moveAbs(120, 220, dragging: .left), .mouseButton(.left, down: false),
        ])
    }
}
