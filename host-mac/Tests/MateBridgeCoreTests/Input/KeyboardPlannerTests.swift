import Testing
@testable import MateBridgeCore

// PLAN-K*: the planner's keyboard half (gate, flags, shadow state), and KPIPE-*: the keyboard through the pipeline
// (owed releases, lost permission, session end).

private func plan(_ p: inout InjectionPlanner, _ actions: [InjectAction], _ env: InjectionEnvironment = openEnv) -> [MacEvent] {
    p.plan(actions, environment: env, now: 1_000_000)
}

private func key(_ kind: MacKey.Kind, _ code: UInt16, _ flags: KeyFlags = [], isRepeat: Bool = false) -> MacEvent {
    .key(MacKey(kind: kind, keyCode: code, flags: flags, isRepeat: isRepeat))
}

private let cmdFlags = KeyFlags(holding: [ModifierKey.leftCommand])

private var noDisplay: InjectionEnvironment { InjectionEnvironment(canInject: true, geometry: nil) }
private var noPermission: InjectionEnvironment { InjectionEnvironment(canInject: false, geometry: testGeometry) }

@Suite("PLAN-K: planner keyboard rules")
struct KeyboardPlannerTests {
    @Test("PLAN-K1 a key press carries the flags of the modifiers held at that moment")
    func k1_flags() {
        var p = InjectionPlanner()
        let events = plan(&p, [
            .modifierDown(.leftCommand), .keyDown(keyCode: 0x08, autorepeat: false), .keyUp(keyCode: 0x08),
            .modifierUp(.leftCommand), .keyDown(keyCode: 0x08, autorepeat: false), .keyUp(keyCode: 0x08),
        ])
        #expect(events == [
            key(.modifierDown, 0x37, cmdFlags), key(.keyDown, 0x08, cmdFlags), key(.keyUp, 0x08, cmdFlags),
            key(.modifierUp, 0x37, []), key(.keyDown, 0x08, []), key(.keyUp, 0x08, []),
        ])
    }

    @Test("PLAN-K2 both sides of a modifier: releasing one keeps the aggregate flag and the other side's bit")
    func k2_bothSides() {
        var p = InjectionPlanner()
        let both = KeyFlags(holding: [ModifierKey.leftCommand, .rightCommand])
        let right = KeyFlags(holding: [ModifierKey.rightCommand])
        let events = plan(&p, [.modifierDown(.leftCommand), .modifierDown(.rightCommand), .modifierUp(.leftCommand),
                               .keyDown(keyCode: 0x00, autorepeat: false), .keyUp(keyCode: 0x00), .modifierUp(.rightCommand)])
        #expect(events == [
            key(.modifierDown, 0x37, cmdFlags), key(.modifierDown, 0x36, both), key(.modifierUp, 0x37, right),
            key(.keyDown, 0x00, right), key(.keyUp, 0x00, right), key(.modifierUp, 0x36, []),
        ])
        #expect(right.contains(.command))
    }

    @Test("PLAN-K3 a repeat is a keyDown with the repeat mark and the current flags; it needs a key that is down")
    func k3_repeat() {
        var p = InjectionPlanner()
        #expect(plan(&p, [.keyDown(keyCode: 0x00, autorepeat: true)]) == [])  // never went down
        _ = plan(&p, [.modifierDown(.leftShift), .keyDown(keyCode: 0x00, autorepeat: false)])
        let shift = KeyFlags(holding: [ModifierKey.leftShift])
        #expect(plan(&p, [.keyDown(keyCode: 0x00, autorepeat: true)]) == [key(.keyDown, 0x00, shift, isRepeat: true)])
        #expect(p.counters.droppedNotHeld == 1)
    }

    @Test("PLAN-K4 no display or no permission: nothing opens, keys and modifiers are not shadowed")
    func k4_closedGate() {
        for env in [noDisplay, noPermission] {
            var p = InjectionPlanner()
            let events = plan(&p, [.modifierDown(.leftCommand), .keyDown(keyCode: 0x00, autorepeat: false)], env)
            #expect(events == [])
            #expect(!p.isHoldingInput)
        }
    }

    @Test("PLAN-K5 releases are never gated: key up and modifier up flow with the display gone or the permission missing")
    func k5_closingNotGated() {
        for env in [noDisplay, noPermission] {
            var p = InjectionPlanner()
            _ = plan(&p, [.modifierDown(.leftCommand), .keyDown(keyCode: 0x00, autorepeat: false)])
            let events = plan(&p, [.keyUp(keyCode: 0x00), .modifierUp(.leftCommand)], env)
            #expect(events == [key(.keyUp, 0x00, cmdFlags), key(.modifierUp, 0x37, [])])
            #expect(!p.isHoldingInput)
        }
    }

    @Test("PLAN-K6 a repeat stops at a closed gate (display gone): the key stays held until its release")
    func k6_repeatGate() {
        var p = InjectionPlanner()
        _ = plan(&p, [.keyDown(keyCode: 0x00, autorepeat: false)])
        #expect(plan(&p, [.keyDown(keyCode: 0x00, autorepeat: true)], noDisplay) == [])
        #expect(plan(&p, [.keyDown(keyCode: 0x00, autorepeat: true)], noPermission) == [])
        #expect(p.isHoldingInput)
    }

    @Test("PLAN-K7 a modifier dropped at the gate never shows up in the flags of a later key")
    func k7_droppedModifier() {
        var p = InjectionPlanner()
        _ = plan(&p, [.modifierDown(.leftCommand)], noDisplay)  // dropped
        let events = plan(&p, [.keyDown(keyCode: 0x00, autorepeat: false), .keyUp(keyCode: 0x00)])
        #expect(events == [key(.keyDown, 0x00, []), key(.keyUp, 0x00, [])])
        // And its release has nothing to release.
        #expect(plan(&p, [.modifierUp(.leftCommand)]) == [])
    }

    @Test("PLAN-K8 a second down of a key the Mac holds, and an up of one it does not, are dropped")
    func k8_duplicates() {
        var p = InjectionPlanner()
        _ = plan(&p, [.keyDown(keyCode: 0x00, autorepeat: false)])
        #expect(plan(&p, [.keyDown(keyCode: 0x00, autorepeat: false)]) == [])
        #expect(plan(&p, [.keyUp(keyCode: 0x01)]) == [])
        #expect(plan(&p, [.modifierUp(.leftShift)]) == [])
        #expect(p.counters.droppedNotHeld == 3)
    }

    @Test("PLAN-K9 releaseAll releases keys (last first) then modifiers, each up with the flags that remain; idempotent")
    func k9_releaseAll() {
        var p = InjectionPlanner()
        _ = plan(&p, [.modifierDown(.leftCommand), .modifierDown(.leftShift), .keyDown(keyCode: 0x00, autorepeat: false),
                      .keyDown(keyCode: 0x0B, autorepeat: false)])
        let both = KeyFlags(holding: [ModifierKey.leftCommand, .leftShift])
        let events = p.releaseAll(environment: noPermission)
        #expect(events == [
            key(.keyUp, 0x0B, both), key(.keyUp, 0x00, both),
            key(.modifierUp, 0x38, cmdFlags), key(.modifierUp, 0x37, []),
        ])
        #expect(!p.isHoldingInput)
        #expect(p.releaseAll(environment: openEnv) == [])
    }

    @Test("PLAN-K10 notPosted forgets the openings that never reached the Mac, not the repeats")
    func k10_notPosted() {
        var p = InjectionPlanner()
        let down = plan(&p, [.modifierDown(.leftCommand), .keyDown(keyCode: 0x00, autorepeat: false)])
        p.notPosted(down)
        #expect(!p.isHoldingInput)

        _ = plan(&p, [.keyDown(keyCode: 0x00, autorepeat: false)])
        let rep = plan(&p, [.keyDown(keyCode: 0x00, autorepeat: true)])
        p.notPosted(rep)  // the repeat failed; the key is still down
        #expect(p.heldKeyCodes == [0x00])
    }

    @Test("PLAN-K11 Caps Lock: an event only when the Mac's state differs, none when it was not sampled")
    func k11_caps() {
        var p = InjectionPlanner()
        var env = openEnv
        #expect(plan(&p, [.setCapsLock(true)], env) == [])  // not sampled
        env.capsLockOn = false
        #expect(plan(&p, [.setCapsLock(false)], env) == [])
        #expect(plan(&p, [.setCapsLock(true)], env) == [.capsLock(on: true)])
        env.capsLockOn = true
        #expect(plan(&p, [.setCapsLock(true)], env) == [])
        #expect(plan(&p, [.setCapsLock(false)], env) == [.capsLock(on: false)])
    }

    @Test("PLAN-K12 Caps Lock is an opening: dropped at a closed gate")
    func k12_capsGate() {
        var p = InjectionPlanner()
        for var env in [noDisplay, noPermission] {
            env.capsLockOn = false
            #expect(plan(&p, [.setCapsLock(true)], env) == [])
        }
    }

    @Test("PLAN-K13 while Caps Lock is on the Mac, key events keep the Caps Lock flag (an explicit flags value would drop it)")
    func k13_capsFlag() {
        var p = InjectionPlanner()
        var env = openEnv
        env.capsLockOn = false
        let events = plan(&p, [.setCapsLock(true), .keyDown(keyCode: 0x00, autorepeat: false), .keyUp(keyCode: 0x00)], env)
        #expect(events == [.capsLock(on: true), key(.keyDown, 0x00, .capsLock), key(.keyUp, 0x00, .capsLock)])
        env.capsLockOn = true  // the Mac now reports what was set
        let off = plan(&p, [.setCapsLock(false), .keyDown(keyCode: 0x00, autorepeat: false), .keyUp(keyCode: 0x00)], env)
        #expect(off == [.capsLock(on: false), key(.keyDown, 0x00, []), key(.keyUp, 0x00, [])])
    }

    @Test("PLAN-K14 isClosing: only key up and modifier up close; Caps Lock and repeats do not")
    func k14_closing() {
        #expect(key(.keyUp, 1).isClosing && key(.modifierUp, 0x37).isClosing)
        #expect(!key(.keyDown, 1).isClosing && !key(.modifierDown, 0x37).isClosing)
        #expect(!key(.keyDown, 1, isRepeat: true).isClosing)
        #expect(!MacEvent.capsLock(on: true).isClosing)
    }
}

@Suite("KPIPE: keyboard through the pipeline")
struct KeyboardPipelineTests {
    @Test("KPIPE-1 typing through the pipeline produces the events in order, with flags")
    func kpipe1_typing() {
        var d = PipeDriver()
        d.env.capsLockOn = false
        var events = d.send(keyDown(Scan.lctrl))
        events += d.send(keyDown(Scan.c))
        events += d.send(keyUp(Scan.c))
        events += d.send(keyUp(Scan.lctrl))
        #expect(events == [
            key(.modifierDown, 0x37, cmdFlags), key(.keyDown, 0x08, cmdFlags), key(.keyUp, 0x08, cmdFlags),
            key(.modifierUp, 0x37, []),
        ])
        #expect(d.model.violations.isEmpty && d.model.isIdle)
    }

    @Test("KPIPE-2 session end, every release cause and shutdown release held keys", arguments: allReleaseCauses)
    func kpipe2_everyCause(_ cause: ReleaseCause) {
        var d = PipeDriver()
        d.send(keyDown(Scan.lshift))
        d.send(keyDown(Scan.a))
        #expect(!d.model.isIdle)
        d.release(cause)
        #expect(d.model.isIdle && d.model.violations.isEmpty && !d.pipe.isHoldingInput)
        #expect(d.tick(after: 5_000 * msec) == [])  // no repeat is left running
    }

    @Test("KPIPE-3 the session ending releases keys even when no release-all came before")
    func kpipe3_sessionEnd() {
        var d = PipeDriver()
        d.send(keyDown(Scan.rctrl))
        d.send(keyDown(Scan.tab))
        d.endSession()
        #expect(d.model.isIdle && d.model.violations.isEmpty && !d.pipe.hasSession)
    }

    @Test("KPIPE-4 the display going away releases held keys right away (gate lost), at the next message or tick")
    func kpipe4_displayLost() {
        var d = PipeDriver()
        d.send(keyDown(Scan.lctrl))
        d.send(keyDown(Scan.a))
        d.env = noDisplay
        let events = d.tick(after: 10 * msec)
        #expect(events == [key(.keyUp, 0x00, cmdFlags), key(.modifierUp, 0x37, [])])
        #expect(d.model.isIdle && d.model.violations.isEmpty)
    }

    @Test("KPIPE-5 the permission going away: releases are owed and replayed first when it is back; nothing opens before")
    func kpipe5_permissionLost() {
        var d = PipeDriver()
        d.send(keyDown(Scan.lctrl))
        d.send(keyDown(Scan.a))
        d.env = noPermission
        d.release(.clientRequest(.focusLost))
        #expect(!d.model.isIdle)  // the Mac still holds them
        #expect(d.pipe.owed.count == 2)
        // A press while the permission is missing goes nowhere; with it back, the owed releases go out before anything.
        d.env = openEnv
        let back = d.send(keyDown(Scan.b))
        #expect(back.first == key(.keyUp, 0x00, cmdFlags))
        #expect(d.model.isIdle || d.model.keys == [0x0B])
        #expect(d.orderingViolations.isEmpty && d.model.violations.isEmpty)
    }

    @Test("KPIPE-6 a key up the poster cannot build is retried until it is posted, and opens wait behind it")
    func kpipe6_failedUp() {
        var d = PipeDriver()
        d.send(keyDown(Scan.a))
        d.failing = { if case .key(let k) = $0 { k.kind == .keyUp } else { false } }
        d.send(keyUp(Scan.a))
        #expect(d.model.keys == [0x00] && d.pipe.owed.count == 1)
        // A new press must not overtake the owed release.
        let blocked = d.send(keyDown(Scan.b))
        #expect(blocked.filter { if case .key(let k) = $0 { k.kind == .keyDown } else { false } }.isEmpty)
        d.failing = { _ in false }
        d.tick(after: 2_000 * msec)
        d.tick(after: 2_000 * msec)
        #expect(d.model.isIdle && d.pipe.owed.isEmpty)
        #expect(d.orderingViolations.isEmpty && d.model.violations.isEmpty)
    }

    @Test("KPIPE-10 owed modifier ups replay in slot order with flags of what remains: no modifier is left looking held")
    func kpipe10_owedFlags() {
        var d = PipeDriver()
        d.send(keyDown(Scan.lmeta))  // Control (0x3B), pressed first
        d.send(keyDown(Scan.lctrl))  // Command (0x37), pressed second: released first, replayed last
        d.env = noPermission
        d.release(.clientRequest(.focusLost))
        #expect(d.pipe.owed.count == 2)
        d.env = openEnv
        let replay = d.tick(after: 10 * msec)
        let flagsByCode = Dictionary(uniqueKeysWithValues: replay.compactMap { e -> (UInt16, KeyFlags)? in
            if case .key(let k) = e { (k.keyCode, k.flags) } else { nil }
        })
        #expect(flagsByCode[0x37] == KeyFlags(holding: [ModifierKey.leftControl]))  // Command up first: Control remains
        #expect(flagsByCode[0x3B] == [])  // the last up leaves nothing
        #expect(d.model.isIdle && d.model.violations.isEmpty)
    }

    @Test("KPIPE-7 the repeat runs from the pipeline's tick and stops at release")
    func kpipe7_repeat() {
        var d = PipeDriver()
        d.send(keyDown(Scan.a))
        let repeats = d.tick(after: 600 * msec)
        #expect(repeats == [key(.keyDown, 0x00, [], isRepeat: true)])
        #expect(d.pipe.nextDeadline(now: d.now) != nil)
        d.send(keyUp(Scan.a))
        #expect(d.pipe.nextDeadline(now: d.now) == nil)
        #expect(d.model.isIdle && d.model.violations.isEmpty)
    }

    @Test("KPIPE-8 the next session's machine takes the repeat settings set since the last one")
    func kpipe8_configuration() {
        var pipe = InputPipeline()
        var c = pipe.nextMachineConfiguration
        c.keyRepeatDelayUs = 123_000
        pipe.setMachineConfiguration(c)
        _ = pipe.sessionStarted(now: 1_000_000, environment: openEnv)
        #expect(pipe.machine?.configuration.keyRepeatDelayUs == 123_000)
    }

    @Test("KPIPE-9 Caps Lock through the pipeline: the Mac is set to the client's state, once")
    func kpipe9_caps() {
        var d = PipeDriver()
        d.env.capsLockOn = false
        #expect(d.send(keyUp(Scan.caps, caps: true)) == [.capsLock(on: true)])
        d.env.capsLockOn = true
        #expect(d.send(keyDown(Scan.a, caps: true)).contains(.capsLock(on: true)) == false)
    }
}
