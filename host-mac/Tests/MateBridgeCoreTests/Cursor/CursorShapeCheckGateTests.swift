import Testing
@testable import MateBridgeCore

@Suite struct CursorShapeCheckGateTests {
    private let ms: UInt64 = 1_000_000

    private func expect(_ gate: inout CursorShapeCheckGate, nowNs: UInt64, hidden: Bool, hasShape: Bool, _ want: Bool,
                        line: UInt = #line) {
        let got = gate.shouldCheck(nowNs: nowNs, hidden: hidden, hasShape: hasShape)
        #expect(got == want, "line \(line)")
    }

    @Test func firstSampleChecks() {
        var gate = CursorShapeCheckGate()
        expect(&gate, nowNs: 5 * ms, hidden: false, hasShape: false, true)
    }

    @Test func limitsToInterval() {
        var gate = CursorShapeCheckGate(minIntervalNs: 66 * ms)
        expect(&gate, nowNs: 0, hidden: false, hasShape: true, true)
        expect(&gate, nowNs: 8 * ms, hidden: false, hasShape: true, false)
        expect(&gate, nowNs: 65 * ms, hidden: false, hasShape: true, false)
        expect(&gate, nowNs: 66 * ms, hidden: false, hasShape: true, true)
        #expect(gate.checks == 2)
    }

    @Test func burstOfInputChecksOncePerInterval() {
        var gate = CursorShapeCheckGate()
        var n = 0
        for i in 0..<360 {
            if gate.shouldCheck(nowNs: UInt64(i) * 2_777_778, hidden: false, hasShape: true) { n += 1 }
        }
        #expect(n <= 16)  // one second of 360 Hz input: about 15 checks
        #expect(n >= 14)
    }

    @Test func hiddenSkipsButReappearForcesCheck() {
        var gate = CursorShapeCheckGate()
        expect(&gate, nowNs: 0, hidden: false, hasShape: true, true)
        expect(&gate, nowNs: 100 * ms, hidden: true, hasShape: true, false)
        expect(&gate, nowNs: 200 * ms, hidden: true, hasShape: true, false)
        expect(&gate, nowNs: 201 * ms, hidden: false, hasShape: true, true)
        // Hidden and shown again inside the interval still checks.
        expect(&gate, nowNs: 210 * ms, hidden: false, hasShape: true, false)
        expect(&gate, nowNs: 211 * ms, hidden: true, hasShape: true, false)
        expect(&gate, nowNs: 212 * ms, hidden: false, hasShape: true, true)
    }

    @Test func hiddenWithoutShapeStillChecks() {
        var gate = CursorShapeCheckGate()
        expect(&gate, nowNs: 0, hidden: true, hasShape: false, true)
    }

    @Test func resetChecksNext() {
        var gate = CursorShapeCheckGate()
        _ = gate.shouldCheck(nowNs: 0, hidden: false, hasShape: true)
        gate.reset()
        expect(&gate, nowNs: 1 * ms, hidden: false, hasShape: true, true)
    }

    @Test func clockGoingBackwardsChecks() {
        var gate = CursorShapeCheckGate()
        _ = gate.shouldCheck(nowNs: 100 * ms, hidden: false, hasShape: true)
        expect(&gate, nowNs: 50 * ms, hidden: false, hasShape: true, true)
    }
}
