import Testing
@testable import MateBridgeCore

// KFLAG-*: keyboard flags on pointer, pen and scroll events (one planner rule), flags of replayed releases, and the
// repeat stopping on any other key's DOWN (review round 1 of T-032).

private let shift = KeyFlags(holding: [ModifierKey.leftShift])
private let cmd = KeyFlags(holding: [ModifierKey.leftCommand])

private func flagsOf(_ e: MacEvent) -> KeyFlags? {
    switch e {
    case .mouse(let m): m.flags
    case .tabletPoint(let p): p.flags
    case .scroll(let s): s.flags
    case .key(let k): k.flags
    case .tabletProximity, .capsLock: nil
    }
}

@Suite("KFLAG: modifier flags on every event kind")
struct KeyboardFlagsTests {
    @Test("KFLAG-1 mouse moves, presses, drags, releases and wheel steps carry the modifiers held when they are emitted")
    func kflag1_mouse() {
        var p = InjectionPlanner()
        _ = p.plan([.modifierDown(.leftShift)], environment: openEnv, now: 1_000_000)
        let events = p.plan([
            moveAbs(), .mouseButton(.left, down: true), moveAbs(600, 700, dragging: .left), .mouseButton(.left, down: false),
            .scrollWheel(dx: 0, dy: 10), .modifierUp(.leftShift), moveAbs(),
        ], environment: openEnv, now: 1_000_000)
        let flags = events.compactMap(flagsOf)
        #expect(flags == [shift, shift, shift, shift, shift, [], []])  // the modifier up event itself carries what remains
        #expect(events.count == 7)
    }

    @Test("KFLAG-2 pen events carry the flags: hover, down, drag and up (Krita's Shift/Ctrl+pen shortcuts)")
    func kflag2_pen() {
        var p = InjectionPlanner()
        _ = p.plan([.modifierDown(.leftCommand)], environment: openEnv, now: 1_000_000)
        let events = p.plan([
            penEnter(), .penHover(tool: .pen, penPt()), .penDown(tool: .pen, penPt(1, 1, 500)),
            .penDrag(tool: .pen, penPt(2, 2, 500)), .penUp(tool: .pen, penPt(2, 2)), penLeave(),
        ], environment: openEnv, now: 1_000_000)
        let tablets = events.compactMap { e -> KeyFlags? in if case .tabletPoint(let t) = e { t.flags } else { nil } }
        #expect(tablets == [cmd, cmd, cmd, cmd])
    }

    @Test("KFLAG-3 scroll gesture events carry the flags, and so does the end")
    func kflag3_scroll() {
        var p = InjectionPlanner()
        _ = p.plan([.modifierDown(.leftShift)], environment: openEnv, now: 1_000_000)
        let events = p.plan([.scroll(.began, dx: 0, dy: 5), .scroll(.changed, dx: 0, dy: 5), .scroll(.ended, dx: 0, dy: 0)],
                            environment: openEnv, now: 1_000_000)
        #expect(events.compactMap(flagsOf) == [shift, shift, shift])
    }

    @Test("KFLAG-4 Caps Lock is part of the flags of pointer events while the Mac has it on")
    func kflag4_caps() {
        var p = InjectionPlanner()
        var env = openEnv
        env.capsLockOn = false
        _ = p.plan([.setCapsLock(true)], environment: env, now: 1)
        let events = p.plan([moveAbs()], environment: env, now: 1)
        #expect(events.compactMap(flagsOf) == [.capsLock])
    }

    @Test("KFLAG-5 a closing event carries the flags current when it is emitted: release-all puts pointer ups before modifier ups")
    func kflag5_closing() {
        var p = InjectionPlanner()
        _ = p.plan([.modifierDown(.leftShift), moveAbs(), .mouseButton(.left, down: true)], environment: openEnv, now: 1)
        let events = p.releaseAll(environment: noPermissionEnv)
        #expect(events.compactMap(flagsOf) == [shift, []])  // button up still sees Shift; the Shift up leaves nothing
        // A modifier released before the button: the button's up has no flags.
        var q = InjectionPlanner()
        _ = q.plan([.modifierDown(.leftShift), moveAbs(), .mouseButton(.left, down: true)], environment: openEnv, now: 1)
        let up = q.plan([.modifierUp(.leftShift), .mouseButton(.left, down: false)], environment: openEnv, now: 1)
        #expect(up.compactMap(flagsOf) == [[], []])
    }

    @Test("KFLAG-6 without a modifier held, pointer events carry empty flags (explicit, never the system's)")
    func kflag6_empty() {
        var p = InjectionPlanner()
        let events = p.plan([moveAbs(), .mouseButton(.left, down: true)], environment: openEnv, now: 1)
        #expect(events.compactMap(flagsOf) == [[], []])
    }

    @Test("KFLAG-7 through the pipeline: Shift+click from KEY and POINTER messages")
    func kflag7_pipeline() {
        var d = PipeDriver()
        d.send(keyDown(Scan.lshift))
        let click = d.send(absMsg(.mouse, 500, 600, .left))
        #expect(click.compactMap(flagsOf) == [shift, shift])
        let release = d.send(absMsg(.mouse, 500, 600, []))
        #expect(release.compactMap(flagsOf) == [shift, shift])  // move, then the up
    }

    // MARK: Replayed releases

    @Test("KFLAG-8 a retried modifier up takes the flags of the keyboard now, not the ones it was produced with")
    func kflag8_retryFlags() {
        var d = PipeDriver()
        d.send(keyDown(Scan.lctrl))  // Command
        d.send(keyDown(Scan.lshift))
        d.failing = { if case .key(let k) = $0 { k.kind == .modifierUp && k.keyCode == 0x37 } else { false } }
        d.send(keyUp(Scan.lctrl))  // Command up fails, produced while Shift is held: saved flags say Shift
        #expect(d.pipe.owed.count == 1)
        d.failing = { _ in false }
        d.send(keyUp(Scan.lshift))  // Shift is released before the retry
        let retry = d.tick(after: 300 * msec)
        let commandUp = retry.compactMap { e -> KeyFlags? in
            if case .key(let k) = e, k.keyCode == 0x37 { k.flags } else { nil }
        }
        #expect(commandUp == [[]])
        #expect(!d.pipe.isHoldingInput && d.pipe.owed.isEmpty)
        #expect(d.model.modifiers.isEmpty)
    }

    @Test("KFLAG-9 replayed pointer releases see the modifiers the Mac still holds (held now plus owed modifier ups)")
    func kflag9_replayedPointerUp() {
        var d = PipeDriver()
        d.send(keyDown(Scan.lshift))
        d.send(absMsg(.mouse, 500, 600, .left))
        d.env = noPermissionEnv
        d.release(.clientRequest(.focusLost))
        d.env = openEnv
        let replay = d.tick(after: 10 * msec)
        #expect(replay.compactMap(flagsOf) == [shift, []])  // button up with Shift, then the Shift up
        #expect(d.model.isIdle)
    }

    @Test("KFLAG-11 a replay counts modifier ups that are owed but not due yet: A-up retried before Command-up still carries Command")
    func kflag11_pendingModifier() {
        var d = PipeDriver()
        d.send(keyDown(Scan.lctrl))  // Command
        d.send(keyDown(Scan.a))
        d.failing = { if case .key(let k) = $0 { k.kind == .keyUp || k.kind == .modifierUp } else { false } }
        d.send(keyUp(Scan.a))  // fails at T, retry due at T + 250 ms
        d.send(keyUp(Scan.lctrl), after: 100 * msec)  // fails at T + 100 ms, retry due at T + 350 ms
        #expect(d.pipe.owed.count == 2)
        d.failing = { _ in false }
        let first = d.tick(after: 150 * msec)  // T + 250 ms: only the A-up is due
        #expect(first.count == 1)
        #expect(first.compactMap(flagsOf) == [cmd])
        let second = d.tick(after: 100 * msec)  // T + 350 ms
        #expect(second.compactMap(flagsOf) == [[]])
        #expect(d.model.isIdle && d.pipe.owed.isEmpty)
    }

    @Test("KFLAG-12 a deferred pointer release also keeps the flags of a modifier up that is still owed")
    func kflag12_pendingForPointer() {
        var pending = OwedRelease()
        let up = MacEvent.mouse(MacMouse(kind: .up, button: .left, position: .zero, deltaX: 0, deltaY: 0, clickState: 1))
        let cmdUp = MacEvent.key(MacKey(kind: .modifierUp, keyCode: ModifierKey.leftCommand.keyCode, flags: []))
        pending.owe([up], now: 0, countsAsAttempt: true)
        pending.owe([cmdUp], now: 100_000, countsAsAttempt: true)
        let due = pending.replay(now: 250_000, force: false, geometry: nil)
        #expect(due.compactMap(flagsOf) == [cmd])
        #expect(pending.count == 1)
    }

    // MARK: Repeat

    @Test("KFLAG-13 macOS key repeat off: no repeat is ever armed")
    func kflag13_repeatOff() {
        var c = InputStateMachine.Configuration()
        c.keyRepeatEnabled = false
        var d = Driver(configuration: c)
        #expect(withoutCaps(d.send(keyDown(Scan.a))) == [.keyDown(keyCode: 0x00, autorepeat: false)])
        #expect(d.machine.nextDeadline(now: d.now) == nil)
        #expect(d.tick(after: 10_000 * msec) == [])
        #expect(d.machine.keyCounters.repeats == 0)
        #expect(withoutCaps(d.send(keyUp(Scan.a))) == [.keyUp(keyCode: 0x00)])
    }

    @Test("KFLAG-10 the Caps key's DOWN and an unmapped key's DOWN stop the repeat; a duplicate DOWN of the repeating key does not")
    func kflag10_repeatStops() {
        for stopper in [keyDown(Scan.caps), keyDown(84), keyDown(Scan.b)] {
            var d = Driver()
            d.send(keyDown(Scan.a))
            #expect(d.tick(after: 600 * msec) == [.keyDown(keyCode: 0x00, autorepeat: true)])
            d.send(stopper)
            #expect(d.tick(after: 5_000 * msec).filter { $0 == .keyDown(keyCode: 0x00, autorepeat: true) }.isEmpty)
        }
        var d = Driver()
        d.send(keyDown(Scan.a))
        d.send(keyDown(Scan.a), after: 100 * msec)  // duplicate
        #expect(d.tick(after: 450 * msec) == [.keyDown(keyCode: 0x00, autorepeat: true)])
    }
}

