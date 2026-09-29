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
