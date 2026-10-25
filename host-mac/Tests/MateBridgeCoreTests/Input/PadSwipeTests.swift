import Testing
@testable import MateBridgeCore

// SWIPE-*: the PAD_SWIPE message (PROTOCOL.md section 4, decision 0043): codec, state machine rules, planner, pipeline.
// The byte-exact golden vectors (pad_swipe_up, pad_swipe_left) are in FixtureTests.

func swipeMsg(_ direction: PadSwipeDirection, fingers: UInt8 = 3) -> Message {
    .padSwipe(PadSwipe(timeUs: 0, direction: direction, fingers: fingers))
}

private func swipeRaw(_ direction: UInt8, fingers: UInt8 = 3) -> Message {
    .padSwipe(PadSwipe(timeUs: 0, directionRaw: direction, fingers: fingers))
}

private func swipePayload(direction: UInt8 = 1, fingers: UInt8 = 3) -> [UInt8] {
    var w = ByteWriter()
    w.u64(7); w.u8(direction); w.u8(fingers); w.u16(0)
    return w.bytes
}

private let ctrlSide = KeyFlags(holding: [ModifierKey.leftControl])
private let arrowExtra: KeyFlags = [.secondaryFn, .numericPad]

private func key(_ kind: MacKey.Kind, _ code: UInt16, _ flags: KeyFlags) -> MacEvent {
    .key(MacKey(kind: kind, keyCode: code, flags: flags))
}

/// The four events of a swipe by the planner when the user holds nothing.
private func plainSwipe(_ arrow: UInt16) -> [MacEvent] {
    [key(.modifierDown, 0x3B, ctrlSide),
     key(.keyDown, arrow, ctrlSide.union(arrowExtra)),
     key(.keyUp, arrow, ctrlSide.union(arrowExtra)),
     key(.modifierUp, 0x3B, [])]
}

@Suite("SWIPE: codec")
struct PadSwipeCodecTests {
    @Test("SWIPE-C1 fields decode in protocol order and encode back")
    func fields() throws {
        let m = PadSwipe(timeUs: 7, direction: .down)
        let payload = swipePayload(direction: 2)
        #expect(try Message.decode(type: 0x18, payload: payload) == .padSwipe(m))
        #expect(Message.padSwipe(m).encodePayload() == payload)
        #expect(Message.padSwipe(m).type == .padSwipe)
    }

    @Test("SWIPE-C2 an unknown direction or finger count decodes (it is ignored later, not a protocol error)")
    func unknownValuesDecode() throws {
        #expect(try Message.decode(type: 0x18, payload: swipePayload(direction: 0))
            == .padSwipe(PadSwipe(timeUs: 7, directionRaw: 0, fingers: 3)))
        #expect(try Message.decode(type: 0x18, payload: swipePayload(direction: 9, fingers: 4))
            == .padSwipe(PadSwipe(timeUs: 7, directionRaw: 9, fingers: 4)))
        #expect(PadSwipe(timeUs: 0, directionRaw: 9, fingers: 3).direction == nil)
    }

    @Test("SWIPE-C3 a short payload is a protocol error; a longer payload is accepted")
    func shortAndLong() throws {
        #expect(throws: ProtocolError.payloadTooShort(type: 0x18)) {
            try Message.decode(type: 0x18, payload: Array(swipePayload().dropLast()))
        }
        #expect(try Message.decode(type: 0x18, payload: swipePayload() + [9, 9]) != nil)
    }

    @Test("SWIPE-C4 the arrow of each direction (fingers left = Control+Right, as on a real trackpad)")
    func arrows() {
        #expect(PadSwipeDirection.up.arrowKeyCode == 0x7E)
        #expect(PadSwipeDirection.down.arrowKeyCode == 0x7D)
        #expect(PadSwipeDirection.left.arrowKeyCode == 0x7C)
        #expect(PadSwipeDirection.right.arrowKeyCode == 0x7B)
    }
}

@Suite("SWIPE: state machine")
struct PadSwipeStateMachineTests {
    @Test("SWIPE-1 a swipe becomes one action; nothing is held afterwards")
    func performed() {
        var d = Driver()
        #expect(d.send(swipeMsg(.up)) == [.padSwipe(.up)])
        #expect(!d.machine.hasHeldInput)
        #expect(d.machine.takePadSwipeOutcomes() == [.performed(.up)])
        #expect(d.machine.takePadSwipeOutcomes().isEmpty)
    }

    @Test("SWIPE-2 an unknown direction and a finger count other than 3 are ignored without a rate penalty")
    func ignoredValues() {
        var d = Driver()
        #expect(d.send(swipeRaw(0)).isEmpty)
        #expect(d.send(swipeRaw(5)).isEmpty)
        #expect(d.send(swipeMsg(.up, fingers: 4)).isEmpty)
        #expect(d.send(swipeMsg(.up, fingers: 2)).isEmpty)
        #expect(d.machine.takePadSwipeOutcomes() == [.ignored(.dir), .ignored(.dir), .ignored(.fingers), .ignored(.fingers)])
        // None of those used up the rate limit.
        #expect(d.send(swipeMsg(.left)) == [.padSwipe(.left)])
    }

    @Test("SWIPE-3 ignored while a source owns the left button (a drag), allowed again after it is released")
    func dragIgnored() {
        var d = Driver()
        d.send(absMsg(.mouse, 10, 10, .left))
        #expect(d.send(swipeMsg(.up)).isEmpty)
        #expect(d.machine.takePadSwipeOutcomes() == [.ignored(.drag)])
        d.send(absMsg(.mouse, 10, 10, []))
        #expect(d.send(swipeMsg(.up)) == [.padSwipe(.up)])
    }

    @Test("SWIPE-4 a swipe within 250 ms of the previous performed one is ignored; at 250 ms it is allowed")
    func rate() {
        var d = Driver()
        d.send(swipeMsg(.up))
        #expect(d.send(swipeMsg(.down), after: 100 * msec).isEmpty)
        #expect(d.send(swipeMsg(.down), after: 149 * msec).isEmpty)  // 249 ms after the performed one
        #expect(d.send(swipeMsg(.down), after: 1 * msec) == [.padSwipe(.down)])  // 250 ms
        #expect(d.machine.takePadSwipeOutcomes() == [.performed(.up), .ignored(.rate), .ignored(.rate), .performed(.down)])
    }

    @Test("SWIPE-5 a clock that goes backwards does not lock swipes out")
    func backwardsClock() {
        var d = Driver()
        d.send(swipeMsg(.up))
        #expect(d.send(swipeMsg(.up), delta: -5_000_000) == [.padSwipe(.up)])
    }

    @Test("SWIPE-6 an open scroll or pinch is force-ended before the swipe")
    func endsGestures() {
        var d = Driver()
        d.send(scrollMsg(.began))
        #expect(d.send(swipeMsg(.up)) == [.scroll(.forcedEnd, dx: 0, dy: 0), .padSwipe(.up)])
        #expect(!d.machine.hasHeldInput)

        d.send(pinchMsg(.began, source: .touchpad))
        let out = d.send(swipeMsg(.down), after: 300 * msec)
        #expect(out == [.pinch(.forcedEnd(.padSwipe), scale: 0, center: nil), .padSwipe(.down)])
        #expect(d.machine.takePinchForcedEnds() == [.padSwipe])
        #expect(!d.machine.hasHeldInput)
    }

    @Test("SWIPE-7 an ignored swipe leaves an open scroll alone")
    func ignoredKeepsGestures() {
        var d = Driver()
        d.send(scrollMsg(.began))
        #expect(d.send(swipeMsg(.up, fingers: 4)).isEmpty)
        #expect(d.machine.hasHeldInput)
    }

    @Test("SWIPE-8 the user's held keys are not touched, and release-all still releases exactly them")
    func heldKeysUntouched() {
        var d = Driver()
        d.send(keyDown(Scan.lctrl)); d.send(keyDown(Scan.a))
        #expect(d.send(swipeMsg(.up)) == [.padSwipe(.up)])
        #expect(d.machine.heldKeys.count == 2)
        let release = d.release()
        #expect(release == [.keyUp(keyCode: 0x00), .modifierUp(.leftCommand)])
    }
}

@Suite("SWIPE: planner")
struct PadSwipePlannerTests {
    private func plan(_ p: inout InjectionPlanner, _ actions: [InjectAction], env: InjectionEnvironment = openEnv) -> [MacEvent] {
        p.plan(actions, environment: env, now: 1_000_000)
    }

    @Test("SWIPE-P1 each direction is Control down, arrow down, arrow up, Control up with explicit flags")
    func sequences() {
        let cases: [(PadSwipeDirection, UInt16)] = [(.up, 0x7E), (.down, 0x7D), (.left, 0x7C), (.right, 0x7B)]
        for (direction, arrow) in cases {
            var p = InjectionPlanner()
            #expect(plan(&p, [.padSwipe(direction)]) == plainSwipe(arrow), "\(direction)")
            #expect(!p.isHoldingInput && p.heldKeyCodes.isEmpty)
            #expect(p.releaseAll(environment: openEnv).isEmpty)
        }
    }

    @Test("SWIPE-P2 held Command (Ctrl mapping) does not leak into the swipe and returns in the flags after it")
    func heldCommand() {
        var p = InjectionPlanner()
        _ = plan(&p, [.modifierDown(.leftCommand)])
        let command = KeyFlags(holding: [ModifierKey.leftCommand])
        let out = plan(&p, [.padSwipe(.up)])
        #expect(out == [key(.modifierDown, 0x3B, ctrlSide),
                        key(.keyDown, 0x7E, ctrlSide.union(arrowExtra)),
                        key(.keyUp, 0x7E, ctrlSide.union(arrowExtra)),
                        key(.modifierUp, 0x3B, command)])
        for case .key(let k) in out { #expect(!k.flags.contains(.command) || k.kind == .modifierUp) }
        // Afterwards the Command key keeps working: the next key carries it, the swipe left no trace.
        #expect(p.heldKeyCodes.isEmpty)
        let next = plan(&p, [.keyDown(keyCode: 0x00, autorepeat: false)])
        #expect(next == [key(.keyDown, 0x00, command)])
        #expect(plan(&p, [.modifierUp(.leftCommand)]) == [key(.modifierUp, 0x37, [])])
    }

    @Test("SWIPE-P3 held Shift and Option stay out of the swipe events too")
    func heldOthers() {
        var p = InjectionPlanner()
        _ = plan(&p, [.modifierDown(.leftShift), .modifierDown(.rightOption)])
        let out = plan(&p, [.padSwipe(.down)])
        let held = KeyFlags(holding: [ModifierKey.leftShift, .rightOption])
        #expect(out.count == 4)
        for case .key(let k) in out where k.kind != .modifierUp {
            #expect(!k.flags.contains(.shift) && !k.flags.contains(.option))
        }
        #expect(out.last == key(.modifierUp, 0x3B, held))
    }

    @Test("SWIPE-P4 a Control the user already holds (Meta mapping) is not pressed or released again")
    func heldControl() {
        var p = InjectionPlanner()
        _ = plan(&p, [.modifierDown(.leftControl)])
        let out = plan(&p, [.padSwipe(.up)])
        #expect(out == [key(.keyDown, 0x7E, ctrlSide.union(arrowExtra)), key(.keyUp, 0x7E, ctrlSide.union(arrowExtra))])
        #expect(p.releaseAll(environment: openEnv) == [key(.modifierUp, 0x3B, [])])
    }

    @Test("SWIPE-P4b Control held with Shift or Command: the swipe ends by restating the user's full modifier state")
    func heldControlPlusOthers() {
        for other in [ModifierKey.leftShift, .leftCommand] {
            var p = InjectionPlanner()
            _ = plan(&p, [.modifierDown(.leftControl), .modifierDown(other)])
            let held = KeyFlags(holding: [ModifierKey.leftControl, other])
            let out = plan(&p, [.padSwipe(.up)])
            #expect(out == [key(.keyDown, 0x7E, ctrlSide.union(arrowExtra)),
                            key(.keyUp, 0x7E, ctrlSide.union(arrowExtra)),
                            key(.flagsRefresh, 0x3B, held)], "\(other)")
            // Nothing was released: both stay held, and the next key carries both.
            #expect(plan(&p, [.keyDown(keyCode: 0x00, autorepeat: false)]) == [key(.keyDown, 0x00, held)])
        }
    }

    @Test("SWIPE-P5the user holding that very arrow: the swipe is dropped, the held key stays held")
    func heldArrow() {
        var p = InjectionPlanner()
        _ = plan(&p, [.keyDown(keyCode: 0x7E, autorepeat: false)])
        #expect(plan(&p, [.padSwipe(.up)]).isEmpty)
        #expect(p.heldKeyCodes == [0x7E])
        #expect(plan(&p, [.padSwipe(.down)]).count == 4)
    }

    @Test("SWIPE-P6 opening gate: no permission, no display or an owed release means no swipe")
    func gating() {
        for env in [noPermissionEnv, noDisplayEnv, closedEnv] {
            var p = InjectionPlanner()
            #expect(plan(&p, [.padSwipe(.up)], env: env).isEmpty)
            #expect(!p.isHoldingInput)
        }
        var blocked = openEnv
        blocked.opensBlocked = true
        var p = InjectionPlanner()
        #expect(plan(&p, [.padSwipe(.up)], env: blocked).isEmpty)
    }

    @Test("SWIPE-P7 caps lock is not part of the swipe's flags")
    func capsLock() {
        var p = InjectionPlanner()
        var env = openEnv
        env.capsLockOn = true
        _ = plan(&p, [.setCapsLock(true)], env: env)
        let out = plan(&p, [.padSwipe(.up)], env: env)
        for case .key(let k) in out { #expect(!k.flags.contains(.capsLock) || k.kind == .modifierUp) }
        #expect(out.count == 4)
    }
}

@Suite("SWIPE: pipeline")
struct PadSwipePipelineTests {
    @Test("SWIPE-I1 a swipe through the pipeline posts one balanced sequence and leaves nothing held or owed")
    func balanced() {
        var d = PipeDriver()
        let events = d.send(swipeMsg(.up))
        #expect(events == plainSwipe(0x7E))
        #expect(d.model.isIdle && !d.pipe.isHoldingInput && d.pipe.owed.isEmpty)
        #expect(d.pipe.takePadSwipeOutcomes() == [.performed(.up)])
        #expect(d.pipe.takePadSwipeOutcomes().isEmpty)
        // 250 ms later the next one goes out.
        d.send(swipeMsg(.left), after: 100 * msec)
        #expect(d.pipe.takePadSwipeOutcomes() == [.ignored(.rate)])
        #expect(d.send(swipeMsg(.left), after: 200 * msec) == plainSwipe(0x7C))
        #expect(d.model.violations.isEmpty && d.orderingViolations.isEmpty)
    }

    @Test("SWIPE-I2 an unknown direction produces no events and no state")
    func unknown() {
        var d = PipeDriver()
        #expect(d.send(swipeRaw(77)).isEmpty)
        #expect(d.pipe.takePadSwipeOutcomes() == [.ignored(.dir)])
        #expect(!d.pipe.isHoldingInput)
    }

    @Test("SWIPE-I3 an arrow release the poster cannot build is owed and retried; the Control press of that batch was posted")
    func failedRelease() {
        var d = PipeDriver()
        d.failing = { if case .key(let k) = $0 { k.kind == .keyUp } else { false } }
        d.send(swipeMsg(.up))
        // The arrow up and the Control up are returned unposted: both are owed.
        #expect(d.pipe.owed.count == 2 && d.pipe.owed.isBlocking)
        d.failing = { _ in false }
        d.tick(after: 300 * msec)
        #expect(d.pipe.owed.isEmpty && d.model.isIdle)
        #expect(d.model.violations.isEmpty && d.orderingViolations.isEmpty)
    }

    @Test("SWIPE-I4 the session end after a swipe has nothing to release")
    func sessionEnd() {
        var d = PipeDriver()
        d.send(swipeMsg(.down))
        d.endSession()
        #expect(d.model.isIdle && d.lastEmitted.isEmpty)
    }
}
