import XCTest
@testable import MateBridgeCore

/// The writer-side stall timing (`WriteGapMeter`) feeding `SendStallDetector`, polled every 100 ms at every sampling
/// phase. Times are in milliseconds in the helpers; the meter takes nanoseconds.
final class WriteGapMeterTests: XCTestCase {
    private enum Act {
        case queue
        case progress(Int)
        case idle
    }

    /// Runs the writer actions (ms) against polls at `phase`, `phase + 100`, ... up to `endMs`; returns the events the
    /// detector reported, the longest active stall it saw and the longest ended one.
    private func run(_ acts: [(ms: Double, act: Act)], phase: Int, endMs: Int = 3_000)
        -> (events: Int, maxActiveMs: Double, maxEndedMs: Double) {
        var meter = WriteGapMeter()
        var det = SendStallDetector()
        let sorted = acts.sorted { $0.ms < $1.ms }
        var next = 0
        var events = 0
        var maxActive = 0.0
        var maxEnded = 0.0
        var t = 1_000 + phase  // polls start after the first action
        func ns(_ ms: Double) -> UInt64 { UInt64(ms * 1_000_000) }
        while t <= endMs {
            while next < sorted.count, sorted[next].ms <= Double(t) {
                let (ms, act) = sorted[next]
                switch act {
                case .queue: meter.workQueued(nowNs: ns(ms), wasIdle: true)
                case .progress(let n): meter.progress(nowNs: ns(ms), bytes: n)
                case .idle: meter.idle()
                }
                next += 1
            }
            let r = det.observe(.init(meter.snapshot(nowNs: ns(Double(t)), pendingBytes: 0), headAgeUs: nil,
                                       nowUs: UInt64(t) * 1_000))
            events += r.events
            maxActive = max(maxActive, Double(r.activeUs) / 1_000)
            maxEnded = max(maxEnded, Double(r.endedUs) / 1_000)
            t += 100
        }
        return (events, maxActive, maxEnded)
    }

    /// A record queued at 1000 ms that progresses at 1001 ms, blocks for `stallMs`, then finishes.
    private func stallActs(_ stallMs: Double, at start: Double = 1_000) -> [(ms: Double, act: Act)] {
        [(start, .queue), (start + 1, .progress(100)), (start + 1 + stallMs, .progress(5_000)),
         (start + 2 + stallMs, .idle)]
    }

    func testStallsOfAtLeast150msAreFoundAtEverySamplingPhase() {
        for stallMs in [160.0, 220.0, 500.0] {
            for phase in 0..<100 {
                let r = run(stallActs(stallMs), phase: phase)
                XCTAssertEqual(r.events, 1, "stall \(stallMs) ms, phase \(phase)")
            }
        }
    }

    func testStallsShorterThanTheThresholdAreNeverFound() {
        for phase in 0..<100 {
            XCTAssertEqual(run(stallActs(140), phase: phase).events, 0, "phase \(phase)")
        }
    }

    func testRepeated220msStallsAreAllFoundAtEveryPhase() {
        // The 20:55 shape: a 220 ms stall every second.
        var acts: [(ms: Double, act: Act)] = []
        for i in 0..<3 { acts += stallActs(220, at: 1_000 + Double(i) * 1_000) }
        for phase in 0..<100 {
            XCTAssertEqual(run(acts, phase: phase, endMs: 4_500).events, 3, "phase \(phase)")
        }
    }

    func testTheLengthOfAStallThatEndedBetweenPollsIsReported() {
        for phase in stride(from: 0, to: 100, by: 7) {
            let r = run(stallActs(220), phase: phase)
            // Either seen open (active grows to at least 150) or reported when it ended (about 220).
            XCTAssertTrue(r.maxEndedMs >= 219 || r.maxActiveMs >= 150, "phase \(phase): \(r)")
        }
    }

    func testAProgressingBigWriteIsNeverAStall() {
        var acts: [(ms: Double, act: Act)] = [(1_000, .queue)]
        var t = 1_010.0
        while t < 3_000 {  // a 4 MB keyframe: progress every 10 ms for 2 s
            acts.append((t, .progress(20_000)))
            t += 10
        }
        acts.append((3_000, .idle))
        for phase in stride(from: 0, to: 100, by: 9) {
            XCTAssertEqual(run(acts, phase: phase, endMs: 3_100).events, 0, "phase \(phase)")
        }
    }

    func testRecordTransitionDoesNotMixTheGaps() {
        // Record A stalls 200 ms and finishes at 1201; record B is queued at 1210 and moves at once; C stalls 200 ms.
        var acts = stallActs(200)
        acts += [(1_210, .queue), (1_211, .progress(1_000)), (1_212, .idle)]
        acts += stallActs(200, at: 1_500)
        for phase in 0..<100 {
            XCTAssertEqual(run(acts, phase: phase).events, 2, "phase \(phase): A and C once each, B never")
        }
        // B was queued behind A (no idle in between) and blocks as soon as A is through: its gap starts at A's last
        // byte, not at A's start: two events.
        let back: [(ms: Double, act: Act)] = [(1_000, .queue), (1_001, .progress(100)), (1_201, .progress(100)),
                                              (1_401, .progress(100)), (1_402, .idle)]
        for phase in 0..<100 {
            XCTAssertEqual(run(back, phase: phase).events, 2, "phase \(phase)")
        }
    }

    /// A frame sits at the head of the send queue from 1010 ms for `waitMs` with nothing pending in the writer (the last
    /// record finished at 1000 ms), then is written. Polls pass the head age as the driver does.
    private func headRun(waitMs: Double, phase: Int) -> (events: Int, maxActiveMs: Double, maxEndedMs: Double) {
        var meter = WriteGapMeter()
        var det = SendStallDetector()
        meter.workQueued(nowNs: 990_000_000, wasIdle: true)
        meter.progress(nowNs: 1_000_000_000, bytes: 1_000)
        meter.idle()
        let enqueued = 1_010.0
        let acceptedAt = enqueued + waitMs
        var accepted = false
        var events = 0
        var maxActive = 0.0
        var maxEnded = 0.0
        var t = 1_000 + phase
        while t <= 3_000 {
            if !accepted, Double(t) >= acceptedAt {
                accepted = true
                meter.headWaitEnded(nowNs: UInt64(acceptedAt * 1_000_000), waitNs: UInt64(waitMs * 1_000_000))
                meter.workQueued(nowNs: UInt64(acceptedAt * 1_000_000), wasIdle: true)
                meter.progress(nowNs: UInt64((acceptedAt + 1) * 1_000_000), bytes: 5_000)
                meter.idle()
            }
            let age: UInt64? = (!accepted && Double(t) >= enqueued) ? UInt64((Double(t) - enqueued) * 1_000) : nil
            let r = det.observe(.init(meter.snapshot(nowNs: UInt64(t) * 1_000_000, pendingBytes: 0), headAgeUs: age,
                                       nowUs: UInt64(t) * 1_000))
            events += r.events
            maxActive = max(maxActive, Double(r.activeUs) / 1_000)
            maxEnded = max(maxEnded, Double(r.endedUs) / 1_000)
            t += 100
        }
        return (events, maxActive, maxEnded)
    }

    func testQueueHeadStallsAreFoundOnceAtEverySamplingPhase() {
        for waitMs in [160.0, 220.0, 520.0] {
            for phase in 0..<100 {
                XCTAssertEqual(headRun(waitMs: waitMs, phase: phase).events, 1, "head wait \(waitMs) ms, phase \(phase)")
            }
        }
    }

    func testQueueHeadWaitsUnderTheThresholdAreNeverFound() {
        for phase in 0..<100 { XCTAssertEqual(headRun(waitMs: 140, phase: phase).events, 0, "phase \(phase)") }
    }

    func testAnEndedQueueHeadStallKeepsItsRealLength() {
        for phase in stride(from: 0, to: 100, by: 11) {
            let r = headRun(waitMs: 520, phase: phase)
            XCTAssertGreaterThanOrEqual(r.maxEndedMs, 519, "phase \(phase): \(r)")
        }
    }

    func testWaitBehindAWriterThatWasStillProgressingIsNotAStall() {
        var m = WriteGapMeter()
        m.workQueued(nowNs: 1_390_000_000, wasIdle: true)
        m.progress(nowNs: 1_400_000_000, bytes: 10)  // bytes moved 100 ms before the next record
        m.idle()
        // The frame waited 500 ms, but the no-progress gap is only 100 ms.
        m.headWaitEnded(nowNs: 1_500_000_000, waitNs: 500_000_000)
        XCTAssertEqual(m.snapshot(nowNs: 1_500_000_000, pendingBytes: 0).longGapsEnded, 0)
    }

    func testMeterKeepsTheEndTimeOfEachLongGap() {
        var m = WriteGapMeter()
        m.workQueued(nowNs: 0, wasIdle: true)
        m.progress(nowNs: 200_000_000, bytes: 1)       // gap 1 ends at 200 ms
        m.progress(nowNs: 600_000_000, bytes: 1)       // gap 2 (400 ms) ends at 600 ms
        let s = m.snapshot(nowNs: 700_000_000, pendingBytes: 0)
        XCTAssertEqual(s.longGapsEnded, 2)
        XCTAssertEqual(s.recentLongGapEndAgesNs, [500_000_000, 100_000_000])
    }

    func testSnapshotFieldsOfTheMeter() {
        var m = WriteGapMeter()
        XCTAssertEqual(m.snapshot(nowNs: 5, pendingBytes: 0).sinceProgressNs, 0, "nothing happened yet")
        m.workQueued(nowNs: 1_000_000, wasIdle: true)
        let open = m.snapshot(nowNs: 201_000_000, pendingBytes: 10)
        XCTAssertTrue(open.busy)
        XCTAssertEqual(open.openGapNs, 200_000_000)
        m.progress(nowNs: 201_000_000, bytes: 10)
        m.idle()
        let done = m.snapshot(nowNs: 202_000_000, pendingBytes: 0)
        XCTAssertFalse(done.busy)
        XCTAssertEqual(done.openGapNs, 0)
        XCTAssertEqual(done.sinceProgressNs, 1_000_000)
        XCTAssertEqual(done.longGapsEnded, 1)
        XCTAssertEqual(done.lastLongGapNs, 200_000_000)
        XCTAssertEqual(done.acceptedBytes, 10)
    }
}
