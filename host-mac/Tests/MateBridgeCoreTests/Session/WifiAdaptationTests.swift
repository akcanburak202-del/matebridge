import XCTest
@testable import MateBridgeCore

/// T-328: the knob, the frame admission of `WifiAdaptation` (budget, retry, wake-ups), the queue-drop rule and the log
/// window. The clock, the send-buffer reading and the retry timer are manual, so every interleaving is deterministic.
final class WifiAdaptationTests: XCTestCase {
    // MARK: Harness

    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: UInt64 = 1_000_000
        private var _sendBuffer: UInt32? = 0
        private var _reads = 0
        private var _wakes = 0
        private var _timers: [(at: UInt64, fire: @Sendable () -> Void)] = []
        private var _delays: [UInt64] = []

        var now: UInt64 { lock.withLock { _now } }
        var sendBuffer: UInt32? {
            get { lock.withLock { _sendBuffer } }
            set { lock.withLock { _sendBuffer = newValue } }
        }
        var reads: Int { lock.withLock { _reads } }
        var wakes: Int { lock.withLock { _wakes } }
        var pendingTimers: Int { lock.withLock { _timers.count } }
        var armedDelays: [UInt64] { lock.withLock { _delays } }

        /// A reading taken on another thread before it got the lock: older than what was stored meanwhile.
        func setNow(_ us: UInt64) { lock.withLock { _now = us } }

        func read() -> UInt32? { lock.withLock { _reads += 1; return _sendBuffer } }
        func wake() { lock.withLock { _wakes += 1 } }
        func schedule(_ afterUs: UInt64, _ fire: @escaping @Sendable () -> Void) {
            lock.withLock {
                _timers.append((_now + afterUs, fire))
                _delays.append(afterUs)
            }
        }

        /// Moves the clock and runs the timers that came due, in order.
        func advance(us: UInt64) {
            let target = lock.withLock { _now + us }
            while true {
                let next: (at: UInt64, fire: @Sendable () -> Void)? = lock.withLock {
                    guard let i = _timers.indices.filter({ _timers[$0].at <= target })
                        .min(by: { _timers[$0].at < _timers[$1].at }) else { return nil }
                    let t = _timers.remove(at: i)
                    _now = max(_now, t.at)
                    return t
                }
                guard let next else { break }
                next.fire()
            }
            lock.withLock { _now = target }
        }
    }

    private func make(ceilingKbps: Int = 60_000) -> (WifiAdaptation, World) {
        let w = World()
        let a = WifiAdaptation(config: .init(ceilingKbps: ceilingKbps),
                               readSendBuffer: { w.read() }, nowUs: { w.now },
                               schedule: { w.schedule($0, $1) })
        a.setWakeHandler { w.wake() }
        return (a, w)
    }

    private func report(srttMs: UInt32 = 5, sendBuffer: UInt32 = 0, retx: UInt64 = 0) -> TcpInfoReport {
        TcpInfoReport(snapshot: TcpConnectionSnapshot(srttMs: srttMs, sendBufferBytes: sendBuffer),
                      retransmitPacketsDelta: retx, retransmitBytesDelta: 0, outOfOrderBytesDelta: 0,
                      txPacketsDelta: 0)
    }

    // MARK: Knob

    func testKnobIsOffUnlessExactlyOne() {
        XCTAssertFalse(WifiAdaptKnob.isEnabled([:]))
        for v in ["", "0", "true", "on", "yes", "2", "01", "-1"] {
            XCTAssertFalse(WifiAdaptKnob.isEnabled([WifiAdaptKnob.name: v]), v)
        }
        XCTAssertTrue(WifiAdaptKnob.isEnabled([WifiAdaptKnob.name: "1"]))
        XCTAssertTrue(WifiAdaptKnob.isEnabled([WifiAdaptKnob.name: " 1 "]))
        XCTAssertFalse(WifiAdaptKnob.isEnabled(["OTHER": "1"]))
    }

    func testKnobIsNeverActiveOnUsb() {
        let on = [WifiAdaptKnob.name: "1"]
        XCTAssertTrue(WifiAdaptKnob.isActive(on, transport: .network))
        XCTAssertFalse(WifiAdaptKnob.isActive(on, transport: .usb))
        XCTAssertFalse(WifiAdaptKnob.isActive([:], transport: .network))
        XCTAssertFalse(WifiAdaptKnob.isActive([:], transport: .usb))
    }

    // MARK: Admission

    func testAdmitsWithinBudgetAndRefusesAbove() {
        let (a, w) = make()
        XCTAssertEqual(a.budgetBytes, 150_000, "20 ms of 60 Mbps")
        w.sendBuffer = 150_000
        XCTAssertTrue(a.admit(), "at the budget")
        w.advance(us: 5_000)
        w.sendBuffer = 150_001
        XCTAssertFalse(a.admit())
    }

    func testUnreadableSocketAdmits() {
        let (a, w) = make()
        w.sendBuffer = nil
        XCTAssertTrue(a.admit())
        XCTAssertTrue(a.admit())
        XCTAssertEqual(w.pendingTimers, 0, "no retry for a gate that did not refuse")
    }

    func testSendBufferReadingIsSharedWithinTheFreshnessWindow() {
        let (a, w) = make()
        w.sendBuffer = 10_000
        XCTAssertTrue(a.admit())
        XCTAssertTrue(a.admit())
        w.advance(us: WifiAdaptation.sampleFreshUs - 1)
        XCTAssertTrue(a.admit())
        XCTAssertEqual(w.reads, 1, "one getsockopt for a canSend / send pair")
        w.advance(us: 1)
        XCTAssertTrue(a.admit())
        XCTAssertEqual(w.reads, 2)
    }

    func testRefusalArmsOneRetryAndWakesWhenTheBufferDrains() {
        let (a, w) = make()
        w.sendBuffer = 400_000
        XCTAssertFalse(a.admit())
        XCTAssertFalse(a.admit())
        XCTAssertFalse(a.admit())
        XCTAssertEqual(w.pendingTimers, 1, "one retry however often the sender asks")
        XCTAssertEqual(w.armedDelays, [WifiAdaptation.retryFirstUs])

        // Drained before the retry: the retry wakes the sender, which asks again and passes.
        w.sendBuffer = 20_000
        w.advance(us: WifiAdaptation.retryFirstUs)
        XCTAssertEqual(w.wakes, 1)
        XCTAssertTrue(a.admit())
        w.advance(us: 100_000)
        XCTAssertEqual(w.wakes, 1, "the episode is closed: no more wakes")
        XCTAssertEqual(w.pendingTimers, 0)
    }

    func testRetryBacksOffWhileStillOverBudgetAndNeverExceedsTheCap() {
        let (a, w) = make()
        w.sendBuffer = 400_000
        XCTAssertFalse(a.admit())
        w.advance(us: 200_000)
        XCTAssertEqual(w.wakes, 0, "still over budget: no wake")
        let d = w.armedDelays
        XCTAssertEqual(Array(d.prefix(4)), [4_000, 8_000, 16_000, 20_000])
        XCTAssertTrue(d.allSatisfy { $0 <= WifiAdaptation.retryMaxUs })
        // And it wakes as soon as the buffer is back.
        w.sendBuffer = 0
        w.advance(us: 25_000)
        XCTAssertEqual(w.wakes, 1)
    }

    func testTickRechecksAnOpenRefusal() {
        let (a, w) = make()
        w.sendBuffer = 400_000
        XCTAssertFalse(a.admit())
        // A tick (100 ms) comes before the retry fires: it wakes the sender too, so no wake-up depends on one source.
        _ = a.tick(report: report(sendBuffer: 400_000), queueDropsTotal: 0)
        XCTAssertEqual(w.wakes, 1)
        // A tick without an open refusal wakes nothing.
        w.sendBuffer = 0
        w.advance(us: 50_000)
        XCTAssertTrue(a.admit())
        let wakes = w.wakes
        _ = a.tick(report: report(), queueDropsTotal: 0)
        XCTAssertEqual(w.wakes, wakes)
    }

    func testNoWakeIsLostWhenTheDrainRacesTheRetryAndTheTick() {
        let (a, w) = make()
        w.sendBuffer = 400_000
        XCTAssertFalse(a.admit())
        // The buffer drains right after the refusal; whichever of the writable event, the retry or the tick comes
        // first, the sender is woken at least once and then passes.
        w.sendBuffer = 0
        w.advance(us: WifiAdaptation.retryFirstUs)
        _ = a.tick(report: report(), queueDropsTotal: 0)
        XCTAssertGreaterThanOrEqual(w.wakes, 1)
        XCTAssertTrue(a.admit())
    }

    func testStopEndsGateRetriesAndWakes() {
        let (a, w) = make()
        w.sendBuffer = 400_000
        XCTAssertFalse(a.admit())
        a.stop()
        w.sendBuffer = 0
        w.advance(us: 100_000)
        XCTAssertEqual(w.wakes, 0)
        w.sendBuffer = 400_000
        w.advance(us: 10_000)
        XCTAssertTrue(a.admit(), "a stopped gate never refuses")
        _ = a.tick(report: report(), queueDropsTotal: 0)
        XCTAssertEqual(w.wakes, 0)
    }

    // MARK: Queue drops

    func testHostQueueDropLowersTheTargetWhenTheGateWasNotRefusing() {
        let (a, w) = make()
        XCTAssertEqual(a.targetKbps, 60_000)
        _ = a.tick(report: report(), queueDropsTotal: 7)  // first tick: the drop count base
        w.advance(us: 100_000)
        let r = a.tick(report: report(), queueDropsTotal: 10)
        XCTAssertEqual(r.reportedDrops, 3)
        XCTAssertEqual(r.trigger, .queueDrop)
        XCTAssertTrue(r.changed)
        XCTAssertLessThan(r.targetKbps, 60_000)
    }

    func testDropsAfterTheGateRefusedAreNotReported() {
        let (a, w) = make()
        _ = a.tick(report: report(), queueDropsTotal: 0)
        w.advance(us: 100_000)
        w.sendBuffer = 400_000
        XCTAssertFalse(a.admit(), "the gate refuses; the two-frame queue overflows because of it")
        w.advance(us: 50_000)
        let r1 = a.tick(report: report(), queueDropsTotal: 4)
        XCTAssertEqual(r1.reportedDrops, 0)
        XCTAssertNil(r1.trigger)
        XCTAssertFalse(r1.changed)
        XCTAssertEqual(a.targetKbps, 60_000, "the gate's own effect never lowers the target")

        // The window after: the refusal is one window old, drops that trail it still belong to it.
        w.advance(us: 100_000)
        let r2 = a.tick(report: report(), queueDropsTotal: 6)
        XCTAssertEqual(r2.reportedDrops, 0)
        XCTAssertFalse(r2.changed)

        // Two clean windows later a real drop counts.
        w.advance(us: 100_000)
        _ = a.tick(report: report(), queueDropsTotal: 6)
        w.advance(us: 100_000)
        let r3 = a.tick(report: report(), queueDropsTotal: 9)
        XCTAssertEqual(r3.reportedDrops, 3)
        XCTAssertEqual(r3.trigger, .queueDrop)
    }

    func testRetransmitsAndSendBufferLowerTheTargetThroughTheTick() {
        let (a, w) = make()
        _ = a.tick(report: report(), queueDropsTotal: 0)
        w.advance(us: 100_000)
        let r = a.tick(report: report(retx: 50), queueDropsTotal: 0)
        XCTAssertEqual(r.trigger, .retransmit)
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.targetKbps, 42_000)
        XCTAssertFalse(a.tick(report: report(retx: 0), queueDropsTotal: 0).changed, "no change, no apply")
    }

    // MARK: Sustained blocking (P2)

    /// One tick of the closed-loop picture: the sender asks while the kernel buffer reads `sb`, 100 ms pass, the tick
    /// runs with the same reading (admission and tick see the same buffer).
    private func blockedTick(_ a: WifiAdaptation, _ w: World, drops: inout Int, dropsPerTick: Int = 3,
                             sb: UInt32) -> WifiAdaptation.TickResult {
        w.sendBuffer = sb
        _ = a.admit()
        w.advance(us: 100_000)
        drops += dropsPerTick
        return a.tick(report: report(sendBuffer: sb), queueDropsTotal: drops)
    }

    /// A 680 KB keyframe on a slow link (6.4 Mbps of drain): the gate stays closed for most of a second, the queue
    /// overflows, and the buffer is over three budgets (450 KB) for only 3 ticks. Admission and tick readings match.
    /// Neither the send-buffer trigger (400 ms of backlog needed) nor the sustained-blocking trigger (60 % of 2 s)
    /// may fire.
    func testOneOversizedKeyframeNeverLowersTheTarget() {
        let (a, w) = make()
        var drops = 0
        _ = a.tick(report: report(), queueDropsTotal: 0)
        let keyframe: [UInt32] = [680_000, 600_000, 520_000, 440_000, 360_000, 280_000, 200_000, 120_000, 40_000, 0]
        for i in 0..<60 {
            let sb = i < keyframe.count ? keyframe[i] : 0
            let r = blockedTick(a, w, drops: &drops, dropsPerTick: i < 8 ? 3 : 0, sb: sb)
            XCTAssertNil(r.trigger, "tick \(i)")
        }
        XCTAssertEqual(a.targetKbps, 60_000)
    }

    /// A backlog that does not drain (three budgets and more for 400 ms) is congestion on the first tick past that.
    func testSustainedBacklogLowersTheTarget() {
        let (a, w) = make()
        var drops = 0
        _ = a.tick(report: report(), queueDropsTotal: 0)
        var triggers: [CongestionController.Trigger?] = []
        for _ in 0..<6 { triggers.append(blockedTick(a, w, drops: &drops, dropsPerTick: 0, sb: 700_000).trigger) }
        XCTAssertEqual(triggers, [nil, nil, nil, nil, .sendBuffer, nil])  // the sixth is inside the minimum interval
        XCTAssertLessThan(a.targetKbps, 60_000)
    }

    func testSustainedBlockingOnAnUnderCapacityLinkLowersTheTargetOncePerSpan() {
        let (a, w) = make()
        var drops = 0
        _ = a.tick(report: report(), queueDropsTotal: 0)
        var triggers: [Int] = []
        for i in 0..<45 {
            let r = blockedTick(a, w, drops: &drops, sb: 160_000)
            if r.trigger == .blocked { triggers.append(i) }
            XCTAssertEqual(r.reportedDrops, 0, "the gate refused: these drops are never reported as queue drops")
        }
        XCTAssertEqual(triggers.count, 2, "one decrease per full 2 s span, not one per tick")
        XCTAssertGreaterThanOrEqual(triggers[0], 19)
        XCTAssertGreaterThanOrEqual(triggers[1] - triggers[0], 20)
        XCTAssertEqual(a.targetKbps, 29_500, "60 Mbps x 0.7 x 0.7 in 250 kbps steps")
    }

    func testBlockingWithoutQueueDropsIsNotACongestionSignal() {
        let (a, w) = make()
        var drops = 0
        _ = a.tick(report: report(), queueDropsTotal: 0)
        for _ in 0..<45 { _ = blockedTick(a, w, drops: &drops, dropsPerTick: 0, sb: 160_000) }
        XCTAssertEqual(a.targetKbps, 60_000)
    }

    // MARK: Timestamps (P1)

    func testStaleTimestampNeverWrapsTheBlockedAccounting() {
        let (a, w) = make()
        w.sendBuffer = 400_000
        XCTAssertFalse(a.admit())              // episode opens at 1.000 s
        w.advance(us: 500_000)
        _ = a.takeLogWindow()                  // moves the open episode's start to 1.500 s
        w.sendBuffer = 0
        w.advance(us: 30_000)                  // the retry reads the drained buffer (cached at about 1.53 s)
        // A sender thread that read the clock at 1.200 s and got the lock afterwards:
        w.setNow(1_200_000)
        XCTAssertTrue(a.admit(), "the budget is fine; the stale timestamp must not trap")
        w.advance(us: 1_000_000)
        let win = a.takeLogWindow()
        XCTAssertLessThan(win.blockedMs, 1_000, "no wrapped difference in the window")
        // The tick path with an old clock reading, too.
        w.setNow(1_000_000)
        _ = a.tick(report: report(), queueDropsTotal: 0)
        w.setNow(900_000)
        _ = a.tick(report: report(), queueDropsTotal: 0)
        XCTAssertLessThan(a.takeLogWindow().blockedMs, 1_000)
    }

    // MARK: Encoder apply policy

    func testEncoderApplyPolicyNeverDelaysDecreasesOrTheCeilingJump() {
        let ceil = 60_000
        // Decrease: at once.
        XCTAssertTrue(WifiAdaptation.shouldApply(target: 42_000, applied: 60_000, ceiling: ceil, nowUs: 10, lastUpApplyUs: 10))
        // The idle recovery jump to the ceiling: at once, even right after a slope step.
        XCTAssertTrue(WifiAdaptation.shouldApply(target: 60_000, applied: 12_000, ceiling: ceil, nowUs: 100_000,
                                                 lastUpApplyUs: 90_000))
        // A slope step: only every 500 ms.
        XCTAssertFalse(WifiAdaptation.shouldApply(target: 15_000, applied: 12_000, ceiling: ceil, nowUs: 1_400_000,
                                                  lastUpApplyUs: 1_000_000))
        XCTAssertTrue(WifiAdaptation.shouldApply(target: 15_000, applied: 12_000, ceiling: ceil, nowUs: 1_500_000,
                                                 lastUpApplyUs: 1_000_000))
        XCTAssertFalse(WifiAdaptation.shouldApply(target: 12_000, applied: 12_000, ceiling: ceil, nowUs: 9_000_000,
                                                  lastUpApplyUs: 0))
    }

    // MARK: Log window

    func testLogWindowCountsEpisodesNotRetries() {
        let (a, w) = make()
        w.sendBuffer = 400_000
        XCTAssertFalse(a.admit())
        XCTAssertFalse(a.admit())
        w.advance(us: 30_000)  // several retries, still blocked
        w.sendBuffer = 10_000
        w.advance(us: 20_000)
        XCTAssertTrue(a.admit())
        w.sendBuffer = 400_000
        w.advance(us: 5_000)
        XCTAssertFalse(a.admit())  // second episode, still open at the end of the window
        w.advance(us: 100_000)

        _ = a.tick(report: report(srttMs: 9, retx: 2), queueDropsTotal: 0)
        let win = a.takeLogWindow()
        XCTAssertEqual(win.admitsBlocked, 2)
        XCTAssertGreaterThanOrEqual(win.blockedMs, 100)
        XCTAssertEqual(win.srttMs, 9)
        XCTAssertEqual(win.retransmitPackets, 2)
        XCTAssertEqual(win.sendBufferP95, 400_000)
        XCTAssertEqual(win.budgetBytes, a.budgetBytes)
        XCTAssertTrue(win.logFields.hasPrefix("target_kbps="))
        for key in ["sbbytes_p95=", "srtt_ms=", "admits_blocked=", "blocked_ms=", "budget_bytes=", "retx_pkts=",
                    "queue_drops=", "down_steps="] {
            XCTAssertTrue(win.logFields.contains(key), key)
        }

        // The next window starts clean; the open episode keeps counting but is not counted as a new one.
        let next = a.takeLogWindow()
        XCTAssertEqual(next.admitsBlocked, 0)
        XCTAssertEqual(next.retransmitPackets, 0)
        XCTAssertEqual(next.sendBufferP95, 0)
    }

    func testFrameWrittenFeedsTheBudgetFloor() {
        let (a, w) = make(ceilingKbps: 12_000)
        let before = a.budgetBytes  // 12 Mbps: 30 000 bytes of delay budget vs one average frame of 25 000
        for _ in 0..<400 { a.frameWritten(bytes: 100_000) }
        XCTAssertGreaterThan(a.budgetBytes, before, "a single frame can always go: the floor follows the frame size")
        w.sendBuffer = 90_000
        XCTAssertTrue(a.admit())
    }
}
