import Testing
@testable import MateBridgeCore

// KEY-REPEAT-STALL (T-163): the host's key auto-repeat pauses while the control connection has been silent for more
// than `keyRepeatStallPauseUs`, without an UP and without touching the held keys, and resumes one interval after the
// next activity. The host notes a record's activity AFTER handling it, so the tests do the same (`record`).

private let repeatA = InjectAction.keyDown(keyCode: 0x00, autorepeat: true)

private func repeats(_ actions: [InjectAction]) -> Int {
    actions.filter { if case .keyDown(_, true) = $0 { true } else { false } }.count
}

/// The host's order for a record of the active session: handle it (watchdogs first), then note its activity.
private extension Driver {
    @discardableResult
    mutating func record(_ message: Message, after: UInt64 = 1 * msec) -> [InjectAction] {
        let out = send(message, after: after)
        machine.noteControlActivity(at: now)
        return out
    }

    /// A record that is not input (PING): only its activity.
    @discardableResult
    mutating func ping(after: UInt64) -> Bool {
        now += after
        return machine.noteControlActivity(at: now)
    }

    /// Ticks every `step` for `duration` (the timer of a busy host), collecting what came out.
    mutating func run(for duration: UInt64, step: UInt64 = 1 * msec) -> [InjectAction] {
        var out: [InjectAction] = []
        var elapsed: UInt64 = 0
        while elapsed < duration {
            out += tick(after: step)
            elapsed += step
        }
        return out
    }
}

private func defaults() -> InputStateMachine.Configuration {
    var c = InputStateMachine.Configuration()
    c.keyRepeatDelayUs = 500 * msec
    c.keyRepeatIntervalUs = 83 * msec
    return c
}

@Suite("KEY-REPEAT-STALL: key repeat pauses while the control connection is silent")
struct KeyRepeatStallTests {
    @Test("STALL-1 no repeat while the connection has been silent for more than 600 ms; the key stays held, no UP")
    func stall1_pause() {
        var d = Driver(configuration: defaults())
        #expect(d.machine.configuration.keyRepeatStallPauseUs == 600 * msec)
        d.record(keyDown(Scan.a))
        // Repeats at +500 and +583 (the connection is 583 ms silent: still within 600 ms). +666 is past the pause.
        let out = d.run(for: 3_000 * msec)
        #expect(out == [repeatA, repeatA])
        #expect(d.machine.keyCounters.repeats == 2)
        #expect(d.machine.isKeyRepeatPaused(at: d.now))
        #expect(d.machine.hasHeldInput)  // still held: the pause produces no UP
        #expect(!out.contains(.keyUp(keyCode: 0x00)))
    }

    @Test("STALL-1b PINGs every 500 ms keep a normal hold repeating at the interval, as before")
    func stall1b_steadyHold() {
        var d = Driver(configuration: defaults())
        d.record(keyDown(Scan.a))
        var total = 0
        for _ in 0..<6 {  // 3 s of hold with a PING every 500 ms
            total += repeats(d.run(for: 500 * msec))
            d.ping(after: 0)
        }
        // From +500 to +3000 at 83 ms: 31 repeats (500, 583, ..., 2990).
        #expect(total == 31)
        #expect(!d.machine.isKeyRepeatPaused(at: d.now))
    }

    @Test("STALL-1c the pause starts after MORE than 600 ms: exactly 600 ms is still active")
    func stall1c_boundary() {
        var d = Driver(configuration: defaults())
        d.record(keyDown(Scan.a))
        let at = d.now
        #expect(!d.machine.isKeyRepeatPaused(at: at + 600 * msec))
        #expect(d.machine.isKeyRepeatPaused(at: at + 600 * msec + 1))
    }

    @Test("STALL-2 the repeat resumes after new activity, the first repeat a whole interval later (no burst)")
    func stall2_resume() {
        var d = Driver(configuration: defaults())
        d.record(keyDown(Scan.a))
        _ = d.run(for: 1_400 * msec)  // stall: 2 repeats, then paused
        #expect(d.machine.keyCounters.repeats == 2)
        #expect(d.machine.isKeyRepeatPaused(at: d.now))
        let resumed = d.ping(after: 0)  // ends the pause
        #expect(resumed)
        let resumedAt = d.now
        #expect(!d.machine.isKeyRepeatPaused(at: d.now))
        #expect(d.machine.nextDeadline(now: d.now) == resumedAt + 83 * msec)
        #expect(d.tick(after: 0) == [])  // the overdue repeat is not fired at once
        #expect(d.tick(after: 82 * msec) == [])
        #expect(d.tick(after: 1 * msec) == [repeatA])
        #expect(d.machine.nextDeadline(now: d.now) == resumedAt + 166 * msec)
        // Ongoing activity: back to the plain interval.
        d.ping(after: 10 * msec)
        #expect(repeats(d.run(for: 300 * msec)) == 3)  // +166, +249, +332 from resume (the run ends at +393)
    }

    @Test("STALL-2b a late timer after resume still gives one repeat per call, not a burst")
    func stall2b_noBurstAfterResume() {
        var d = Driver(configuration: defaults())
        d.record(keyDown(Scan.a))
        _ = d.run(for: 1_400 * msec)
        d.ping(after: 0)
        // The timer runs 400 ms late, the connection stays alive meanwhile (activity 1 ms before the tick).
        d.ping(after: 399 * msec)
        #expect(d.tick(after: 1 * msec) == [repeatA])
        #expect(d.tick(after: 0) == [])
    }

    @Test("STALL-2c a note while not paused changes no repeat deadline and reports no resume")
    func stall2c_noteWhileActive() {
        var d = Driver(configuration: defaults())
        d.record(keyDown(Scan.a))
        let due = d.machine.nextDeadline(now: d.now)
        let resumedEarly = d.ping(after: 300 * msec)
        #expect(!resumedEarly)
        #expect(d.machine.nextDeadline(now: d.now) == due)
        // No repeat armed at all: never a resume either.
        var idle = Driver(configuration: defaults())
        idle.ping(after: 0)
        let resumedIdle = idle.ping(after: 5_000 * msec)
        #expect(!resumedIdle)
    }

    @Test("STALL-3 a delayed KEY UP that ends a stall gives the key-up and no repeat before it")
    func stall3_delayedUp() {
        var d = Driver(configuration: defaults())
        d.record(keyDown(Scan.a))
        _ = d.run(for: 600 * msec)  // two repeats while the connection was fresh
        let before = d.machine.keyCounters.repeats
        #expect(before == 2)
        // 900 ms more of silence with the timer stopped (no deadline while paused), then the UP arrives.
        let up = d.record(keyUp(Scan.a), after: 900 * msec)
        #expect(withoutCaps(up) == [.keyUp(keyCode: 0x00)])
        #expect(d.machine.keyCounters.repeats == before)
        #expect(!d.machine.hasHeldInput)
        #expect(d.machine.nextDeadline(now: d.now) == nil)
    }

    @Test("STALL-3b the same through the timer: ticks during the stall emit nothing, the UP then releases")
    func stall3b_delayedUpWithTicks() {
        var d = Driver(configuration: defaults())
        d.record(keyDown(Scan.a))
        let during = d.run(for: 1_300 * msec)
        #expect(repeats(during) == 2)  // +500 and +583 only
        let up = d.record(keyUp(Scan.a), after: 50 * msec)
        #expect(withoutCaps(up) == [.keyUp(keyCode: 0x00)])
    }

    @Test("STALL-4 while paused, UP, another DOWN and release-all stop the repeat and release exactly as before")
    func stall4_stopsWhilePaused() {
        // Another DOWN: no repeat of the old key, the new key goes down and repeats after its own delay.
        var d = Driver(configuration: defaults())
        d.record(keyDown(Scan.a))
        _ = d.run(for: 1_000 * msec)
        #expect(d.machine.isKeyRepeatPaused(at: d.now))
        let b = d.record(keyDown(Scan.b), after: 200 * msec)
        #expect(withoutCaps(b) == [.keyDown(keyCode: 0x0B, autorepeat: false)])
        let bAt = d.now
        #expect(d.machine.nextDeadline(now: d.now) == bAt + 500 * msec)
        d.ping(after: 400 * msec)
        #expect(d.tick(after: 100 * msec) == [.keyDown(keyCode: 0x0B, autorepeat: true)])
        // Both keys are still held; their UPs release them (a no longer repeats).
        #expect(withoutCaps(d.record(keyUp(Scan.a))) == [.keyUp(keyCode: 0x00)])
        #expect(withoutCaps(d.record(keyUp(Scan.b))) == [.keyUp(keyCode: 0x0B)])
        #expect(!d.machine.hasHeldInput)

        // Release-all (message or host cause) while paused: key up, no repeat afterwards even with activity.
        for cause in allReleaseCauses {
            var r = Driver(configuration: defaults())
            r.record(keyDown(Scan.lshift))
            r.record(keyDown(Scan.a))
            _ = r.run(for: 1_000 * msec)
            #expect(r.machine.isKeyRepeatPaused(at: r.now))
            #expect(r.release(cause) == [.keyUp(keyCode: 0x00), .modifierUp(.leftShift)])
            #expect(!r.machine.hasHeldInput)
            let resumedAfterRelease = r.ping(after: 10 * msec)
            #expect(!resumedAfterRelease)
            #expect(r.machine.nextDeadline(now: r.now) == nil)
            #expect(r.run(for: 2_000 * msec) == [])
        }
        var m = Driver(configuration: defaults())
        m.record(keyDown(Scan.a))
        _ = m.run(for: 1_000 * msec)
        let released = m.record(.releaseAll(.user), after: 100 * msec)
        #expect(released == [.keyUp(keyCode: 0x00)])
    }

    @Test("STALL-5 while paused nextDeadline returns no overdue repeat deadline; other watchdogs keep theirs")
    func stall5_nextDeadline() {
        var d = Driver(configuration: defaults())
        d.record(keyDown(Scan.a))
        _ = d.run(for: 1_000 * msec)
        for _ in 0..<5 {
            #expect(d.machine.nextDeadline(now: d.now) == nil)
            d.now += 100 * msec
        }
        // A pen in range still has its own watchdog deadline while the key repeat is paused.
        d.send(penMsg(.pen, penSample(100, 100, [.inRange])), after: 0)
        let penAt = d.now
        #expect(d.machine.nextDeadline(now: d.now) == penAt + 500 * msec)
    }

    @Test("STALL-6 without any noted activity the repeat never pauses (behaviour before T-163)")
    func stall6_noInformation() {
        var d = Driver(configuration: defaults())
        d.send(keyDown(Scan.a))
        #expect(d.machine.lastControlActivity == nil)
        #expect(repeats(d.run(for: 3_000 * msec, step: 83 * msec)) > 20)
    }

    @Test("STALL-7 activity ahead of a clock that went backwards is re-anchored: no pause, no stall of the repeat")
    func stall7_backwardsClock() {
        var d = Driver(configuration: defaults())
        d.record(keyDown(Scan.a))
        d.jump(-5_000 * Int64(msec))
        #expect(!d.machine.isKeyRepeatPaused(at: d.now))
        let due = d.machine.nextDeadline(now: d.now)
        #expect(due != nil && due! <= d.now + 500 * msec)
        #expect(d.machine.lastControlActivity == d.now)
        d.now = due!
        #expect(d.machine.tick(now: d.now) == [repeatA])
    }
}

@Suite("KEY-REPEAT-STALL through the pipeline")
struct KeyRepeatStallPipelineTests {
    private static func isRepeat(_ e: MacEvent) -> Bool {
        if case .key(let k) = e { k.isRepeat } else { false }
    }

    @Test("SPIPE-1 the pipeline forwards activity; the heartbeat-silence release while paused releases the key")
    func spipe1_heartbeatRelease() {
        var d = PipeDriver()
        d.send(keyDown(Scan.a))
        d.pipe.noteControlActivity(at: d.now)
        let ticks = (0..<14).flatMap { _ in d.tick(after: 100 * msec) }  // 1.4 s of silence
        #expect(ticks.filter(Self.isRepeat).count == 2)
        #expect(d.pipe.nextDeadline(now: d.now) == nil)
        d.tick(after: 100 * msec)
        // SessionMachine's 1.5 s silence release, exactly as before.
        let released = d.release(.silence)
        #expect(released.contains(.key(MacKey(kind: .keyUp, keyCode: 0x00, flags: []))))
        #expect(d.model.isIdle && d.model.violations.isEmpty)
        #expect(!d.pipe.isHoldingInput)
    }

    @Test("SPIPE-2 no session: a note does nothing and reports no resume")
    func spipe2_noSession() {
        var pipe = InputPipeline()
        let resumed = pipe.noteControlActivity(at: 1_000_000)
        #expect(!resumed)
        #expect(pipe.machine == nil)
    }

    @Test("SPIPE-3 a fresh session's machine starts without activity: nothing of the last session's silence carries over")
    func spipe3_freshSession() {
        var d = PipeDriver()
        d.pipe.noteControlActivity(at: d.now)
        d.now += 10_000 * msec
        d.endSession()
        d.startSession()
        #expect(d.pipe.machine?.lastControlActivity == nil)
        d.send(keyDown(Scan.a))
        #expect(d.tick(after: 500 * msec).filter(Self.isRepeat).count == 1)
    }

    @Test("SPIPE-4 random keys, PINGs, stalls and releases: never a repeat after 600 ms of silence, nothing stuck")
    func spipe4_fuzz() {
        for seed in UInt64(1)...40 {
            var g = InputFuzzRNG(seed: seed)
            var d = PipeDriver()
            var lastActivity: UInt64?
            var failures: [String] = []
            func note() {
                d.pipe.noteControlActivity(at: d.now)
                lastActivity = d.now
            }
            func checkRepeats(_ events: [MacEvent], _ label: String) {
                guard events.contains(where: Self.isRepeat), let last = lastActivity else { return }
                if d.now - last > 600 * msec { failures.append("seed \(seed) \(label): repeat after \(d.now - last) us") }
            }
            for step in 0..<400 {
                let after = UInt64.random(in: 0...400, using: &g) * msec
                switch Int.random(in: 0..<100, using: &g) {
                case 0..<35:
                    let scan = [Scan.a, Scan.b, Scan.lshift].randomElement(using: &g)!
                    let msg = Bool.random(using: &g) ? keyDown(scan) : keyUp(scan)
                    checkRepeats(d.send(msg, after: after), "key \(step)")  // handled with the activity before it
                    note()
                case 35..<60:
                    d.now += after
                    note()  // PING
                case 60..<92:
                    checkRepeats(d.tick(after: after), "tick \(step)")
                case 92..<97:
                    checkRepeats(d.tick(after: 1_000 * msec), "stall \(step)")
                default:
                    d.release(allReleaseCauses.randomElement(using: &g)!)
                }
                if !d.model.violations.isEmpty { failures.append("seed \(seed) step \(step): \(d.model.violations)") }
            }
            d.release(.shutdown)
            if !d.model.isIdle || d.pipe.isHoldingInput { failures.append("seed \(seed): input still held at the end") }
            #expect(failures.isEmpty, "\(failures.prefix(5))")
        }
    }
}
