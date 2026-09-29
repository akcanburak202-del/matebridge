import XCTest
@testable import MateBridgeCore

final class FrameGateTests: XCTestCase {
    func testFirstFrameAndSpacedFramesPass() {
        var g = FrameGate(streamFps: 60, gapFraction: 0.75)   // gap 12 499 us
        XCTAssertEqual(g.minGapUs, 12_499)
        XCTAssertEqual(g.waitUs(forPtsUs: 1_000_000), 0)
        g.accept(ptsUs: 1_000_000)
        XCTAssertEqual(g.waitUs(forPtsUs: 1_016_666), 0)
    }

    func testEarlyFrameWaitsForRemainingGap() {
        var g = FrameGate(streamFps: 60, gapFraction: 0.75)
        g.accept(ptsUs: 1_000_000)
        XCTAssertEqual(g.waitUs(forPtsUs: 1_008_333), 12_499 - 8_333)
    }

    /// A 120 fps burst is thinned to the stream rate: simulate hold-then-send and count what goes out.
    func testBurstAt120IsLimitedToStreamRate() {
        var g = FrameGate(streamFps: 60)
        var sent = 0
        var nowUs: UInt64 = 0
        while nowUs < 10_000_000 {
            nowUs += 8_333
            if g.waitUs(forPtsUs: nowUs) == 0 { g.accept(ptsUs: nowUs); sent += 1 }
        }
        // Input is 120/s; every second frame passes (16.7 ms apart), i.e. 60/s.
        XCTAssertLessThanOrEqual(sent, 620)
        XCTAssertGreaterThan(sent, 550)
    }

    func testSteadySixtyWithJitterIsNotDelayed() {
        var g = FrameGate(streamFps: 60)
        var delayed = 0
        var t: UInt64 = 1_000_000
        for i in 0..<600 {
            // alternating +-2.5 ms jitter around 16.666 ms
            t += i % 2 == 0 ? 16_666 + 2_500 : 16_666 - 2_500
            if g.waitUs(forPtsUs: t) > 0 { delayed += 1 }
            g.accept(ptsUs: t)
        }
        XCTAssertEqual(delayed, 0)
    }

    func testClockGoingBackwardsDoesNotStall() {
        var g = FrameGate(streamFps: 60)
        g.accept(ptsUs: 5_000_000)
        XCTAssertEqual(g.waitUs(forPtsUs: 4_000_000), 0)
    }
}
