import Testing
@testable import MateBridgeCore

// KFUZZ-*: random KEY messages mixed with release-all, ticks (auto-repeat) and gate changes (permission, display)
// through the whole pipeline, checked against the independent event model (`MacEventModel`): no key is left down, no
// double down, no stray up, flags always match the modifiers the Mac holds, and no press overtakes an owed release.

private let fuzzScans: [UInt16] = [
    Scan.a, Scan.b, Scan.c, Scan.tab, 57,  // ordinary keys, Space
    Scan.lctrl, Scan.rctrl, Scan.lshift, Scan.lalt, Scan.ralt, Scan.lmeta,  // modifiers, several map to one side
    Scan.caps, 84, 0,  // Caps Lock, an unknown key, no scan code at all
]

private func randomKey(_ g: inout InputFuzzRNG) -> Message {
    let scan = fuzzScans.randomElement(using: &g)!
    let android: UInt16 = scan == 0 ? [29, 30, 113, 85, 0].randomElement(using: &g)! : 0  // alias of A, B, Ctrl
    let action: KeyAction = Bool.random(using: &g) ? .down : .up
    return keyMsg(scan, action, caps: Bool.random(using: &g), android: android)
}

private func randomGate(_ g: inout InputFuzzRNG) -> InjectionEnvironment {
    var env: InjectionEnvironment
    switch Int.random(in: 0..<8, using: &g) {
    case 0: env = InjectionEnvironment(canInject: false, geometry: testGeometry)
    case 1: env = InjectionEnvironment(canInject: true, geometry: nil)
    default: env = openEnv
    }
    env.capsLockOn = Bool.random(using: &g)
    return env
}

private func runKeyboardSequence(seed: UInt64, steps: Int) -> [String] {
    var g = InputFuzzRNG(seed: seed)
    var d = PipeDriver()
    var failures: [String] = []

    func check(_ step: Int, _ label: String) {
        if !d.model.violations.isEmpty { failures.append("seed \(seed) step \(step) \(label): \(d.model.violations)") }
        if !d.orderingViolations.isEmpty { failures.append("seed \(seed) step \(step) \(label): \(d.orderingViolations)") }
    }

    for i in 0..<steps {
        d.env = randomGate(&g)
        let after = UInt64.random(in: 0...900, using: &g) * msec
        switch Int.random(in: 0..<100, using: &g) {
        case 0..<60:
            d.send(randomKey(&g), after: after)
            check(i, "key")
        case 60..<80:
            d.tick(after: after)
            check(i, "tick")
        case 80..<88:
            d.send(.releaseAll(ReleaseReason(rawValue: UInt8.random(in: 0...4, using: &g))), after: after)
            check(i, "release-all message")
        case 88..<94:
            d.release(allReleaseCauses.randomElement(using: &g)!)
            check(i, "release")
            d.release(.shutdown)  // idempotent
            check(i, "release again")
        case 94..<97:
            d.endSession()
            check(i, "session end")
            d.startSession()
        default:
            // A key with a pointer button and a pen in the mix: the keyboard must not disturb their state.
            d.send(absMsg(.mouse, 500, 600, Bool.random(using: &g) ? .left : []), after: after)
            check(i, "pointer")
        }
    }

    // Everything comes back: permission, display. A release-all then leaves nothing held anywhere.
    d.env = openEnv
    for _ in 0..<12 { d.tick(after: 2_000 * msec) }
    d.release(.shutdown)
    for _ in 0..<12 { d.tick(after: 2_000 * msec) }
    check(steps, "final")
    if !d.model.keys.isEmpty || !d.model.modifiers.isEmpty {
        failures.append("seed \(seed): keys \(d.model.keys) modifiers \(d.model.modifiers) still down at the end")
    }
    if d.pipe.isHoldingInput { failures.append("seed \(seed): pipeline still holds input") }
    if !d.pipe.owed.isEmpty { failures.append("seed \(seed): releases still owed") }
    return failures
}

@Suite("KFUZZ: random keyboard sequences never leave a key down")
struct KeyboardFuzzTests {
    @Test("KFUZZ-1 500 random sequences with release-all and gate changes: no key left down, no double down, consistent flags")
    func kfuzz1_sequences() {
        var failures: [String] = []
        for seed in 1...500 {
            failures += runKeyboardSequence(seed: UInt64(seed) &* 104_729, steps: 250)
            if failures.count > 5 { break }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5).joined(separator: "\n"))")
    }

    @Test("KFUZZ-2 the state machine alone: release-all always leaves nothing held and downs equal ups")
    func kfuzz2_machineBalance() {
        var g = InputFuzzRNG(seed: 0xCAFE)
        var d = Driver()
        var model = MacInputModel()
        for _ in 0..<20_000 {
            let delay = Int64.random(in: 0...700, using: &g) * Int64(msec)
            switch Int.random(in: 0..<10, using: &g) {
            case 0..<7: model.apply(d.send(randomKey(&g), delta: delay))
            case 7, 8: model.apply(d.tick(delta: delay))
            default:
                d.jump(delay)
                model.apply(d.release(allReleaseCauses.randomElement(using: &g)!))
                #expect(model.isIdle && !d.machine.hasHeldInput && model.violations.isEmpty)
            }
        }
        #expect(model.violations.isEmpty, "\(model.violations.prefix(3))")
        model.apply(d.release(.shutdown))
        #expect(model.isIdle)
    }
}
