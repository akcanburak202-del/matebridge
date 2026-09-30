import Testing
@testable import MateBridgeCore

// WELL-*: a simulated well-behaved tablet client. The action-replay model in the fuzz tests can only see what the
// machine emitted; it cannot see input the machine wrongly swallowed. This client knows what it pressed and lifted:
// it releases everything it pressed and lifts the pen, and it is not told about host-initiated release-alls
// (silence, takeover, ...). Afterwards the Mac must be idle with NO final release-all, and every press or stroke the
// protocol says must be accepted must have produced its action.

struct WellFormedSimClient {
    enum PenPhase { case out, hover, contact }

    /// How release-alls happen in a run.
    enum Mode: CaseIterable {
        /// Only the host releases (silence, takeover, ...); the client is unaware.
        case hostReleases
        /// Only the client sends RELEASE_ALL, following the PROTOCOL.md section 7 client obligations.
        case clientReleases
        /// Both.
        case both
    }

    var g: InputFuzzRNG
    var d = Driver()
    var model = MacInputModel()
    var failures: [String] = []
    let label: String
    let mode: Mode

    var penPhase = PenPhase.out
    var penTool = PenTool.pen
    var reported: [PtrSource: PointerButtons] = [.rel: [], .mouse: [], .touch: []]
    var scrolling = false
    var lastPenMessageAt: UInt64?

    init(seed: UInt64, mode: Mode) {
        g = InputFuzzRNG(seed: seed &* 2654435761 &+ 17)
        label = "seed \(seed) \(mode)"
        self.mode = mode
    }

    mutating func fail(_ text: String) { failures.append("\(label): \(text)") }

    private mutating func coin(_ percent: Int) -> Bool { Int.random(in: 0..<100, using: &g) < percent }

    @discardableResult
    private mutating func deliver(_ message: Message, after delay: UInt64) -> [InjectAction] {
        let out = d.send(message, after: delay)
        model.apply(out)
        return out
    }

    private static func isDown(_ a: InjectAction) -> Bool {
        if case .penDown = a { true } else { false }
    }

    // MARK: Client behaviour

    private mutating func sendPen(_ flags: PenFlags, tool: PenTool, samples: Int = 1, after delay: UInt64) {
        var list: [PenSample] = []
        for i in 0..<samples {
            var f = flags
            if i > 0 { f.remove(.strokeStart) }
            var s = penSample(UInt16(3 + i), 4, f, pressure: f.contains(.contact) ? 77 : 0)
            s.dtUs = UInt32(i) * 3000
            list.append(s)
        }
        let out = deliver(.pen(PenBatch(tool: tool, baseTimeUs: 0, samples: list)), after: delay)
        lastPenMessageAt = d.now
        // A real stroke start must always draw, whatever the host state was (latch, watchdog, owner, tool change).
        if flags.contains(.strokeStart) && !out.contains(where: Self.isDown) { fail("STROKE_START did not start a stroke") }
    }

    private mutating func penStep(after delay: UInt64) {
        let other: PenTool = penTool == .pen ? .eraser : .pen
        switch penPhase {
        case .out:
            penTool = coin(25) ? .eraser : .pen
            penPhase = .hover
            sendPen(.inRange, tool: penTool, after: delay)
        case .hover:
            switch Int.random(in: 0..<8, using: &g) {
            case 0:
                penPhase = .out
                sendPen([], tool: penTool, after: delay)
            case 1:  // tool switch while hovering: the old tool leaves, the new one comes in
                sendPen([], tool: penTool, after: delay)
                penTool = other
                sendPen(.inRange, tool: penTool, after: 1 * msec)
            case 2, 3, 4:
                penPhase = .contact
                sendPen([.inRange, .contact, .strokeStart], tool: penTool, samples: Int.random(in: 1...3, using: &g), after: delay)
            default:
                sendPen(.inRange, tool: penTool, samples: Int.random(in: 1...2, using: &g), after: delay)
            }
        case .contact:
            switch Int.random(in: 0..<7, using: &g) {
            case 0:
                penPhase = .hover
                sendPen(.inRange, tool: penTool, after: delay)
            case 1:
                penPhase = .out
                sendPen([], tool: penTool, after: delay)
            case 2:  // tool switch in contact: the old tool lifts and leaves, the new tool starts a new stroke
                sendPen([], tool: penTool, after: delay)
                penTool = other
                sendPen([.inRange, .contact, .strokeStart], tool: penTool, after: 1 * msec)
            default:  // continuing, or the 100 ms liveness repeat (no STROKE_START)
                sendPen([.inRange, .contact], tool: penTool, samples: Int.random(in: 1...3, using: &g), after: delay)
            }
        }
    }

    private mutating func pointerStep(after delay: UInt64) {
        let source = PtrSource.allCases.randomElement(using: &g)!
        var buttons = reported[source] ?? []
        let bit: PointerButtons = [.left, .left, .left, .right, .middle].randomElement(using: &g)!
        buttons.formSymmetricDifference(bit)
        sendPointer(source, buttons, after: delay)
    }

    private mutating func sendPointer(_ source: PtrSource, _ buttons: PointerButtons, after delay: UInt64) {
        d.jump(Int64(delay))  // so the acceptance test below sees the time the message is received
        let previous = reported[source] ?? []
        let gateOpen = penPhase == .out && (lastPenMessageAt.map { d.now - $0 >= 1_000_000 } ?? true)
        let mayAccept = source != .touch || gateOpen
        var mustAppear: [InjectAction] = []
        for button in MouseButton.allCases {
            let bit = button.pointerButton
            guard mayAccept, buttons.contains(bit), !previous.contains(bit) else { continue }
            if reported.values.contains(where: { $0.contains(bit) }) { continue }   // another source holds it
            if button == .left && penPhase == .contact { continue }                // the pen has priority
            mustAppear.append(.mouseButton(button, down: true))
        }
        reported[source] = buttons
        let out = deliver(source.msg(buttons), after: 0)
        for action in mustAppear where !out.contains(action) { fail("a legitimate press was swallowed: \(action) from \(source)") }
    }

    private mutating func scrollStep(after delay: UInt64) {
        if scrolling {
            if coin(35) {
                scrolling = false
                deliver(scrollMsg(.ended), after: delay)
            } else {
                deliver(scrollMsg(.changed, 1, 1), after: delay)
            }
        } else {
            scrolling = true
            let out = deliver(scrollMsg(.began), after: delay)
            if !out.contains(.scroll(.began, dx: 0, dy: 0)) { fail("a scroll BEGAN was swallowed") }
        }
    }

    /// PROTOCOL.md section 7 client obligations for a RELEASE_ALL the client sends itself.
    private mutating func clientReleaseAll(after delay: UInt64) {
        for source in PtrSource.allCases where !(reported[source] ?? []).isEmpty {
            reported[source] = []
            deliver(source.msg([]), after: delay)
        }
        deliver(.releaseAll(.background), after: 1 * msec)
        scrolling = false
        if penPhase == .contact { penPhase = .hover }  // from now on only hover, until a real new stroke start
        expectIdle("after RELEASE_ALL")
    }

    private mutating func hostReleaseAll(after delay: UInt64) {
        d.jump(Int64(delay))
        model.apply(d.release(allReleaseCauses.randomElement(using: &g)!))
        expectIdle("after a host release-all")
    }

    private mutating func expectIdle(_ when: String) {
        if !model.isIdle || d.machine.hasHeldInput { fail("Mac not idle \(when)") }
    }

    // MARK: Run

    mutating func run(steps: Int) {
        for step in 0..<steps {
            let delay = UInt64.random(in: 1...80, using: &g) * msec
            switch Int.random(in: 0..<100, using: &g) {
            case 0..<36: penStep(after: delay)
            case 36..<66: pointerStep(after: delay)
            case 66..<74: scrollStep(after: delay)
            case 74..<79: deliver(doubleTap, after: delay)
            case 79..<84:
                model.apply(d.tick(after: coin(20) ? 600 * msec : delay))
            case 84..<92:
                if mode != .clientReleases { hostReleaseAll(after: delay) }
            default:
                if mode != .hostReleases { clientReleaseAll(after: delay) }
            }
            if !model.violations.isEmpty { fail("step \(step): \(model.violations)"); return }
            if d.machine.hasHeldInput == model.isIdle { fail("step \(step): machine and Mac model disagree"); return }
        }
        // The client lifts and releases everything it still holds. No release-all from anyone.
        if penPhase != .out { sendPen([], tool: penTool, after: 1 * msec) }
        for source in PtrSource.allCases { sendPointer(source, [], after: 1 * msec) }
        if scrolling { deliver(scrollMsg(.ended), after: 1 * msec) }
        expectIdle("at the end, without any final release-all")
        if !model.violations.isEmpty { fail("end: \(model.violations)") }
    }
}

@Suite("WELL: a well-formed client leaves nothing held and loses nothing legitimate")
struct WellFormedClientTests {
    @Test("WELL-1 client releases everything it pressed: the Mac ends idle with no final release-all",
          arguments: WellFormedSimClient.Mode.allCases)
    func well1_endsIdle(mode: WellFormedSimClient.Mode) {
        var failures: [String] = []
        for seed in 1...600 {
            var client = WellFormedSimClient(seed: UInt64(seed), mode: mode)
            client.run(steps: 160)
            failures += client.failures
            if failures.count >= 5 { break }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5).joined(separator: "\n"))")
    }
}
