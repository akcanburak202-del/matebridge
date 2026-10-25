import XCTest
@testable import MateBridgeCore

/// Replays the numeric traces of `WifiAdaptV2Traces` (two host logs of 2026-10-25) through `SendStallDetector` and
/// `WifiAdaptV2Controller`.
///
/// Mapping from the 1 s log rows to the controller's 100 ms ticks (the logs have no finer data):
/// - Ten ticks per row, at +100 ms ... +1000 ms. `srtt` and the send buffer are the row's value on all ten ticks (the
///   worst case for a false decrease: a buffer that stays up is a buffer that "does not fall").
/// - `retx` and `tx` of the row are split evenly over the ten ticks.
/// - A row with `stall_ms` >= 150 holds one stall: the writer queues a record at +100 ms (right after the first
///   tick), moves 100 bytes at +101 ms, then makes no progress until `stall_ms` later and finishes it. The writer
///   (`WriteGapMeter`) times that gap itself, so the stall is counted whether or not a tick falls inside it.
/// - The send buffer is not interpolated between rows (a buffer that stays up is a buffer that "does not fall").
/// - Every other tick has a record written 5 ms before it (12.5 KB, progress 1 ms later), so there is always fresh
///   work and progress; the head of the send queue is empty.
struct V2Replay {
    var controller: WifiAdaptV2Controller
    var detector = SendStallDetector()
    let baseUs: UInt64 = 1_000_000_000
    var steps: [(second: Int, atUs: UInt64, step: WifiAdaptV2Controller.Step)] = []
    var stallEventsUs: [UInt64] = []
    /// The target at the end of each row.
    var targets: [Int] = []
    private var second = 0

    init(ceilingKbps: Int) { controller = WifiAdaptV2Controller(ceilingKbps: ceilingKbps) }

    static func parse(_ trace: String) -> [(srtt: UInt32, sbKB: UInt32, retx: UInt64, tx: UInt64, stallMs: UInt64)] {
        trace.split(separator: "\n").map { line in
            let f = line.split(separator: " ").map { UInt64($0)! }
            return (UInt32(f[0]), UInt32(f[1]), f[2], f[3], f[4])
        }
    }

    private var meter = WriteGapMeter()

    mutating func run(_ trace: String) {
        for row in Self.parse(trace) {
            let rowStart = baseUs + UInt64(second) * 1_000_000
            let stallFrom = rowStart + 100_000
            let stallTo = stallFrom + row.stallMs * 1_000
            // Writer actions of this row, in microseconds.
            enum Act { case queue, progress(Int), idle }
            var acts: [(UInt64, Act)] = []
            if row.stallMs > 0 {
                acts += [(stallFrom + 1_000, .queue), (stallFrom + 1_001, .progress(100)), (stallTo, .progress(12_400)),
                         (stallTo + 1_000, .idle)]
            }
            for k in 1...10 {
                let t = rowStart + UInt64(k) * 100_000
                let w = t - 5_000
                if row.stallMs == 0 || w < stallFrom || w >= stallTo {
                    acts += [(w, .queue), (w + 1_000, .progress(12_500)), (w + 2_000, .idle)]
                }
            }
            acts.sort { $0.0 < $1.0 }
            var next = 0
            for k in 1...10 {
                let t = rowStart + UInt64(k) * 100_000
                while next < acts.count, acts[next].0 <= t {
                    let (at, act) = acts[next]
                    switch act {
                    case .queue: meter.workQueued(nowNs: at * 1_000, wasIdle: true)
                    case .progress(let n): meter.progress(nowNs: at * 1_000, bytes: n)
                    case .idle: meter.idle()
                    }
                    next += 1
                }
                let snap = meter.snapshot(nowNs: t * 1_000, pendingBytes: 0)
                let r = detector.observe(.init(snap, headAgeUs: nil, nowUs: t))
                for _ in 0..<r.events { stallEventsUs.append(t) }
                let K = UInt64(k)
                let o = controller.tick(.init(nowUs: t, srttMs: row.srtt, sendBufferBytes: row.sbKB * 1024,
                                              txPacketsDelta: row.tx * K / 10 - row.tx * (K - 1) / 10,
                                              retransmitPacketsDelta: row.retx * K / 10 - row.retx * (K - 1) / 10,
                                              stallEvents: r.events, stallActiveMs: UInt32(r.activeUs / 1_000),
                                              stallEndedMs: UInt32(r.endedUs / 1_000),
                                              stallEventAgesMs: r.eventAgesUs.map { UInt32($0 / 1_000) }))
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
