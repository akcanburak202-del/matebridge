import XCTest
@testable import MateBridgeCore

/// T-365: after a late submission (encoder slot held a pending frame past one interval) the gate re-anchors. The
/// re-anchor must follow the source cadence, not the late submit time, or every later on-time frame waits for
/// minutes. Source: fixed period, capture time = arrival time, 1 ms timer steps like `FrameGateTests.Sim`.
final class FrameGateReanchorTests: XCTestCase {
    private let period: UInt64 = 16_666

    private struct Run {
        var pacer = FramePacer<UInt64>(streamFps: 60)
        var gateWaits: [UInt64] = []   // per submitted frame: submit time - arrival of that frame
        var submitTimes: [UInt64] = []
    }

    /// `busy`: encoder slot unavailable in that time range. `idle`: frame indices the source skips.
    /// `skewPpm`: source clock vs host clock. `burstAt`: a second frame arrives 100 us after that frame.
    private func run(frames: Int, busy: Range<UInt64>?, idle: Range<Int>? = nil, skewPpm: Double = 0,
                     burstAt: Int? = nil) -> Run {
        var r = Run()
        var arrivals: [(t: UInt64, id: UInt64)] = []
        var tNow = 0.0
        for k in 0..<frames {
            tNow += Double(period) * (1 + skewPpm / 1e6)
            if let idle, idle.contains(k) { continue }
            arrivals.append((UInt64(tNow), UInt64(k)))
            if let burstAt, k == burstAt { arrivals.append((UInt64(tNow) + 100, UInt64(10_000 + k))) }
        }
        var arrivalOf: [UInt64: UInt64] = [:]
        var i = 0
        var t: UInt64 = 0
        let end = (arrivals.last?.t ?? 0) + 100_000
        while t <= end {
            let free = !(busy?.contains(t) ?? false)
            while i < arrivals.count, arrivals[i].t <= t {
                let a = arrivals[i]; i += 1
                arrivalOf[a.id] = a.t
                if case .submit = r.pacer.offer(a.id, ptsUs: a.t, nowUs: a.t, slotFree: free) {
                    r.gateWaits.append(0); r.submitTimes.append(a.t)
                }
            }
            if case .submit(let f) = r.pacer.takePending(nowUs: t, slotFree: free) {
                r.gateWaits.append(t - (arrivalOf[f] ?? t)); r.submitTimes.append(t)
            }
            t += 1_000
        }
        return r
    }

    func testOnTimeFramesDoNotWaitAfterALateSubmit() {
        // Encoder busy from frame 30 until 30 ms later: the pending frame is submitted late, the gate re-anchors.
        let r = run(frames: 120, busy: (30 * period)..<(30 * period + 30_000))
        let tail = r.gateWaits.suffix(60)
        XCTAssertLessThanOrEqual(tail.max() ?? 0, 1_000, "gate waits after the late submit: \(Array(tail))")
        XCTAssertGreaterThanOrEqual(r.submitTimes.count, 100)
    }

    func testRateStillCappedAtStreamFpsAfterReanchor() {
        let r = run(frames: 240, busy: (30 * period)..<(30 * period + 30_000))
        let span = Double(r.submitTimes.last! - r.submitTimes.first!) / 1e6
        XCTAssertLessThanOrEqual(Double(r.submitTimes.count - 1) / span, 60.5)
        // never more than two submissions within one interval
        for i in 2..<r.submitTimes.count {
            XCTAssertGreaterThanOrEqual(r.submitTimes[i] - r.submitTimes[i - 2], period - 1_000, "i=\(i)")
        }
    }

    func testPersistentClockSkewKeepsWaitsLowAfterLateSubmit() {
        for ppm in [50.0, -50.0] {
            let r = run(frames: 200, busy: (30 * period)..<(30 * period + 30_000), skewPpm: ppm)
            XCTAssertLessThanOrEqual(r.gateWaits.suffix(60).max() ?? 0, 1_000, "ppm \(ppm)")
        }
    }

    func testIdleThenResumeReanchorsWithoutWaiting() {
        let r = run(frames: 150, busy: nil, idle: 40..<90)
        XCTAssertLessThanOrEqual(r.gateWaits.max() ?? 0, 1_000)
    }

    func testBackToBackBurstKeepsTheRateCap() {
        let r = run(frames: 150, busy: nil, burstAt: 50)
        for i in 2..<r.submitTimes.count {
            XCTAssertGreaterThanOrEqual(r.submitTimes[i] - r.submitTimes[i - 2], period - 1_000, "i=\(i)")
        }
    }

    func testGateAcceptCreditIsBoundedByHalfAnInterval() {
        var g = FrameGate(streamFps: 60)
        g.accept(nowUs: 0)
        g.accept(nowUs: 5_000_000, phaseCreditUs: 1_000_000)
        XCTAssertEqual(g.nextSlotUs, 5_000_000 + 16_666 - 8_333)
        g.accept(nowUs: 9_000_000)   // no credit: unchanged behaviour
        XCTAssertEqual(g.nextSlotUs, 9_000_000 + 16_666)
    }
}
