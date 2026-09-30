import Testing
@testable import MateBridgeCore

// PINCH-*: the PINCH message (PROTOCOL.md section 4, decision 0009): codec, state machine rules, planner, pipeline.

private func magnifyEvent(_ phase: MacMagnify.Phase, _ value: Double = 0, at p: DisplayPoint = testGeometry.center,
                          flags: KeyFlags = []) -> MacEvent {
    .magnify(MacMagnify(phase: phase, value: value, position: p, flags: flags))
}

private func decodePinch(_ payload: [UInt8]) throws -> Message? { try Message.decode(type: 0x17, payload: payload) }

private func pinchPayload(scale: Float = 0, phase: UInt8 = 1, source: UInt8 = 0) -> [UInt8] {
    var w = ByteWriter()
    w.u64(7); w.u32(scale.bitPattern); w.u16(1); w.u16(2); w.u8(phase); w.u8(source); w.u16(0)
    return w.bytes
}

@Suite("PINCH: codec")
struct PinchCodecTests {
    @Test("PINCH-C1 fields decode in protocol order and encode back")
    func fields() throws {
        let m = Pinch(timeUs: 7, scale: -0.25, x: 1, y: 2, phase: .cancelled, source: .touchpad)
        let payload = pinchPayload(scale: -0.25, phase: 4, source: 1)
        #expect(try decodePinch(payload) == .pinch(m))
        #expect(Message.pinch(m).encodePayload() == payload)
        #expect(Message.pinch(m).type == .pinch)
    }

    @Test("PINCH-C2 an unknown or zero phase or source is a protocol error")
    func invalidEnums() {
        #expect(throws: ProtocolError.invalidField("phase")) { try decodePinch(pinchPayload(phase: 0)) }
        #expect(throws: ProtocolError.invalidField("phase")) { try decodePinch(pinchPayload(phase: 5)) }
        #expect(throws: ProtocolError.invalidField("source")) { try decodePinch(pinchPayload(source: 2)) }
    }

    @Test("PINCH-C3 a short payload and a non-finite scale are protocol errors; a longer payload is accepted")
    func shortAndNonFinite() throws {
        #expect(throws: ProtocolError.payloadTooShort(type: 0x17)) { try decodePinch(Array(pinchPayload().dropLast())) }
        #expect(throws: ProtocolError.nonFiniteFloat("scale")) { try decodePinch(pinchPayload(scale: .nan)) }
        #expect(throws: ProtocolError.nonFiniteFloat("scale")) { try decodePinch(pinchPayload(scale: .infinity)) }
        #expect(try decodePinch(pinchPayload(scale: 0.5) + [9, 9]) != nil)
    }
}

@Suite("PINCH: state machine")
struct PinchStateMachineTests {
    @Test("PINCH-1 began, changed and ended become actions; a touch began carries the center, a touchpad one does not")
    func lifecycle() {
        var d = Driver()
        #expect(d.send(pinchMsg(.began, x: 10, y: 20)) == [.pinch(.began, scale: 0, center: PinchCenter(x: 10, y: 20))])
        #expect(d.machine.hasHeldInput)
        #expect(d.send(pinchMsg(.changed, scale: 0.05)) == [.pinch(.changed, scale: 0.05, center: nil)])
        #expect(d.send(pinchMsg(.ended)) == [.pinch(.ended, scale: 0, center: nil)])
        #expect(!d.machine.hasHeldInput)
        #expect(d.send(pinchMsg(.began, source: .touchpad)) == [.pinch(.began, scale: 0, center: nil)])
        #expect(d.send(pinchMsg(.cancelled)) == [.pinch(.cancelled, scale: 0, center: nil)])
        #expect(!d.machine.hasHeldInput)
        #expect(d.machine.pinchMessages == 5)
    }

    @Test("PINCH-2 CHANGED, ENDED and CANCELLED without a BEGAN are ignored")
    func withoutBegan() {
        var d = Driver()
        for phase in [PinchPhase.changed, .ended, .cancelled] { #expect(d.send(pinchMsg(phase, scale: 0.1)).isEmpty) }
        d.send(pinchMsg(.began)); d.send(pinchMsg(.ended))
        #expect(d.send(pinchMsg(.changed, scale: 0.1)).isEmpty)
        #expect(d.send(pinchMsg(.ended)).isEmpty)
    }

    @Test("PINCH-3 a BEGAN over an open pinch ends the old one first")
    func beganOverPinch() {
        var d = Driver()
        d.send(pinchMsg(.began))
        let out = d.send(pinchMsg(.began, x: 5, y: 6))
        #expect(out == [.pinch(.forcedEnd(.newPinch), scale: 0, center: nil),
                        .pinch(.began, scale: 0, center: PinchCenter(x: 5, y: 6))])
        #expect(d.machine.takePinchForcedEnds() == [.newPinch])
    }

    @Test("PINCH-4 pinch and scroll exclude each other, in both directions")
    func mutualExclusion() {
        var d = Driver()
        d.send(scrollMsg(.began))
        #expect(d.send(pinchMsg(.began)) == [.scroll(.forcedEnd, dx: 0, dy: 0),
                                             .pinch(.began, scale: 0, center: PinchCenter(x: 500, y: 600))])
        #expect(d.send(scrollMsg(.changed, 0, 4)) == [])  // the scroll is closed; its continuation is ignored
        #expect(d.send(scrollMsg(.began)) == [.pinch(.forcedEnd(.newScroll), scale: 0, center: nil),
                                              .scroll(.began, dx: 0, dy: 0)])
        #expect(d.machine.takePinchForcedEnds() == [.newScroll])
        #expect(d.send(pinchMsg(.changed, scale: 0.1)).isEmpty)
        // A wheel step is not a gesture and leaves an open pinch alone.
        d.send(pinchMsg(.began))
        #expect(d.send(scrollMsg(.none, 0, 3)) == [.scrollWheel(dx: 0, dy: 3)])
        #expect(d.machine.hasHeldInput)
    }

    @Test("PINCH-5 a BEGAN is ignored while a source owns the left button, and so is the rest of that gesture")
    func leftOwner() {
        var d = Driver()
        d.send(absMsg(.mouse, 10, 10, .left))
        #expect(d.send(pinchMsg(.began, source: .touchpad)).isEmpty)
        #expect(d.send(pinchMsg(.changed, scale: 0.1, source: .touchpad)).isEmpty)
        #expect(d.send(pinchMsg(.ended, source: .touchpad)).isEmpty)
        d.send(absMsg(.mouse, 10, 10, []))
        // Pen contact owns the left button too.
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        d.send(penMsg(.pen, penSample(1, 1, startFlags, pressure: 100)))
        #expect(d.send(pinchMsg(.began, source: .touchpad)).isEmpty)
        #expect(d.machine.takePinchForcedEnds().isEmpty)
    }

    @Test("PINCH-6 an ignored BEGAN ends an older open pinch, so its continuation cannot be mistaken for the new one")
    func ignoredBeganEndsOld() {
        var d = Driver()
        d.send(pinchMsg(.began, source: .touchpad))
        d.send(absMsg(.mouse, 10, 10, .left))
        #expect(d.send(pinchMsg(.began, source: .touchpad)) == [.pinch(.forcedEnd(.ignoredBegan), scale: 0, center: nil)])
        #expect(d.send(pinchMsg(.changed, scale: 0.1, source: .touchpad)).isEmpty)
        #expect(d.machine.takePinchForcedEnds() == [.ignoredBegan])
    }

    @Test("PINCH-7 a touchscreen pinch follows the finger gate: not while the pen is in range or for 1 s after it")
    func fingerGate() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(pinchMsg(.began)).isEmpty)
        #expect(d.send(pinchMsg(.changed, scale: 0.1)).isEmpty)
        // The touchpad is not a finger on the glass: never gated.
        #expect(d.send(pinchMsg(.began, source: .touchpad)).count == 1)
        d.send(pinchMsg(.ended, source: .touchpad))
        d.send(penMsg(.pen, penSample(1, 1, [])))  // pen leaves
        #expect(d.send(pinchMsg(.began), after: 900 * msec).isEmpty)  // still inside the second
        #expect(d.send(pinchMsg(.ended)).isEmpty)
        #expect(d.send(pinchMsg(.began), after: 200 * msec).count == 1)
    }

    @Test("PINCH-8 500 ms without a PINCH message end the gesture; any message keeps it alive")
    func watchdog() {
        var d = Driver()
        d.send(pinchMsg(.began))
        #expect(d.machine.nextDeadline(now: d.now) == d.now + 500 * msec)
        d.send(pinchMsg(.changed, scale: 0), after: 400 * msec)  // the client's keepalive
        #expect(d.tick(after: 499 * msec).isEmpty)
        #expect(d.tick(after: 1 * msec) == [.pinch(.forcedEnd(.watchdog), scale: 0, center: nil)])
        #expect(d.machine.nextDeadline(now: d.now) == nil)
        #expect(d.machine.takePinchForcedEnds() == [.watchdog])
        #expect(d.tick(after: 1_000 * msec).isEmpty)
    }

    @Test("PINCH-9 an overdue watchdog is applied before the next message")
    func watchdogBeforeMessage() {
        var d = Driver()
        d.send(pinchMsg(.began))
        let out = d.send(pinchMsg(.changed, scale: 0.1), after: 600 * msec)
        #expect(out == [.pinch(.forcedEnd(.watchdog), scale: 0, center: nil)])
    }

    @Test("PINCH-10 a clock that goes backwards restarts the watchdog from there")
    func backwardsClock() {
        var d = Driver()
        d.send(pinchMsg(.began))
        #expect(d.tick(delta: -5_000 * Int64(msec)).isEmpty)
        #expect(d.machine.nextDeadline(now: d.now) == d.now + 500 * msec)
        #expect(d.tick(after: 500 * msec) == [.pinch(.forcedEnd(.watchdog), scale: 0, center: nil)])
    }

    @Test("PINCH-11 release-all ends an open pinch (no latch, idempotent); a watchdog end is not a release")
    func releaseAll() {
        var d = Driver()
        d.send(pinchMsg(.began))
        #expect(d.release() == [.pinch(.forcedEnd(.releaseAll), scale: 0, center: nil)])
        #expect(!d.machine.hasHeldInput)
        #expect(d.release().isEmpty)
        #expect(d.machine.takePinchForcedEnds() == [.releaseAll])
        // RELEASE_ALL and BYE messages take the same way.
        d.send(pinchMsg(.began))
        #expect(d.send(.releaseAll(.background)) == [.pinch(.forcedEnd(.releaseAll), scale: 0, center: nil)])
        d.send(pinchMsg(.began))
        #expect(d.send(.bye(.normal)) == [.pinch(.forcedEnd(.releaseAll), scale: 0, center: nil)])
    }
}

@Suite("PINCH: planner")
struct PinchPlannerTests {
    private func plan(_ p: inout InjectionPlanner, _ actions: [InjectAction], env: InjectionEnvironment = openEnv) -> [MacEvent] {
        p.plan(actions, environment: env, now: 1_000_000)
    }

    @Test("PINCH-P1 a touchscreen began moves the cursor to the center first (a plain move), then begins the gesture there")
    func touchBegan() {
        var p = InjectionPlanner()
        let center = testGeometry.point(x: 16384, y: 49152)
        let out = plan(&p, [.pinch(.began, scale: 0, center: PinchCenter(x: 16384, y: 49152))])
        #expect(out.count == 2)
        #expect(out[0] == mouseEvent(.moved, at: center))  // no cursor before: no delta
        #expect(out[1] == magnifyEvent(.began, at: center))
        #expect(p.isMagnifyOpen && p.cursor == center)
        let changed = plan(&p, [.pinch(.changed, scale: 0.05, center: nil)])
        #expect(changed == [magnifyEvent(.changed, Double(Float(0.05)), at: center)])
        #expect(plan(&p, [.pinch(.ended, scale: 0, center: nil)]) == [magnifyEvent(.ended, at: center)])
        #expect(!p.isMagnifyOpen && !p.isHoldingInput)
    }

    @Test("PINCH-P2 a touchpad began leaves the cursor where it is")
    func touchpadBegan() {
        var p = InjectionPlanner()
        _ = plan(&p, [moveAbs(10, 20)])
        let at = testGeometry.point(x: 10, y: 20)
        #expect(plan(&p, [.pinch(.began, scale: 0, center: nil)]) == [magnifyEvent(.began, at: at)])
        // A second touch pinch after a cursor move carries the delta of that move.
        _ = plan(&p, [.pinch(.ended, scale: 0, center: nil)])
        let out = plan(&p, [.pinch(.began, scale: 0, center: PinchCenter(x: 30, y: 40))])
        let target = testGeometry.point(x: 30, y: 40)
        #expect(out[0] == mouseEvent(.moved, at: target, delta: DisplayPoint(x: target.x - at.x, y: target.y - at.y)))
    }

    @Test("PINCH-P3 a zero change is never injected; values are clamped to -0.5...1")
    func keepaliveAndClamp() {
        var p = InjectionPlanner()
        _ = plan(&p, [.pinch(.began, scale: 0, center: nil)])
        #expect(plan(&p, [.pinch(.changed, scale: 0, center: nil)]).isEmpty)
        #expect(p.counters.droppedKeepalive == 1)
        let values: [Double] = plan(&p, [.pinch(.changed, scale: 7, center: nil), .pinch(.changed, scale: -3, center: nil),
                                         .pinch(.changed, scale: .nan, center: nil)])
            .compactMap { if case .magnify(let g) = $0 { g.value } else { nil } }
        #expect(values == [1.0, -0.5, 0.0])
    }

    @Test("PINCH-P4 cancelled and forced ends are an ended to the Mac, never gated, also without permission or display")
    func endsAlwaysProduced() {
        for end in [InjectPinchPhase.ended, .cancelled, .forcedEnd(.watchdog), .forcedEnd(.releaseAll)] {
            for env in [openEnv, noPermissionEnv, noDisplayEnv, closedEnv] {
                var p = InjectionPlanner()
                _ = plan(&p, [.pinch(.began, scale: 0, center: nil)])
                let out = plan(&p, [.pinch(end, scale: 0, center: nil)], env: env)
                #expect(out.count == 1 && out[0].isClosing, "\(end) \(env)")
                guard case .magnify(let g) = out[0] else { Issue.record("not a magnify event"); continue }
                #expect(g.phase == .ended && g.value == 0)
                #expect(!p.isMagnifyOpen)
            }
        }
        var p = InjectionPlanner()
        #expect(plan(&p, [.pinch(.ended, scale: 0, center: nil)]).isEmpty)
        #expect(p.counters.droppedNotHeld == 1)
    }

    @Test("PINCH-P5 opening needs permission, a display and no owed release; changes need permission and a display")
    func gating() {
        for env in [noPermissionEnv, noDisplayEnv, closedEnv] {
            var p = InjectionPlanner()
            #expect(plan(&p, [.pinch(.began, scale: 0, center: PinchCenter(x: 1, y: 1))], env: env).isEmpty)
            #expect(!p.isMagnifyOpen && p.cursor == nil)
        }
        var blocked = openEnv
        blocked.opensBlocked = true
        var p = InjectionPlanner()
        #expect(plan(&p, [.pinch(.began, scale: 0, center: nil)], env: blocked).isEmpty)
        #expect(p.counters.droppedOwed == 1)
        _ = plan(&p, [.pinch(.began, scale: 0, center: nil)])
        #expect(plan(&p, [.pinch(.changed, scale: 0.1, center: nil)], env: noPermissionEnv).isEmpty)
        #expect(plan(&p, [.pinch(.changed, scale: 0.1, center: nil)], env: noDisplayEnv).isEmpty)
        #expect(plan(&p, [.pinch(.changed, scale: 0.1, center: nil)]).count == 1)
    }

    @Test("PINCH-P6 every event of the gesture carries the keyboard modifiers held at that moment (Cmd+pinch)")
    func flags() {
        var p = InjectionPlanner()
        let cmd = KeyFlags(holding: [ModifierKey.leftCommand])
        _ = plan(&p, [.modifierDown(.leftCommand)])
        let began = plan(&p, [.pinch(.began, scale: 0, center: PinchCenter(x: 5, y: 5))])
        let changed = plan(&p, [.pinch(.changed, scale: 0.1, center: nil)])
        #expect(began.compactMap { if case .magnify(let g) = $0 { g.flags } else { nil } } == [cmd])
        #expect(began.compactMap { if case .mouse(let m) = $0 { m.flags } else { nil } } == [cmd])
        #expect(changed.compactMap { if case .magnify(let g) = $0 { g.flags } else { nil } } == [cmd])
        // A release of the modifier while the gesture is open: the end carries what remains.
        _ = plan(&p, [.modifierUp(.leftCommand)])
        let ended = plan(&p, [.pinch(.ended, scale: 0, center: nil)])
        let endFlags: [KeyFlags] = ended.compactMap { if case .magnify(let g) = $0 { g.flags } else { nil } }
        #expect(endFlags == [KeyFlags()])
    }

    @Test("PINCH-P7 the planner's own release-all ends an open gesture; a never-posted began is forgotten by notPosted")
    func releaseAndNotPosted() {
        var p = InjectionPlanner()
        _ = plan(&p, [.pinch(.began, scale: 0, center: nil)])
        #expect(p.releaseAll(environment: closedEnv) == [magnifyEvent(.ended)])
        #expect(p.releaseAll(environment: closedEnv).isEmpty)

        let began = plan(&p, [.pinch(.began, scale: 0, center: nil)])
        #expect(p.isMagnifyOpen)
        p.notPosted(began)
        #expect(!p.isMagnifyOpen && !p.isHoldingInput)
    }
}

@Suite("PINCH: pipeline")
struct PinchPipelineTests {
    @Test("PINCH-I1 a whole gesture through the pipeline; the watchdog and every release trigger close it")
    func closers() {
        var d = PipeDriver()
        d.send(pinchMsg(.began)); d.send(pinchMsg(.changed, scale: 0.1))
        #expect(d.model.magnifyOpen && d.pipe.isHoldingInput)
        d.send(pinchMsg(.ended))
        #expect(d.model.isIdle && !d.pipe.isHoldingInput)

        d.send(pinchMsg(.began))
        d.tick(after: 600 * msec)
        #expect(d.model.isIdle)
        #expect(d.pipe.takePinchForcedEnds() == [.watchdog])

        for cause in allReleaseCauses {
            d.send(pinchMsg(.began, source: .touchpad))
            d.release(cause)
            #expect(d.model.isIdle && !d.pipe.isHoldingInput, "\(cause)")
        }
        #expect(d.pipe.takePinchForcedEnds() == [PinchEndCause](repeating: .releaseAll, count: allReleaseCauses.count))
        #expect(d.model.violations.isEmpty && d.orderingViolations.isEmpty)
    }

    @Test("PINCH-I2 the session end releases a gesture, and its cause survives the machine")
    func sessionEnd() {
        var d = PipeDriver()
        d.send(pinchMsg(.began))
        d.endSession()
        #expect(d.model.isIdle)
        #expect(d.pipe.takePinchForcedEnds() == [.releaseAll])
        #expect(d.pipe.takePinchForcedEnds().isEmpty)
    }

    @Test("PINCH-I3 an end the poster could not build is owed and retried; nothing new opens before it is posted")
    func failedEndIsOwed() {
        var d = PipeDriver()
        d.send(pinchMsg(.began))
        d.failing = { if case .magnify(let g) = $0 { g.phase == .ended } else { false } }
        d.send(pinchMsg(.ended))
        #expect(d.pipe.owed.count == 1 && d.model.magnifyOpen)
        #expect(d.pipe.owed.isBlocking)
        // A new gesture must not open while the old end is owed (the old end would close it later).
        #expect(d.send(pinchMsg(.began)).isEmpty)
        d.send(pinchMsg(.ended))
        d.failing = { _ in false }
        d.tick(after: 300 * msec)
        #expect(d.model.isIdle && d.pipe.owed.isEmpty)
        d.tick(after: 300 * msec)
        #expect(d.send(pinchMsg(.began)).count == 2)
        #expect(d.model.violations.isEmpty && d.orderingViolations.isEmpty)
    }

    @Test("PINCH-I4 revoked permission: the end is owed and replayed when the permission is back")
    func revokedPermission() {
        var d = PipeDriver()
        d.send(pinchMsg(.began))
        d.env = noPermissionEnv
        d.send(pinchMsg(.ended))
        #expect(d.pipe.owed.count == 1)
        d.env = openEnv
        d.tick(after: 10 * msec)
        #expect(d.model.isIdle)
        #expect(d.pipe.owed.isEmpty || d.pipe.owed.isBlocking)
    }

    @Test("PINCH-I5 losing the display mid-gesture releases it at once")
    func displayLost() {
        var d = PipeDriver()
        d.send(pinchMsg(.began)); d.send(pinchMsg(.changed, scale: 0.1))
        d.env = noDisplayEnv
        d.tick(after: 10 * msec)
        #expect(d.model.isIdle)
    }

    @Test("PINCH-I6 a closing magnify event is named in the release log record")
    func releaseRecord() {
        let r = ReleaseRecord(reason: "bye", events: [magnifyEvent(.ended)])
        #expect(r.pinchEnds == 1 && r.logFields.contains("pinch=1"))
        #expect(ReleaseRecord(reason: "bye", events: [magnifyEvent(.changed, 0.1)]).pinchEnds == 0)
    }
}

@Suite("PINCH: owed slot")
struct PinchOwedTests {
    @Test("PINCH-O1 only the ended is closing, it has its own slot, and a failed began cancels an ended of the same batch")
    func slot() {
        #expect(magnifyEvent(.ended).isClosing)
        #expect(!magnifyEvent(.began).isClosing && !magnifyEvent(.changed, 0.1).isClosing)
        #expect(OwedRelease.Slot(magnifyEvent(.ended)) == .magnifyEnd)
        #expect(OwedRelease.Slot(closing: magnifyEvent(.began)) == .magnifyEnd)
        #expect(OwedRelease.Slot(magnifyEvent(.changed, 0.1)) == nil)

        var o = OwedRelease()
        o.owe([magnifyEvent(.changed, 0.1), magnifyEvent(.ended)], now: 0, countsAsAttempt: true)
        #expect(o.count == 1)
        let replay = o.replay(now: 0, force: true, geometry: testGeometry)
        #expect(replay == [magnifyEvent(.ended)])
        // Placed on the display that came back, and with the flags of the keyboard as it is now.
        var far = OwedRelease()
        far.owe([magnifyEvent(.ended, at: DisplayPoint(x: -9000, y: -9000))], now: 0, countsAsAttempt: false)
        let cmd = KeyboardSnapshot(modifiers: [.leftCommand], capsLock: false)
        #expect(far.replay(now: 0, force: true, geometry: testGeometry, keyboard: cmd)
                == [magnifyEvent(.ended, at: testGeometry.center, flags: KeyFlags(holding: [ModifierKey.leftCommand]))])
    }
}
