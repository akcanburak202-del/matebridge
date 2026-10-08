import XCTest
@testable import MateBridgeCore

final class CadenceTests: XCTestCase {
    func testPercentileNearestRank() {
        let s: [UInt64] = Array(1...100)
        XCTAssertEqual(CadenceWindow.percentile(s, 50), 50)
        XCTAssertEqual(CadenceWindow.percentile(s, 95), 95)
        XCTAssertEqual(CadenceWindow.percentile(s, 99), 99)
        XCTAssertEqual(CadenceWindow.percentile([], 50), 0)
        XCTAssertEqual(CadenceWindow.percentile([7], 99), 7)
        XCTAssertEqual(CadenceWindow.percentile([3, 1, 2], 100), 3)
    }

    func testIntervalsAndLateCountOnlyForCompleteFrames() {
        let m = CadenceMeter(fps: 60)   // target 16 666 us, late > 25 000 us
        m.start(nowUs: 0)
        m.recordCapture(status: "complete", ptsUs: 1_000_000, arrivalUs: 1_000_100)
        m.recordCapture(status: "complete", ptsUs: 1_016_666, arrivalUs: 1_016_800)
        m.recordCapture(status: "idle", ptsUs: 1_020_000, arrivalUs: 1_020_000)   // no interval, only counted
        m.recordCapture(status: "complete", ptsUs: 1_050_000, arrivalUs: 1_050_200) // 33 334 us: late
        let w = m.take(nowUs: 1_000_000, queueDropsTotal: 0, sentTotal: 0)
        XCTAssertEqual(w.captured, 3)
        XCTAssertEqual(w.statusCounts["idle"], 1)
        XCTAssertEqual(w.captureIntervalsUs, [16_666, 33_334])
        XCTAssertEqual(w.lateCaptureIntervals, 1)
        XCTAssertEqual(w.lateArrivalIntervals, 1)
        XCTAssertEqual(w.captureFps, 3, accuracy: 0.001)
    }

    func testEncoderCountersAndCumulativeDeltas() {
        let m = CadenceMeter(fps: 60)
        m.start(nowUs: 0)
        for _ in 0..<5 { m.recordEncoderIn() }
        m.recordOverwritten()
        m.recordEncoderOut(encodeTimeUs: 10_000)
        m.recordEncoderOut(encodeTimeUs: 20_000)
        let a = m.take(nowUs: 500_000, queueDropsTotal: 2, sentTotal: 4)
        XCTAssertEqual([a.encoderIn, a.encoderOut, a.overwritten, a.queueDrops, a.sent], [5, 2, 1, 2, 4])
        XCTAssertEqual(a.encoderOutFps, 4, accuracy: 0.001)
        XCTAssertEqual(a.sentFps, 8, accuracy: 0.001)
        // Second window: cumulative counters grow -> delta; a reset counter (new sender) is taken as is.
        let b = m.take(nowUs: 1_500_000, queueDropsTotal: 3, sentTotal: 1)
        XCTAssertEqual([b.queueDrops, b.sent, b.encoderIn], [1, 1, 0])
        XCTAssertEqual(b.durationUs, 1_000_000)
        XCTAssertTrue(CadenceWindow(targetIntervalUs: 1).isEmpty)
    }

    func testIntervalStateSurvivesWindowBoundary() {
        let m = CadenceMeter(fps: 60)
        m.start(nowUs: 0)
        m.recordCapture(status: "complete", ptsUs: 100, arrivalUs: 100)
        _ = m.take(nowUs: 1000, queueDropsTotal: 0, sentTotal: 0)
        m.recordCapture(status: "complete", ptsUs: 16_766, arrivalUs: 16_766)
        let w = m.take(nowUs: 2000, queueDropsTotal: 0, sentTotal: 0)
        XCTAssertEqual(w.captureIntervalsUs, [16_666])
    }

    func testMergeAndLogFields() {
        var a = CadenceWindow(targetIntervalUs: 16_666)
        a.durationUs = 1_000_000
        a.recordStatus("complete"); a.recordStatus("blank")
        a.recordCaptureInterval(16_000)
        a.sent = 1
        var b = CadenceWindow(targetIntervalUs: 16_666)
        b.durationUs = 1_000_000
        b.recordStatus("complete")
        b.recordCaptureInterval(40_000)
        b.sent = 2
        a.merge(b)
        XCTAssertEqual(a.captured, 2)
        XCTAssertEqual(a.sent, 3)
        XCTAssertEqual(a.durationUs, 2_000_000)
        XCTAssertEqual(a.lateCaptureIntervals, 1)
        let f = a.logFields
        XCTAssertTrue(f.contains("status=blank=1,complete=2"), f)
        XCTAssertTrue(f.contains("cap_late=1"), f)
        XCTAssertTrue(f.contains("sent=3"), f)
        XCTAssertEqual(a.menuText, "cap 1 / enc 0 / sent 2 fps")
    }

    func testSamplesAreBounded() {
        var w = CadenceWindow(targetIntervalUs: 1)
        for i in 0..<10_000 { w.recordCaptureInterval(UInt64(i)) }
        XCTAssertEqual(w.captureIntervalsUs.count, CadenceWindow.maxSamples)
    }

    func testRefreshIsIndependentOfStreamFps() {
        XCTAssertEqual(VideoSettings.tabletDefault.displayRefreshHz, 60)
        // The stream fps is independent of the display refresh rate.
        var s = VideoSettings.tabletDefault
        s.displayRefreshHz = 120
        XCTAssertEqual(s.streamConfig(configID: 1).fps, 60)
    }
}

final class CadenceTargetTests: XCTestCase {
    func testTargetFollowsTheEffectiveRate() {
        let m = CadenceMeter(fps: 120)
        m.setTargetFps(60)
        m.recordDecimated()
        let w = m.take(nowUs: 1_000_000, queueDropsTotal: 0, sentTotal: 0)
        XCTAssertEqual(w.targetIntervalUs, 16_666)
        XCTAssertEqual(w.decimated, 1)
        XCTAssertTrue(w.logFields.contains("target_ms=16.7"))
        XCTAssertTrue(w.logFields.contains("decimated=1"))
        XCTAssertTrue(w.logFields.contains("deferred=0"))
    }
}
