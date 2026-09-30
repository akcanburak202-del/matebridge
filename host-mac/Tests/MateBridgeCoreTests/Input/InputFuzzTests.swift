import Testing
@testable import MateBridgeCore

// FUZZ-*: seeded random message sequences with random release-alls and ticks, checked against an independent
// model of the Mac (`MacInputModel`) that is built only from the emitted `InjectAction`s.

/// Deterministic generator so a failing seed reproduces.
struct InputFuzzRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private enum Step {
    case message(Message)
    case tick
    case release(ReleaseCause)
}

private func randomButtons(_ g: inout InputFuzzRNG) -> PointerButtons {
    switch Int.random(in: 0..<10, using: &g) {
    case 0, 1: return []
    case 2, 3, 4: return .left
    case 5: return .right
    case 6: return [.left, .right]
    case 7: return .middle
    case 8: return PointerButtons(rawValue: UInt8.random(in: 0...0x1F, using: &g))
    default: return PointerButtons(rawValue: UInt8.random(in: 0...0xFF, using: &g))  // undefined bits too
    }
}

private func randomPenFlags(_ g: inout InputFuzzRNG) -> PenFlags {
    switch Int.random(in: 0..<14, using: &g) {
    case 0, 1: return []
    case 2, 3, 4: return .inRange
    case 5, 6, 7: return [.inRange, .contact]
    case 8, 9: return [.inRange, .contact, .strokeStart]
    case 10: return [.inRange, .contact, .button]
    default: return PenFlags(rawValue: UInt8.random(in: 0...0x0F, using: &g))  // includes invalid combinations
    }
}

private func randomPenMessage(_ g: inout InputFuzzRNG) -> Message {
    let tool: PenTool = Int.random(in: 0..<10, using: &g) < 7 ? .pen : .eraser
    let count = Int.random(in: 1...4, using: &g)
    var samples: [PenSample] = []
    for i in 0..<count {
        samples.append(PenSample(dtUs: UInt32(i) * 3000, x: UInt16.random(in: 0...3, using: &g) * 1000,
                                 y: UInt16.random(in: 0...3, using: &g) * 1000,
                                 pressure: UInt16.random(in: 0...65535, using: &g),
                                 tiltX: Int16.random(in: -32768...32767, using: &g),
                                 tiltY: Int16.random(in: -32768...32767, using: &g),
                                 flags: randomPenFlags(&g)))
    }
    return .pen(PenBatch(tool: tool, baseTimeUs: 0, samples: samples))
}

private func randomStep(_ g: inout InputFuzzRNG) -> Step {
    switch Int.random(in: 0..<100, using: &g) {
    case 0..<30: return .message(randomPenMessage(&g))
    case 30..<42:
        let dx = Float(Int.random(in: -3...3, using: &g)), dy = Float(Int.random(in: -3...3, using: &g))
        return .message(relMsg(dx, dy, randomButtons(&g)))
    case 42..<54: return .message(absMsg(.touch, UInt16.random(in: 0...9, using: &g), 7, randomButtons(&g)))
    case 54..<64: return .message(absMsg(.mouse, UInt16.random(in: 0...9, using: &g), 8, randomButtons(&g)))
    case 64..<74:
        let phase = ScrollPhase(rawValue: UInt8.random(in: 0...4, using: &g))!
        return .message(scrollMsg(phase, 1, 2))
    case 74..<78: return .message(doubleTap)
    case 78..<80: return .message(.penGesture(PenGesture(timeUs: 0, gesture: PenGestureKind(rawValue: 7))))
    case 80..<83: return .message(.releaseAll(ReleaseReason(rawValue: UInt8.random(in: 0...4, using: &g))))
    case 83..<84: return .message(.bye(.normal))
    case 84..<86: return .release(allReleaseCauses.randomElement(using: &g)!)
    default: return .tick
    }
}

/// A signed clock step in microseconds: mostly small forward steps, but also zero, backwards and long ones.
private func randomDelta(_ g: inout InputFuzzRNG) -> Int64 {
    switch Int.random(in: 0..<100, using: &g) {
    case 0..<5: return 0
    case 5..<10: return -Int64.random(in: 1...800, using: &g) * Int64(msec)
    case 10..<75: return Int64.random(in: 1...30, using: &g) * Int64(msec)
    case 75..<93: return Int64.random(in: 100...700, using: &g) * Int64(msec)
    default: return Int64.random(in: 1_000...3_000, using: &g) * Int64(msec)
    }
}

/// Runs one random sequence and checks every invariant after every step.
private func runSequence(seed: UInt64, steps: Int) -> [String] {
    var g = InputFuzzRNG(seed: seed)
    var d = Driver()
    var model = MacInputModel()
    var failures: [String] = []

    func check(_ step: Int, _ label: String, releaseExpected: Bool) {
        if !model.violations.isEmpty { failures.append("seed \(seed) step \(step) \(label): \(model.violations)") }
        if d.machine.hasHeldInput == model.isIdle {
            failures.append("seed \(seed) step \(step) \(label): machine held=\(d.machine.hasHeldInput) model idle=\(model.isIdle)")
        }
        if d.machine.isPenInRange != (model.proximity != nil) || d.machine.isPenInContact != model.penContact {
            failures.append("seed \(seed) step \(step) \(label): pen state mismatch")
        }
        if releaseExpected && (!model.isIdle || d.machine.hasHeldInput) {
            failures.append("seed \(seed) step \(step) \(label): still holding after release-all")
        }
    }

    for i in 0..<steps {
        let delay = randomDelta(&g)
        switch randomStep(&g) {
        case .message(let m):
            model.apply(d.send(m, delta: delay))
            var isRelease = false
            switch m {
            case .releaseAll, .bye: isRelease = true
            default: break
            }
            check(i, "message \(m.type)", releaseExpected: isRelease)
        case .tick:
            model.apply(d.tick(delta: delay))
            check(i, "tick", releaseExpected: false)
        case .release(let cause):
            d.jump(delay)
            model.apply(d.release(cause))
            check(i, "release \(cause)", releaseExpected: true)
            model.apply(d.release(cause))  // idempotent
            check(i, "release again", releaseExpected: true)
        }
    }
    model.apply(d.release(.shutdown))
    check(steps, "final release", releaseExpected: true)
    return failures
}

@Suite("FUZZ: random sequences keep the Mac's input consistent")
struct InputFuzzTests {
    @Test("FUZZ-1 500 random sequences: model consistency, no double down or stray up, nothing held after release-all")
    func fuzz1_randomSequences() {
        var failures: [String] = []
        for seed in 1...500 {
            failures += runSequence(seed: UInt64(seed), steps: 200)
            if failures.count > 5 { break }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5).joined(separator: "\n"))")
    }

    @Test("FUZZ-2 every down has an up: counts balance at the end of long random runs")
    func fuzz2_downsEqualUps() {
        var g = InputFuzzRNG(seed: 0xD00D)
        var d = Driver()
        var counts = (penDown: 0, penUp: 0, enter: 0, leave: 0, buttonDown: 0, buttonUp: 0, began: 0, ended: 0)
        func count(_ actions: [InjectAction]) {
            for a in actions {
                switch a {
                case .penDown: counts.penDown += 1
                case .penUp: counts.penUp += 1
                case .penProximity(_, let entering): if entering { counts.enter += 1 } else { counts.leave += 1 }
                case .mouseButton(_, let down): if down { counts.buttonDown += 1 } else { counts.buttonUp += 1 }
                case .scroll(let phase, _, _):
                    if phase == .began { counts.began += 1 } else if phase != .changed { counts.ended += 1 }
                default: break
                }
            }
        }
        for _ in 0..<20_000 {
            let delay = randomDelta(&g)
            switch randomStep(&g) {
            case .message(let m): count(d.send(m, delta: delay))
            case .tick: count(d.tick(delta: delay))
            case .release(let cause): d.jump(delay); count(d.release(cause))
            }
        }
        count(d.release(.shutdown))
        #expect(counts.penDown == counts.penUp)
        #expect(counts.enter == counts.leave)
        #expect(counts.buttonDown == counts.buttonUp)
        #expect(counts.began == counts.ended)
        #expect(counts.penDown > 100 && counts.buttonDown > 100 && counts.began > 100)  // the run exercised something
    }

    @Test("FUZZ-3 after a release-all, replaying the last reported state never starts a press or stroke")
    func fuzz3_staleReplayAfterRelease() {
        var failures: [String] = []
        for seed in 1...300 {
            var g = InputFuzzRNG(seed: UInt64(seed) &* 7919)
            var d = Driver()
            var model = MacInputModel()
            var lastByPointer: [Message] = []
            for _ in 0..<80 {
                let delay = randomDelta(&g)
                switch randomStep(&g) {
                case .message(let m):
                    if case .pointerRel = m { lastByPointer.removeAll { if case .pointerRel = $0 { true } else { false } }; lastByPointer.append(m) }
                    if case .pointerAbs(let a) = m {
                        lastByPointer.removeAll { if case .pointerAbs(let b) = $0 { b.source == a.source } else { false } }
                        lastByPointer.append(m)
                    }
                    if case .releaseAll = m { lastByPointer.removeAll() }
                    if case .bye = m { lastByPointer.removeAll() }
                    model.apply(d.send(m, delta: delay))
                case .tick: model.apply(d.tick(delta: delay))
                case .release(let cause):
                    d.jump(delay)
                    model.apply(d.release(cause))
                    lastByPointer.removeAll()
                }
            }
            model.apply(d.release(.disconnected))
            // Stale traffic: each pointer source repeats its last state, both pen tools repeat mid-stroke contact.
            var stale: [Message] = lastByPointer
            for tool in [PenTool.pen, .eraser] {
                stale.append(penMsg(tool, penSample(5, 5, touchFlags, pressure: 500), penSample(6, 6, touchFlags, pressure: 600)))
            }
            for m in stale + stale {
                let out = d.send(m, after: 2 * msec)
                model.apply(out)
                for a in out {
                    switch a {
                    case .penDown, .penDrag: failures.append("seed \(seed): pen contact from stale samples: \(a)")
                    case .mouseButton(_, true): failures.append("seed \(seed): press from a stale message: \(a)")
                    default: break
                    }
                }
            }
            if !model.violations.isEmpty { failures.append("seed \(seed): \(model.violations)") }
            model.apply(d.release(.shutdown))
            if !model.isIdle { failures.append("seed \(seed): not idle after final release") }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5).joined(separator: "\n"))")
    }

    @Test("FUZZ-4 the machine is deterministic: the same sequence yields the same actions")
    func fuzz4_deterministic() {
        func run() -> [InjectAction] {
            var g = InputFuzzRNG(seed: 42)
            var d = Driver()
            var all: [InjectAction] = []
            for _ in 0..<500 {
                let delay = randomDelta(&g)
                switch randomStep(&g) {
                case .message(let m): all += d.send(m, delta: delay)
                case .tick: all += d.tick(delta: delay)
                case .release(let cause): d.jump(delay); all += d.release(cause)
                }
            }
            return all
        }
        #expect(run() == run())
    }

    @Test("FUZZ-5 tick acts exactly at nextDeadline(now:): not 1 us before, never when nil, also right after the clock went backwards")
    func fuzz5_nextDeadlineIsExact() {
        var failures: [String] = []
        for seed in 1...400 {
            var g = InputFuzzRNG(seed: UInt64(seed) &* 977)
            var d = Driver()
            for step in 0..<150 {
                let delta = randomDelta(&g)
                switch randomStep(&g) {
                case .message(let m): d.send(m, delta: delta)
                case .tick: d.tick(delta: delta)
                case .release(let cause): d.jump(delta); d.release(cause)
                }
                // Probe at the current time, and at a time that is behind every stored timestamp (the first look
                // at a backwards clock is the nextDeadline call itself, with no handle/tick before it).
                let behind = d.now - Swift.min(d.now, UInt64.random(in: 1...3_000, using: &g) * msec)
                for probeNow in [d.now, behind] {
                    var m = d.machine
                    if let due = m.nextDeadline(now: probeNow) {
                        guard due > probeNow else {
                            failures.append("seed \(seed) step \(step): deadline \(due) not after \(probeNow)")
                            continue
                        }
                        var early = m
                        if !early.tick(now: due - 1).isEmpty { failures.append("seed \(seed) step \(step): acts before the deadline") }
                        var exact = m
                        if exact.tick(now: due).isEmpty { failures.append("seed \(seed) step \(step): silent at the deadline") }
                        // Never later than one period after the observation (PROTOCOL.md section 7).
                        let period = Swift.max(m.configuration.penWatchdogUs, m.configuration.scrollWatchdogUs)
                        if due - probeNow > period { failures.append("seed \(seed) step \(step): deadline more than a period away") }
                    } else {
                        var far = m
                        if !far.tick(now: probeNow + 3_600_000_000).isEmpty { failures.append("seed \(seed) step \(step): nil deadline but tick acts") }
                        if m.isPenInRange || m.scrollOpen { failures.append("seed \(seed) step \(step): armed state without a deadline") }
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5).joined(separator: "\n"))")
    }

    @Test("FUZZ-6 handle() equals tick() followed by the message: the timer's timing never changes the result")
    func fuzz6_watchdogBeforeMessage() {
        var failures: [String] = []
        for seed in 1...300 {
            var g = InputFuzzRNG(seed: UInt64(seed) &* 4243)
            var withTick = Driver()
            var withoutTick = Driver()
            for step in 0..<150 {
                let delta = randomDelta(&g)
                switch randomStep(&g) {
                case .message(let m):
                    withTick.jump(delta)
                    withoutTick.jump(delta)
                    let a = withTick.machine.tick(now: withTick.now) + withTick.machine.handle(m, now: withTick.now)
                    let b = withoutTick.machine.handle(m, now: withoutTick.now)
                    if a != b { failures.append("seed \(seed) step \(step): \(a) vs \(b)") }
                case .tick:
                    if withTick.tick(delta: delta) != withoutTick.tick(delta: delta) { failures.append("seed \(seed) step \(step): tick differs") }
                case .release(let cause):
                    withTick.jump(delta)
                    withoutTick.jump(delta)
                    if withTick.release(cause) != withoutTick.release(cause) { failures.append("seed \(seed) step \(step): release differs") }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5).joined(separator: "\n"))")
    }

    @Test("FUZZ-7 latch oracle: from session start and after any release-all, no down or drag for a latched tool before CONTACT=0 or STROKE_START")
    func fuzz7_latchOracle() {
        var failures: [String] = []
        for seed in 1...600 {
            var g = InputFuzzRNG(seed: UInt64(seed) &* 31337)
            var d = Driver()
            var latched: Set<PenTool> = [.pen, .eraser]  // a fresh machine starts latched
            for _ in 0..<120 {
                let delta = randomDelta(&g)
                switch Int.random(in: 0..<10, using: &g) {
                case 0:
                    d.jump(delta)
                    d.release(allReleaseCauses.randomElement(using: &g)!)
                    latched = [.pen, .eraser]
                case 1:
                    d.tick(delta: delta)
                default:
                    let tool: PenTool = Int.random(in: 0..<4, using: &g) == 0 ? .eraser : .pen
                    let candidates: [PenFlags] = [[], .inRange, [.inRange, .contact], [.inRange, .contact, .strokeStart], .contact]
                    let flags = candidates.randomElement(using: &g)!
                    let normalized = flags.normalized
                    let contact = normalized.contains(.contact) && normalized.contains(.inRange)
                    let start = contact && normalized.contains(.strokeStart)
                    let wasLatched = latched.contains(tool)
                    let out = d.send(penMsg(tool, penSample(1, 1, flags, pressure: 50)), delta: delta)
                    if wasLatched && !start {
                        for a in out {
                            switch a {
                            case .penDown, .penDrag: failures.append("seed \(seed): \(a) while \(tool) latched, flags \(flags)")
                            default: break
                            }
                        }
                    }
                    if !contact || start { latched.remove(tool) }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5).joined(separator: "\n"))")
    }
}
