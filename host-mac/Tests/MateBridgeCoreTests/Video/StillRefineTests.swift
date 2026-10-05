import XCTest
@testable import MateBridgeCore

final class StillRefineTests: XCTestCase {
    private func config(_ edit: (inout StillRefineConfig) -> Void = { _ in }) -> StillRefineConfig {
        var c = StillRefineConfig.resolve(env: [:], transport: .usb)
        edit(&c)
        return c
    }

    func testConfigDefaults() {
        let usb = StillRefineConfig.resolve(env: [:], transport: .usb)
        XCTAssertTrue(usb.enabled)
        XCTAssertEqual(usb.stillUs, 200_000)
        XCTAssertEqual(usb.maxBytes, 1024 * 1024)
        XCTAssertEqual(usb.maxFrames, 16)
        XCTAssertEqual(StillRefineConfig.resolve(env: [:], transport: .network).maxBytes, 256 * 1024)
    }

    func testConfigEnv() {
        XCTAssertFalse(StillRefineConfig.resolve(env: ["MATEBRIDGE_REFINE": "0"], transport: .usb).enabled)
        XCTAssertTrue(StillRefineConfig.resolve(env: ["MATEBRIDGE_REFINE": "1"], transport: .usb).enabled)
        let c = StillRefineConfig.resolve(env: ["MATEBRIDGE_REFINE_MS": "300", "MATEBRIDGE_REFINE_KB": "512",
                                                "MATEBRIDGE_REFINE_FRAMES": "8"], transport: .network)
        XCTAssertEqual(c.stillUs, 300_000)
        XCTAssertEqual(c.maxBytes, 512 * 1024)
        XCTAssertEqual(c.maxFrames, 8)
        let bad = StillRefineConfig.resolve(env: ["MATEBRIDGE_REFINE_MS": "5", "MATEBRIDGE_REFINE_KB": "x",
                                                  "MATEBRIDGE_REFINE_FRAMES": "0"], transport: .usb)
        XCTAssertEqual(bad.stillUs, 200_000)
        XCTAssertEqual(bad.maxBytes, 1024 * 1024)
        XCTAssertEqual(bad.maxFrames, 16)
    }

    func testNoTrainWhileMovingOrBeforeFirstCapture() {
        var p = StillRefinePolicy(config: config())
        XCTAssertFalse(p.tick(nowUs: 10_000_000, queueReady: true).start)  // never captured
        p.noteCapture(nowUs: 1_000_000)
        XCTAssertFalse(p.tick(nowUs: 1_100_000, queueReady: true).start)   // 100 ms < 200 ms
        p.noteCapture(nowUs: 1_150_000)
        XCTAssertFalse(p.tick(nowUs: 1_300_000, queueReady: true).start)   // restarted by the newer capture
        XCTAssertTrue(p.tick(nowUs: 1_350_000, queueReady: true).start)
    }

    func testBusyQueueDelaysStartWithoutLosingIt() {
        var p = StillRefinePolicy(config: config())
        p.noteCapture(nowUs: 0)
        XCTAssertFalse(p.tick(nowUs: 300_000, queueReady: false).start)
        XCTAssertTrue(p.tick(nowUs: 320_000, queueReady: true).start)
    }

    func testTrainRunsUntilConverged() {
        var p = StillRefinePolicy(config: config())
        p.noteCapture(nowUs: 0)
        XCTAssertTrue(p.tick(nowUs: 250_000, queueReady: true).start)
        var t: UInt64 = 250_000
        for bytes in [30_000, 20_000, 9_000, 3_000] {
            t += 16_000
            let r = p.noteOutput(bytes: bytes, nowUs: t, queueReady: true)
            XCTAssertTrue(r.submitNext)
            XCTAssertNil(r.report)
        }
        let end = p.noteOutput(bytes: 900, nowUs: t + 16_000, queueReady: true)
        XCTAssertFalse(end.submitNext)
        XCTAssertEqual(end.report?.reason, .converged)
        XCTAssertEqual(end.report?.frames, 5)
        XCTAssertEqual(end.report?.bytes, 62_900)
        XCTAssertEqual(end.report?.firstBytes, 30_000)
        XCTAssertEqual(end.report?.lastBytes, 900)
        XCTAssertFalse(p.isRunning)
    }

    func testMaxFramesAndMaxBytes() {
        var p = StillRefinePolicy(config: config { $0.maxFrames = 3 })
        p.noteCapture(nowUs: 0)
        XCTAssertTrue(p.tick(nowUs: 300_000, queueReady: true).start)
        XCTAssertTrue(p.noteOutput(bytes: 5_000, nowUs: 1, queueReady: true).submitNext)
        XCTAssertTrue(p.noteOutput(bytes: 5_000, nowUs: 2, queueReady: true).submitNext)
        XCTAssertEqual(p.noteOutput(bytes: 5_000, nowUs: 3, queueReady: true).report?.reason, .maxFrames)

        var q = StillRefinePolicy(config: config { $0.maxBytes = 20_000 })
        q.noteCapture(nowUs: 0)
        XCTAssertTrue(q.tick(nowUs: 300_000, queueReady: true).start)
        XCTAssertTrue(q.noteOutput(bytes: 9_000, nowUs: 1, queueReady: true).submitNext)
        let r = q.noteOutput(bytes: 12_000, nowUs: 2, queueReady: true)
        XCTAssertFalse(r.submitNext)
        XCTAssertEqual(r.report?.reason, .maxBytes)
    }

    func testBusyQueueStopsTrain() {
        var p = StillRefinePolicy(config: config())
        p.noteCapture(nowUs: 0)
        XCTAssertTrue(p.tick(nowUs: 300_000, queueReady: true).start)
        let r = p.noteOutput(bytes: 20_000, nowUs: 1, queueReady: false)
        XCTAssertFalse(r.submitNext)
        XCTAssertEqual(r.report?.reason, .queueBusy)
    }

    func testCaptureCancelsAndLateOutputIsIgnored() {
        var p = StillRefinePolicy(config: config())
        p.noteCapture(nowUs: 0)
        XCTAssertTrue(p.tick(nowUs: 300_000, queueReady: true).start)
        XCTAssertTrue(p.noteOutput(bytes: 20_000, nowUs: 316_000, queueReady: true).submitNext)
        let cancelled = p.noteCapture(nowUs: 320_000)
        XCTAssertEqual(cancelled?.reason, .cancelled)
        XCTAssertEqual(cancelled?.frames, 1)
        // The refine frame that was still in the encoder produces output after the cancel: nothing happens.
        let late = p.noteOutput(bytes: 20_000, nowUs: 330_000, queueReady: true)
        XCTAssertFalse(late.submitNext)
        XCTAssertNil(late.report)
        XCTAssertFalse(p.isRunning)
    }

    func testNewTrainNeedsNewCaptureAndGap() {
        var p = StillRefinePolicy(config: config())
        p.noteCapture(nowUs: 0)
        XCTAssertTrue(p.tick(nowUs: 300_000, queueReady: true).start)
        XCTAssertNotNil(p.noteOutput(bytes: 100, nowUs: 306_000, queueReady: true).report)  // converged at once
        // Still, but no capture since: no second train, however long it waits.
        XCTAssertFalse(p.tick(nowUs: 5_000_000, queueReady: true).start)
        // A capture re-arms; the 500 ms gap is counted from the previous train's start (300 ms).
        p.noteCapture(nowUs: 400_000)
        XCTAssertFalse(p.tick(nowUs: 650_000, queueReady: true).start)  // 350 ms after the previous start
        XCTAssertTrue(p.tick(nowUs: 800_000, queueReady: true).start)
    }

    func testTimeoutEndsStuckTrain() {
        var p = StillRefinePolicy(config: config())
        p.noteCapture(nowUs: 0)
        XCTAssertTrue(p.tick(nowUs: 300_000, queueReady: true).start)
        XCTAssertNil(p.tick(nowUs: 400_000, queueReady: true).timedOut)
        let r = p.tick(nowUs: 560_000, queueReady: true).timedOut
        XCTAssertEqual(r?.reason, .timeout)
        XCTAssertFalse(p.isRunning)
    }

    func testFailureEndsTrain() {
        var p = StillRefinePolicy(config: config())
        p.noteCapture(nowUs: 0)
        XCTAssertNil(p.noteFailure(nowUs: 1))
        XCTAssertTrue(p.tick(nowUs: 300_000, queueReady: true).start)
        XCTAssertEqual(p.noteFailure(nowUs: 310_000)?.reason, .failed)
    }

    func testDisabledNeverStarts() {
        var p = StillRefinePolicy(config: config { $0.enabled = false })
        XCTAssertNil(p.noteCapture(nowUs: 0))
        XCTAssertFalse(p.tick(nowUs: 10_000_000, queueReady: true).start)
    }

    func testReportLogFields() {
        let r = StillRefineReport(frames: 12, bytes: 375_000, firstBytes: 10_000, lastBytes: 440, durationUs: 205_000,
                                  reason: .converged)
        XCTAssertEqual(r.logFields,
                       "frames=12 bytes=375000 first_bytes=10000 last_bytes=440 ms=205 reason=converged")
    }

    func testTrainIDRevalidation() {
        var p = StillRefinePolicy(config: config())
        p.noteCapture(nowUs: 0)
        XCTAssertTrue(p.tick(nowUs: 300_000, queueReady: true).start)
        let first = p.trainID
        XCTAssertTrue(p.isCurrent(first))
        p.noteCapture(nowUs: 310_000)  // cancel: a refine frame validated later is refused
        XCTAssertFalse(p.isCurrent(first))
        XCTAssertTrue(p.tick(nowUs: 900_000, queueReady: true).start)
        XCTAssertNotEqual(p.trainID, first)
        XCTAssertFalse(p.isCurrent(first))
        XCTAssertTrue(p.isCurrent(p.trainID))
    }

    func testPendingKeyframeBlocksStartAndEndsTrain() {
        var p = StillRefinePolicy(config: config())
        p.noteCapture(nowUs: 0)
        XCTAssertFalse(p.tick(nowUs: 300_000, queueReady: true, keyframePending: true).start)
        XCTAssertTrue(p.tick(nowUs: 310_000, queueReady: true, keyframePending: false).start)
        let r = p.noteOutput(bytes: 20_000, nowUs: 320_000, queueReady: true, keyframePending: true)
        XCTAssertFalse(r.submitNext)
        XCTAssertEqual(r.report?.reason, .keyframePending)
        var q = StillRefinePolicy(config: config())
        q.noteCapture(nowUs: 0)
        XCTAssertTrue(q.tick(nowUs: 300_000, queueReady: true).start)
        XCTAssertEqual(q.end(.keyframePending, nowUs: 310_000)?.reason, .keyframePending)
        XCTAssertNil(q.end(.keyframePending, nowUs: 311_000))
    }

    func testByteCeilingIsConservative() {
        // The next frame is assumed as large as the largest so far: 100 + 90 + 100 > 250 stops before a third
        // frame could overshoot.
        var p = StillRefinePolicy(config: config { $0.maxBytes = 250_000 })
        p.noteCapture(nowUs: 0)
        XCTAssertTrue(p.tick(nowUs: 300_000, queueReady: true).start)
        XCTAssertTrue(p.noteOutput(bytes: 100_000, nowUs: 1, queueReady: true).submitNext)
        let r = p.noteOutput(bytes: 90_000, nowUs: 2, queueReady: true)
        XCTAssertFalse(r.submitNext)
        XCTAssertEqual(r.report?.reason, .maxBytes)
        XCTAssertLessThanOrEqual(r.report?.bytes ?? Int.max, 250_000)
    }

    func testQueueReadyForRefine() {
        let q = VideoFrameQueue(keyframeNeeded: {})
        XCTAssertTrue(q.isReadyForRefine)
        q.push(EncodedVideoFrame(flags: .keyframe, captureTimeUs: 1, data: [1]))
        XCTAssertFalse(q.isReadyForRefine)
        q.finish()
        XCTAssertFalse(q.isReadyForRefine)
    }
}
