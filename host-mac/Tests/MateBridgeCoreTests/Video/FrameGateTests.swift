import XCTest
@testable import MateBridgeCore

/// Runs a `FramePacer` against a scripted source in 1 ms steps: a frame "captured" at time t is offered at t
/// (capture time = arrival time), held frames are retried every step, like the encoder's timer would.
private struct Sim {
    var pacer: FramePacer<UInt64>
    var sent: [UInt64] = []
    var overwritten = 0

    init(fps: Int = 60) { pacer = FramePacer<UInt64>(streamFps: fps) }

    mutating func offer(at t: UInt64) {
        switch pacer.offer(t, ptsUs: t, nowUs: t, slotFree: true) {
        case .submit(let f): sent.append(f)
        case .hold, .drop: break
        }
        overwritten += pacer.takeOverwritten()
    }

    mutating func tick(at t: UInt64) {
        if case .submit(let f) = pacer.takePending(nowUs: t, slotFree: true) { sent.append(f) }
        overwritten += pacer.takeOverwritten()
    }

    /// Frames arrive at the given times; time advances in 1 ms steps up to `endUs`.
    mutating func run(arrivals: [UInt64], endUs: UInt64) {
        var i = 0
        var t: UInt64 = 0
        while t <= endUs {
            while i < arrivals.count, arrivals[i] <= t { offer(at: arrivals[i]); i += 1 }
            tick(at: t)
            t += 1_000
        }
    }
}

final class FrameGateTests: XCTestCase {
    func testFirstFrameOpensAndNextSlotIsOneIntervalLater() {
        var g = FrameGate(streamFps: 60)
        XCTAssertEqual(g.waitUs(nowUs: 1_000_000), 0)
        g.accept(nowUs: 1_000_000)
        // next slot at +16 666, may be used 2 ms early
        XCTAssertEqual(g.waitUs(nowUs: 1_000_000), 16_666 - 2_000)
        XCTAssertEqual(g.waitUs(nowUs: 1_015_000), 0)
    }

    func testReanchorsWhenMoreThanOneIntervalBehind() {
        var g = FrameGate(streamFps: 60)
        g.accept(nowUs: 0)
        g.accept(nowUs: 5_000_000)   // long idle: no burst credit
        XCTAssertEqual(g.waitUs(nowUs: 5_000_000), 16_666 - 2_000)
    }

    func testClockGoingBackwardsDoesNotStall() {
        var g = FrameGate(streamFps: 60)
        g.accept(nowUs: 5_000_000)
        XCTAssertLessThanOrEqual(g.waitUs(nowUs: 4_000_000), 1_016_666)  // bounded, not stuck forever
    }

    /// P1: static screen. A frame arriving early is held; no new capture ever comes. The retry uses the current
    /// time, so the held frame goes out as soon as the slot opens, not never.
    func testStaticScreenAfterEarlyFrameSendsPendingWithinOneGap() {
        var sim = Sim()
        sim.offer(at: 0)                       // sent
        sim.offer(at: 5_000)                   // early: held
        XCTAssertEqual(sim.sent, [0])
        XCTAssertTrue(sim.pacer.hasPending)
        var t: UInt64 = 5_000
        while sim.sent.count < 2 && t < 100_000 { t += 1_000; sim.tick(at: t) }
        XCTAssertEqual(sim.sent, [0, 5_000])
        XCTAssertLessThanOrEqual(t, 16_666, "the held frame must go out within one stream interval of the first")
    }

    /// P1: captures at 0, 8 and 17 ms must never send the 8 ms frame after the 17 ms one.
    func testOlderPendingIsDiscardedWhenNewerFrameIsSentDirectly() {
        var sim = Sim()
        sim.offer(at: 0)
        sim.offer(at: 8_000)
        sim.offer(at: 17_000)
        sim.tick(at: 18_000)
        sim.tick(at: 40_000)
        XCTAssertEqual(sim.sent, [0, 17_000])
        XCTAssertEqual(sim.overwritten, 1)
        XCTAssertFalse(sim.pacer.hasPending)
    }

    func testTimestampOlderThanLastSubmittedIsNeverSubmitted() {
        var sim = Sim()
        sim.offer(at: 20_000)
        sim.offer(at: 10_000)                  // older than what was already sent
        sim.tick(at: 60_000)
        XCTAssertEqual(sim.sent, [20_000])
        XCTAssertEqual(sim.overwritten, 1)
        // Same for a stale pending frame found later.
        var p = FramePacer<UInt64>(streamFps: 60)
        _ = p.offer(0, ptsUs: 0, nowUs: 0, slotFree: true)
        _ = p.offer(8_000, ptsUs: 8_000, nowUs: 8_000, slotFree: true)   // held
        _ = p.offer(30_000, ptsUs: 30_000, nowUs: 30_000, slotFree: false) // slot busy: replaces pending
        if case .submit(let f) = p.takePending(nowUs: 31_000, slotFree: true) { XCTAssertEqual(f, 30_000) } else { XCTFail() }
    }

    func testBusyEncoderKeepsOnlyNewestPending() {
        var p = FramePacer<UInt64>(streamFps: 60)
        for t in [0, 1_000, 2_000, 3_000] as [UInt64] {
            _ = p.offer(t, ptsUs: t, nowUs: t, slotFree: false)
        }
        XCTAssertEqual(p.takeOverwritten(), 3)
        if case .submit(let f) = p.takePending(nowUs: 4_000, slotFree: true) { XCTAssertEqual(f, 3_000) } else { XCTFail() }
    }

    func testBypassSkipsGateButKeepsOrder() {
        var p = FramePacer<UInt64>(streamFps: 60)
        _ = p.offer(0, ptsUs: 0, nowUs: 0, slotFree: true)
        if case .submit(let f) = p.offer(3_000, ptsUs: 3_000, nowUs: 3_000, slotFree: true, bypassGate: true) {
            XCTAssertEqual(f, 3_000)
        } else { XCTFail("keyframe re-submission must not wait") }
    }

    /// P2: a steady 75 fps source must come out at no more than 60 fps on average.
    func testSteady75FpsIsLimitedToSixty() {
        var sim = Sim()
        let interval = 1_000_000.0 / 75
        let arrivals = (0..<750).map { UInt64(Double($0) * interval) }   // 10 s
        sim.run(arrivals: arrivals, endUs: 10_000_000)
        XCTAssertLessThanOrEqual(sim.sent.count, 602, "sent \(sim.sent.count) in 10 s")
        XCTAssertGreaterThan(sim.sent.count, 560)
    }

    /// P2: a 60 fps source with jitter loses nothing.
    func testJitteryStreamAtSixtyLosesNoFrames() {
        var sim = Sim()
        var arrivals: [UInt64] = []
        for i in 0..<600 {
            let jitter: Int64 = [0, 1_800, -1_800, 900, -1_500, 1_200][i % 6]
            arrivals.append(UInt64(Int64(100_000) + Int64(i) * 16_666 + jitter))
        }
        sim.run(arrivals: arrivals, endUs: 10_500_000)
        XCTAssertEqual(sim.sent.count, 600)
        XCTAssertEqual(sim.overwritten, 0)
        XCTAssertEqual(sim.sent, sim.sent.sorted(), "timestamps never go backwards")
    }

    /// A 120 fps burst is thinned to the stream rate.
    func testBurstAt120IsThinnedToStreamRate() {
        var sim = Sim()
        let arrivals = (0..<1200).map { UInt64($0) * 8_333 }
        sim.run(arrivals: arrivals, endUs: 10_000_000)
        XCTAssertLessThanOrEqual(sim.sent.count, 602)
    }
}

/// T-058: decimation to the tablet panel rate.
final class DecimationTests: XCTestCase {
    /// Offers a source at `fps` (capture time = arrival time, `count` frames from `startUs`) and returns sent times.
    private func run(_ p: inout FramePacer<UInt64>, fps: Double, from startUs: UInt64, count: Int,
                     jitter: [Int64] = [0]) -> [UInt64] {
        var sent: [UInt64] = []
        for i in 0..<count {
            let t = UInt64(Int64(startUs) + Int64(Double(i) * 1_000_000 / fps) + jitter[i % jitter.count])
            // A hold timer that is due fires before the next capture is offered (a not-yet-due one is a no-op).
            if case .submit(let f) = p.takePending(nowUs: t, slotFree: true) { sent.append(f) }
            if case .submit(let f) = p.offer(t, ptsUs: t, nowUs: t, slotFree: true) { sent.append(f) }
        }
        return sent
    }

    func testEffectiveFpsPolicy() {
        XCTAssertEqual(DisplayRateState.effectiveFps(streamFps: 120, hz: 60), 60)
        XCTAssertEqual(DisplayRateState.effectiveFps(streamFps: 120, hz: 0), 120)
        XCTAssertEqual(DisplayRateState.effectiveFps(streamFps: 120, hz: 144), 120)
        XCTAssertEqual(DisplayRateState.effectiveFps(streamFps: 120, hz: 120), 120)
        XCTAssertEqual(DisplayRateState.effectiveFps(streamFps: 60, hz: 120), 60)
        XCTAssertEqual(DisplayRateState.effectiveFps(streamFps: 120, hz: 5), 24, "garbage is clamped")
        var s = DisplayRateState()
        XCTAssertTrue(s.update(hz: 60))
        XCTAssertFalse(s.update(hz: 60), "same report is no change")
        XCTAssertTrue(s.update(hz: 120))
    }

    func testDecimates120To60PickingEverySecondCaptureEvenly() {
        var p = FramePacer<UInt64>(streamFps: 120)
        p.setTargetFps(60)
        let sent = run(&p, fps: 120, from: 1_000_000, count: 240)
        XCTAssertEqual(sent.count, 120)
        let gaps = zip(sent.dropFirst(), sent).map { $0 - $1 }
        XCTAssertLessThanOrEqual(gaps.max()! - gaps.min()!, 1, "every second capture, equal spacing: \(gaps.prefix(6))")
        XCTAssertEqual(p.takeDecimated(), 119, "off-grid frames were superseded by the next grid frame")
        XCTAssertEqual(p.takeDeferred(), 0, "the hold timer never fires on a steady stream")
        XCTAssertEqual(p.takeOverwritten(), 0)
    }

    func testDecimationStaysEvenWithCaptureJitter() {
        var p = FramePacer<UInt64>(streamFps: 120)
        p.setTargetFps(60)
        let sent = run(&p, fps: 120, from: 1_000_000, count: 600, jitter: [0, 900, -700, 500, -400, 800])
        XCTAssertEqual(sent.count, 300)
        let gaps = zip(sent.dropFirst(), sent).map { Int64($0) - Int64($1) }
        XCTAssertTrue(gaps.allSatisfy { (14_000...19_500).contains($0) }, "gaps: \(gaps.min()!)...\(gaps.max()!)")
    }

    func testLoneOffGridFrameIsSentAfterSlotPlusGrace() {
        var p = FramePacer<UInt64>(streamFps: 120)
        p.setTargetFps(60)
        _ = p.offer(0, ptsUs: 0, nowUs: 0, slotFree: true)   // grid frame, next slot 16 666
        guard case .hold(let retry) = p.offer(8_333, ptsUs: 8_333, nowUs: 8_333, slotFree: true) else { return XCTFail() }
        // slot 16 666 + grace 4 166 = 20 832; arrived at 8 333.
        XCTAssertEqual(retry, 12_499)
        if case .retry(let w) = p.takePending(nowUs: 15_000, slotFree: true) { XCTAssertEqual(w, 5_832) } else { XCTFail("not due yet") }
        if case .submit(let f) = p.takePending(nowUs: 20_900, slotFree: true) { XCTAssertEqual(f, 8_333) } else { XCTFail() }
        XCTAssertEqual(p.takeDeferred(), 1)
        XCTAssertEqual(p.takeDecimated(), 0)
        XCTAssertEqual(p.lastSubmittedPtsUs, 8_333)
        // The timer-sent frame advanced the grid: the next slot is 33 332, the capture at 25 000 is held again.
        if case .hold = p.offer(25_000, ptsUs: 25_000, nowUs: 25_000, slotFree: true) {} else { XCTFail() }
        if case .submit = p.offer(33_400, ptsUs: 33_400, nowUs: 33_400, slotFree: true) {} else { XCTFail() }
    }

    func testTypingBurstLastFrameIsSent() {
        // A key makes two captures 8.3 ms apart, then the screen is still: the second one must be encoded.
        var p = FramePacer<UInt64>(streamFps: 120)
        p.setTargetFps(60)
        _ = p.offer(0, ptsUs: 0, nowUs: 0, slotFree: true)
        // 8 333 is held; 16 667 passes the grid (slot 16 666) and replaces it...
        _ = p.offer(8_333, ptsUs: 8_333, nowUs: 8_333, slotFree: true)
        if case .submit(let f) = p.offer(16_667, ptsUs: 16_667, nowUs: 16_667, slotFree: true) { XCTAssertEqual(f, 16_667) } else { XCTFail() }
        // ...and a lone off-grid second frame after a long idle is sent by the timer.
        _ = p.offer(1_000_000, ptsUs: 1_000_000, nowUs: 1_000_000, slotFree: true)
        _ = p.offer(1_008_333, ptsUs: 1_008_333, nowUs: 1_008_333, slotFree: true)
        if case .submit(let f) = p.takePending(nowUs: 1_030_000, slotFree: true) { XCTAssertEqual(f, 1_008_333) } else { XCTFail() }
        XCTAssertNil({ () -> UInt64? in if case .submit(let f) = p.takePending(nowUs: 1_100_000, slotFree: true) { return f }; return nil }())
    }

    func testStaleTimerDoesNotFlushNewerPendingEarly() {
        var p = FramePacer<UInt64>(streamFps: 120)
        p.setTargetFps(60)
        _ = p.offer(0, ptsUs: 0, nowUs: 0, slotFree: true)
        _ = p.offer(8_333, ptsUs: 8_333, nowUs: 8_333, slotFree: true)
        _ = p.offer(16_667, ptsUs: 16_667, nowUs: 16_667, slotFree: true)   // grid frame replaces the pending one
        _ = p.offer(25_000, ptsUs: 25_000, nowUs: 25_000, slotFree: true)   // new pending, slot 33 332 + 4 166
        if case .retry = p.takePending(nowUs: 21_000, slotFree: true) {} else { XCTFail("stale timer must not send it") }
    }

    func testRaisingTo120AppliesOnTheNextFrame() {
        var p = FramePacer<UInt64>(streamFps: 120)
        p.setTargetFps(60)
        _ = run(&p, fps: 120, from: 0, count: 10)
        p.setTargetFps(120)
        XCTAssertFalse(p.decimating)
        var sent: [UInt64] = []
        for i in 0..<10 {
            let t = 100_000 + UInt64(Double(i) * 1_000_000 / 120)
            if case .submit(let f) = p.offer(t, ptsUs: t, nowUs: t, slotFree: true) { sent.append(f) }
        }
        XCTAssertEqual(sent.count, 10, "all captures pass at 120")
    }

    func testLoweringAppliesImmediately() {
        var p = FramePacer<UInt64>(streamFps: 120)
        XCTAssertEqual(run(&p, fps: 120, from: 0, count: 20).count, 20)
        p.setTargetFps(60)
        XCTAssertEqual(run(&p, fps: 120, from: 200_000, count: 20).count, 10)
    }

    func testNoDisplayRateMessageLeavesBehaviourUnchanged() {
        var a = FramePacer<UInt64>(streamFps: 120)
        var b = FramePacer<UInt64>(streamFps: 120)
        b.setTargetFps(DisplayRateState().effectiveFps(streamFps: 120))   // hz 0: stream fps
        XCTAssertFalse(b.decimating)
        let jitter: [Int64] = [0, 1_500, -1_200, 600]
        XCTAssertEqual(run(&a, fps: 120, from: 0, count: 240, jitter: jitter),
                       run(&b, fps: 120, from: 0, count: 240, jitter: jitter))
        b.setTargetFps(500)   // above the stream fps: capped, still not decimating
        XCTAssertFalse(b.decimating)
    }

    func testBusyEncoderHoldsNewestPassedFrameWhileDecimating() {
        var p = FramePacer<UInt64>(streamFps: 120)
        p.setTargetFps(60)
        _ = p.offer(0, ptsUs: 0, nowUs: 0, slotFree: true)
        if case .hold(let retry) = p.offer(16_700, ptsUs: 16_700, nowUs: 16_700, slotFree: false) {
            XCTAssertNil(retry, "no timer: the slot release submits it")
        } else { XCTFail("expected hold") }
        if case .submit(let f) = p.takePending(nowUs: 17_000, slotFree: true) { XCTAssertEqual(f, 16_700) } else { XCTFail() }
        // The grid was advanced once: the capture at 25 ms is off-grid (held), the one at 33.4 ms passes and replaces it.
        if case .hold = p.offer(25_000, ptsUs: 25_000, nowUs: 25_000, slotFree: true) {} else { XCTFail("25 ms is off-grid") }
        if case .submit = p.offer(33_400, ptsUs: 33_400, nowUs: 33_400, slotFree: true) {} else { XCTFail("33.4 ms is on-grid") }
        XCTAssertFalse(p.hasPending)
    }

    func testKeyframeBypassStillGoesThroughWhileDecimating() {
        var p = FramePacer<UInt64>(streamFps: 120)
        p.setTargetFps(60)
        _ = p.offer(0, ptsUs: 0, nowUs: 0, slotFree: true)
        if case .submit = p.offer(3_000, ptsUs: 3_000, nowUs: 3_000, slotFree: true, bypassGate: true) {} else { XCTFail() }
    }
}
