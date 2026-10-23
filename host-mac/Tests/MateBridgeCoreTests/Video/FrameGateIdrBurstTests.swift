import XCTest
@testable import MateBridgeCore

/// T-368: forced-keyframe re-submissions (`HEVCEncoder.resubmitLast`, `bypassGate: true`) stamp the last buffer with
/// `now + lead` and must not move the send grid or the delivery-lag baseline. Before the fix every IDR burst after a
/// Wi-Fi loss pushed the grid one interval ahead of the source cadence, so each later real frame waited about half an
/// interval (8-9 ms `gate_wait` p50 for tens of seconds on the device).
final class FrameGateIdrBurstTests: XCTestCase {
    private let period: UInt64 = 16_666
    private let leadUs: UInt64 = 6_600

    private struct Run {
        var pacer = FramePacer<UInt64>(streamFps: 60)
        var realWaits: [UInt64] = []      // per submitted real frame: submit time - arrival
        var realSubmits: [UInt64] = []
    }

    /// Real frames arrive on a fixed cadence (arrival = capture time). At each time in `idrAt` a keyframe
    /// re-submission is offered with bypassGate and a `now + lead` stamp, exactly like `resubmitLast`.
    private func run(frames: Int, idrAt: [UInt64], skewPpm: Double = 0) -> Run {
        var r = Run()
        var arrivals: [(t: UInt64, id: UInt64)] = []
        var tNow = 0.0
        for k in 0..<frames {
            tNow += Double(period) * (1 + skewPpm / 1e6)
            arrivals.append((UInt64(tNow), UInt64(k)))
        }
        var arrivalOf: [UInt64: UInt64] = [:]
        var pendingIdr = idrAt.sorted()
        var i = 0
        var t: UInt64 = 0
        let end = (arrivals.last?.t ?? 0) + 100_000
        while t <= end {
            while let n = pendingIdr.first, n <= t {
                pendingIdr.removeFirst()
                let stamp = t + leadUs
                _ = r.pacer.offer(20_000 + stamp, ptsUs: stamp, nowUs: t, slotFree: true, bypassGate: true)
            }
            while i < arrivals.count, arrivals[i].t <= t {
                let a = arrivals[i]; i += 1
                arrivalOf[a.id] = a.t
                if case .submit = r.pacer.offer(a.id, ptsUs: a.t, nowUs: a.t, slotFree: true) {
                    r.realWaits.append(0); r.realSubmits.append(a.t)
                }
            }
            if case .submit(let f) = r.pacer.takePending(nowUs: t, slotFree: true), let arr = arrivalOf[f] {
                r.realWaits.append(t - arr); r.realSubmits.append(t)
            }
            t += 1_000
        }
        return r
    }

    /// The device sequence: one IDR burst (7 re-submissions within a second, different phases) on a steady stream.
    func testRealFramesDoNotWaitAfterAnIdrBurst() {
        let t0 = 30 * period
        let idr = (0..<7).map { t0 + UInt64($0) * 141_000 + 5_000 + UInt64($0) * 1_700 }
        let r = run(frames: 240, idrAt: idr)
        XCTAssertLessThanOrEqual(r.realWaits.suffix(60).max() ?? 0, 1_000,
                                 "gate waits after the IDR burst: \(Array(r.realWaits.suffix(60)))")
    }

    func testSingleIdrResubmissionAtAnyPhaseKeepsWaitsLow() {
        for offset in stride(from: UInt64(1_000), to: period, by: 3_000) {
            let r = run(frames: 120, idrAt: [30 * period + offset])
            XCTAssertLessThanOrEqual(r.realWaits.suffix(40).max() ?? 0, 1_000, "offset \(offset)")
        }
    }

    func testIdrBurstWithClockSkewKeepsWaitsLow() {
        for ppm in [50.0, -50.0] {
            let r = run(frames: 200, idrAt: [30 * period + 5_000, 30 * period + 40_000], skewPpm: ppm)
            XCTAssertLessThanOrEqual(r.realWaits.suffix(60).max() ?? 0, 1_000, "ppm \(ppm)")
        }
    }

    /// Real frames stay under the stream rate (the re-submissions are extra and exempt, as before).
    func testRealFrameRateStaysCapped() {
        let r = run(frames: 240, idrAt: [30 * period + 5_000, 30 * period + 90_000, 31 * period])
        let span = Double(r.realSubmits.last! - r.realSubmits.first!) / 1e6
        XCTAssertLessThanOrEqual(Double(r.realSubmits.count - 1) / span, 60.5)
        for j in 2..<r.realSubmits.count {
            XCTAssertGreaterThanOrEqual(r.realSubmits[j] - r.realSubmits[j - 2], period - 1_000, "j=\(j)")
        }
    }

    /// A bypassed re-submission has a `now + lead` stamp: it must not drag the lag baseline below the real one,
    /// or the next re-anchor would over-credit.
    func testBypassFrameDoesNotMoveGridOrLagBaseline() {
        var p = FramePacer<UInt64>(streamFps: 60)
        _ = p.offer(0, ptsUs: 0, nowUs: 0, slotFree: true)
        let slot = p.gate.nextSlotUs
        _ = p.offer(1, ptsUs: 11_600, nowUs: 5_000, slotFree: true, bypassGate: true)
        XCTAssertEqual(p.gate.nextSlotUs, slot)
    }
}
