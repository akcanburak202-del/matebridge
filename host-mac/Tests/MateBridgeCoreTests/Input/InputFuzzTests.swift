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

private func randomDelay(_ g: inout InputFuzzRNG) -> UInt64 {
    switch Int.random(in: 0..<100, using: &g) {
    case 0..<80: return UInt64.random(in: 1...30, using: &g) * msec
    case 80..<95: return UInt64.random(in: 100...700, using: &g) * msec
    default: return UInt64.random(in: 1_000...3_000, using: &g) * msec
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
        let delay = randomDelay(&g)
        switch randomStep(&g) {
        case .message(let m):
            model.apply(d.send(m, after: delay))
            var isRelease = false
            switch m {
            case .releaseAll, .bye: isRelease = true
            default: break
            }
            check(i, "message \(m.type)", releaseExpected: isRelease)
        case .tick:
            model.apply(d.tick(after: delay))
            check(i, "tick", releaseExpected: false)
        case .release(let cause):
            d.now += delay
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
            let delay = randomDelay(&g)
            switch randomStep(&g) {
            case .message(let m): count(d.send(m, after: delay))
            case .tick: count(d.tick(after: delay))
            case .release(let cause): d.now += delay; count(d.release(cause))
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
                let delay = randomDelay(&g)
                switch randomStep(&g) {
                case .message(let m):
                    if case .pointerRel = m { lastByPointer.removeAll { if case .pointerRel = $0 { true } else { false } }; lastByPointer.append(m) }
                    if case .pointerAbs(let a) = m {
                        lastByPointer.removeAll { if case .pointerAbs(let b) = $0 { b.source == a.source } else { false } }
                        lastByPointer.append(m)
                    }
                    if case .releaseAll = m { lastByPointer.removeAll() }
                    if case .bye = m { lastByPointer.removeAll() }
                    model.apply(d.send(m, after: delay))
                case .tick: model.apply(d.tick(after: delay))
                case .release(let cause):
                    d.now += delay
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
                let delay = randomDelay(&g)
                switch randomStep(&g) {
                case .message(let m): all += d.send(m, after: delay)
                case .tick: all += d.tick(after: delay)
                case .release(let cause): d.now += delay; all += d.release(cause)
                }
            }
            return all
        }
        #expect(run() == run())
    }
}
