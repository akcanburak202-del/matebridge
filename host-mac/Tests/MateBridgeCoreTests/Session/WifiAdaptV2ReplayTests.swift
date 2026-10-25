import XCTest
@testable import MateBridgeCore

/// Replays the numeric traces of `WifiAdaptV2Traces` (two host logs of 2026-10-25) through `SendStallDetector` and
/// `WifiAdaptV2Controller`.
///
/// Mapping from the 1 s log rows to the controller's 100 ms ticks (the logs have no finer data):
/// - Ten ticks per row, at +100 ms ... +1000 ms. `srtt` and the send buffer are the row's value on all ten ticks (the
///   worst case for a false decrease: a buffer that stays up is a buffer that "does not fall").
/// - `retx` and `tx` of the row are split evenly over the ten ticks.
/// - A row with `stall_ms` >= 150 holds one stall: the sender's byte progress stops right after the first tick of the
///   row (+100 ms) and resumes `stall_ms` later. The detector then sees it at the first tick at least 150 ms into it,
///   so a 163 ms stall straddles too few ticks to be seen; that is the phase the 100 ms grid gives it.
/// - The send buffer is not interpolated between rows (a buffer that stays up is a buffer that "does not fall").
/// - Every other tick makes progress (12.5 KB per tick) and has fresh outstanding work.
struct V2Replay {
    var controller: WifiAdaptV2Controller
    var detector = SendStallDetector()
    let baseUs: UInt64 = 1_000_000_000
    var steps: [(second: Int, atUs: UInt64, step: WifiAdaptV2Controller.Step)] = []
    var stallEventsUs: [UInt64] = []
    /// The target at the end of each row.
    var targets: [Int] = []
    private var bytes: UInt64 = 0
    private var second = 0

    init(ceilingKbps: Int) { controller = WifiAdaptV2Controller(ceilingKbps: ceilingKbps) }

    static func parse(_ trace: String) -> [(srtt: UInt32, sbKB: UInt32, retx: UInt64, tx: UInt64, stallMs: UInt64)] {
        trace.split(separator: "\n").map { line in
            let f = line.split(separator: " ").map { UInt64($0)! }
            return (UInt32(f[0]), UInt32(f[1]), f[2], f[3], f[4])
        }
    }

    mutating func run(_ trace: String) {
        for row in Self.parse(trace) {
            let rowStart = baseUs + UInt64(second) * 1_000_000
            let stallFrom = rowStart + 100_000
            let stallTo = stallFrom + row.stallMs * 1_000
            for k in 1...10 {
                let t = rowStart + UInt64(k) * 100_000
                let stalled = row.stallMs > 0 && t > stallFrom && t < stallTo
                if !stalled { bytes += 12_500 }
                let r = detector.observe(.init(nowUs: t, progressBytes: bytes,
                                               outstandingSinceUs: stalled ? stallFrom : t - 1_000))
                if r.newEvent { stallEventsUs.append(t) }
                let K = UInt64(k)
                let o = controller.tick(.init(nowUs: t, srttMs: row.srtt, sendBufferBytes: row.sbKB * 1024,
                                              txPacketsDelta: row.tx * K / 10 - row.tx * (K - 1) / 10,
                                              retransmitPacketsDelta: row.retx * K / 10 - row.retx * (K - 1) / 10,
                                              stallStarted: r.newEvent, stallActiveMs: UInt32(r.activeUs / 1_000)))
                if let s = o.step { steps.append((second, t, s)) }
            }
            targets.append(controller.targetKbps)
            second += 1
        }
    }

    var downSteps: [(second: Int, atUs: UInt64, step: WifiAdaptV2Controller.Step)] {
        steps.filter { $0.step.toKbps < $0.step.fromKbps }
    }
}

final class WifiAdaptV2ReplayTests: XCTestCase {
    private func checkStall(_ trace: String, file: StaticString = #filePath, line: UInt = #line) {
        var r = V2Replay(ceilingKbps: 60_000)
        r.run(trace)
        XCTAssertGreaterThanOrEqual(r.stallEventsUs.count, 2, "the detector sees the stalls", file: file, line: line)
        let down = r.downSteps
        XCTAssertFalse(down.isEmpty, file: file, line: line)
        guard let first = down.first else { return }
        // The first decrease is the heavy one, at most 1 s after the second stall was seen, and it is x0.7.
        XCTAssertEqual(first.step.reason, .severe, file: file, line: line)
        XCTAssertEqual(first.step.toKbps, 42_000, file: file, line: line)
        XCTAssertEqual(first.step.evidence, .stall, file: file, line: line)
        XCTAssertLessThanOrEqual(first.atUs - r.stallEventsUs[1], 1_000_000, file: file, line: line)
        // Never below the 30 Mbps floor, no emergency. (The retransmits of the stall itself, with a backlog, may add
        // a x0.85 step after the heavy one; nothing drives it down on stall evidence alone more than x0.7 per pair.)
        XCTAssertGreaterThanOrEqual(r.targets.min() ?? 0, 30_000, file: file, line: line)
        XCTAssertFalse(r.steps.contains { $0.step.reason == .emergency }, file: file, line: line)
        // It climbs back to the ceiling by +2 Mbps steps, at least a second apart.
        XCTAssertEqual(r.targets.last, 60_000, file: file, line: line)
        let ups = r.steps.filter { $0.step.reason == .recover }
        for u in ups {
            XCTAssertTrue(u.step.toKbps - u.step.fromKbps == 2_000 || u.step.toKbps == 60_000, file: file, line: line)
        }
        for (a, b) in zip(ups, ups.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.atUs - a.atUs, 1_000_000, file: file, line: line)
        }
        // Nothing before the first stall.
        XCTAssertGreaterThan(first.second, 20, file: file, line: line)
    }

    /// 2026-10-25 20:17, the first stall of the log (about 4 s of 200 ms write and queue stalls).
    func testFirstStallOfTheEveningLowersOnceItIsRepeated() { checkStall(WifiAdaptV2Traces.stallA) }

    /// 2026-10-25 20:55:36-41, the stall the user reported (write_ms max 220, queue p95 ~200, srtt 4-11 ms).
    func testReportedStallLowersWithinASecondOfTheSecondEventAndRecovers() { checkStall(WifiAdaptV2Traces.stallB) }

    /// 2026-10-25 14:25-15:11: 46 minutes without a user-visible stall. At most one decrease per 10 minutes, and
    /// the rate never gets near the floor.
    func testCleanSessionDoesNotLower() {
        var r = V2Replay(ceilingKbps: 60_000)
        r.run(WifiAdaptV2Traces.clean)
        let minutes = Double(r.targets.count) / 60
        XCTAssertGreaterThan(minutes, 45)
        XCTAssertLessThanOrEqual(Double(r.downSteps.count), minutes / 10, "decreases: \(r.downSteps.map(\.second))")
        XCTAssertGreaterThanOrEqual(r.targets.min() ?? 0, 51_000, "min target \(r.targets.min() ?? 0)")
        XCTAssertFalse(r.steps.contains { $0.step.reason == .emergency })
    }

    /// The v1 collapse (2026-10-23): the controller lowered on one srtt jump, then on srtt excess that came back
    /// every few hundred ms with no standing queue, 12 Mbps in 1.2 s. Here the same shapes do nothing.
    func testV1CollapseShapesDoNotLower() {
        // One srtt jump to 90 ms with a 40 KB buffer, then srtt 45 ms (excess 39) with an empty buffer for 30 s.
        var rows = Array(repeating: "6 0 0 20 0", count: 30)
        rows.append("90 40 0 20 0")
        rows += Array(repeating: "45 0 0 20 0", count: 30)
        var r = V2Replay(ceilingKbps: 60_000)
        r.run(rows.joined(separator: "\n"))
        XCTAssertTrue(r.steps.isEmpty, "\(r.steps.map(\.step))")
        XCTAssertEqual(r.targets.last, 60_000)
    }
}
