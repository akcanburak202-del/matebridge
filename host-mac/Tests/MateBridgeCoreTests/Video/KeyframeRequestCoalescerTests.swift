import XCTest
@testable import MateBridgeCore

/// T-122: client keyframe requests coalesce while a keyframe is on its way or was just written. Fake clock in µs.
final class KeyframeRequestCoalescerTests: XCTestCase {
    private let ms: UInt64 = 1000

    /// Drives the coalescer like the pipeline: `pushed` is the queue's keyframe push count, and a forced keyframe is
    /// pushed after `encodeMs` and written after `writeMs` (both from the force).
    private struct Sim {
        var c = KeyframeRequestCoalescer()
        var pushed: UInt64 = 0
        var forced = 0
        var inEncoder: [UInt64] = []   // push times of keyframes still in the encoder
        var inQueue: [UInt64] = []     // write-done times of keyframes pushed to the queue
        let encodeUs: UInt64
        let writeUs: UInt64

        init(encodeMs: UInt64 = 10, writeMs: UInt64 = 60) {
            encodeUs = encodeMs * 1000
            writeUs = writeMs * 1000
        }

        /// Advances to `now`: pushes and writes keyframes that are due.
        mutating func advance(to now: UInt64) {
            while let t = inEncoder.first, t <= now {
                inEncoder.removeFirst()
                pushed += 1
                inQueue.append(t - encodeUs + writeUs)
            }
            while let t = inQueue.first, t <= now {
                inQueue.removeFirst()
                c.keyframeWritten(nowUs: t, bytes: 500_000)
            }
        }

        mutating func request(_ reason: KeyframeReason, at now: UInt64) -> KeyframeRequestCoalescer.Decision {
            advance(to: now)
            let d = c.request(reason, nowUs: now, keyframesPushed: pushed, configResent: reason.resendsCodecConfig)
            if d.forceKeyframe {
                forced += 1
                inEncoder.append(now + encodeUs)
            }
            return d
        }
    }

    func testSingleRequestForcesAKeyframe() {
        var c = KeyframeRequestCoalescer()
        let d = c.request(.framesDropped, nowUs: 1_000_000, keyframesPushed: 0)
        XCTAssertEqual(d, .init(action: .forced, forceKeyframe: true, sinceIdrUs: nil))
        XCTAssertEqual(d.logFields, "action=forced idr_forced=1 since_idr_ms=-")
    }

    func testFourRequestsWithin200msForceOneKeyframe() {
        var sim = Sim()
        let t0: UInt64 = 5_000_000
        let actions = [0, 50, 120, 200].map { sim.request(.framesDropped, at: t0 + UInt64($0) * ms).action }
        XCTAssertEqual(actions, [.forced, .coalesced, .coalesced, .coalesced])
        XCTAssertEqual(sim.forced, 1)
        XCTAssertEqual(sim.c.coalescedTotal, 3)
    }

    func testCoalescesWhileTheKeyframeIsStillBeingWritten() {
        // Slow link: the IDR takes 400 ms to write; requests during the write never force another one.
        var sim = Sim(writeMs: 400)
        let t0: UInt64 = 1_000_000
        for off in [0, 100, 200, 300, 390] as [UInt64] { _ = sim.request(.framesDropped, at: t0 + off * ms) }
        XCTAssertEqual(sim.forced, 1)
        // Written at t0 + 400 ms; 249 ms later still inside the window.
        XCTAssertEqual(sim.request(.framesDropped, at: t0 + 649 * ms).action, .coalesced)
        XCTAssertEqual(sim.forced, 1)
    }

    func testRequestAfterTheWindowForcesANewKeyframe() {
        var sim = Sim()
        let t0: UInt64 = 1_000_000
        _ = sim.request(.framesDropped, at: t0)               // written at t0 + 60 ms
        let d = sim.request(.framesDropped, at: t0 + 60 * ms + KeyframeRequestCoalescer.defaultWindowUs)
        XCTAssertEqual(d.action, .forced)
        XCTAssertEqual(d.sinceIdrUs, KeyframeRequestCoalescer.defaultWindowUs)
        XCTAssertEqual(d.logFields, "action=forced idr_forced=1 since_idr_ms=250")
        XCTAssertEqual(sim.forced, 2)
    }

    func testPendingKeyframeThatNeverArrivesStopsAbsorbingAfterTheTimeout() {
        var c = KeyframeRequestCoalescer()
        _ = c.request(.framesDropped, nowUs: 0, keyframesPushed: 0)
        XCTAssertEqual(c.request(.framesDropped, nowUs: 999_999, keyframesPushed: 0).action, .coalesced)
        XCTAssertEqual(c.request(.framesDropped, nowUs: 1_000_000, keyframesPushed: 0).action, .forced)
    }

    func testStartupResendsConfigAndForcesWhenNothingIsPending() {
        var c = KeyframeRequestCoalescer()
        let d = c.request(.startup, nowUs: 1_000_000, keyframesPushed: 3, configResent: true)
        XCTAssertEqual(d, .init(action: .configResent, forceKeyframe: true, sinceIdrUs: nil))
        XCTAssertEqual(d.logFields, "action=config_resent idr_forced=1 since_idr_ms=-")
    }

    func testStartupReusesAKeyframeStillInsideTheEncoder() {
        var c = KeyframeRequestCoalescer()
        _ = c.request(.framesDropped, nowUs: 0, keyframesPushed: 7)
        // Nothing pushed since the force: the keyframe will be queued behind the re-sent config.
        let d = c.request(.startup, nowUs: 5 * ms, keyframesPushed: 7, configResent: true)
        XCTAssertEqual(d.action, .configResent)
        XCTAssertFalse(d.forceKeyframe)
    }

    func testStartupForcesWhenThePendingKeyframeWasAlreadyQueued() {
        var c = KeyframeRequestCoalescer()
        _ = c.request(.framesDropped, nowUs: 0, keyframesPushed: 7)
        // Pushed (the resync discards it, or it is being written ahead of the config): a new one is needed.
        let d = c.request(.decodeError, nowUs: 20 * ms, keyframesPushed: 8, configResent: true)
        XCTAssertEqual(d.action, .configResent)
        XCTAssertTrue(d.forceKeyframe)
        // ... and later FRAMES_DROPPED requests coalesce with the new one.
        XCTAssertEqual(c.request(.framesDropped, nowUs: 30 * ms, keyframesPushed: 8).action, .coalesced)
    }

    func testStartupForcesEvenRightAfterAWrittenKeyframe() {
        // A keyframe written before the config is of no use to a rebuilt decoder.
        var c = KeyframeRequestCoalescer()
        c.keyframeWritten(nowUs: 100 * ms, bytes: 1)
        let d = c.request(.startup, nowUs: 110 * ms, keyframesPushed: 1, configResent: true)
        XCTAssertTrue(d.forceKeyframe)
        XCTAssertEqual(d.sinceIdrUs, 10 * ms)
    }

    func testStartupWithoutParameterSetsIsAPlainForce() {
        var c = KeyframeRequestCoalescer()
        let d = c.request(.startup, nowUs: 0, keyframesPushed: 0, configResent: false)
        XCTAssertEqual(d.action, .forced)
        XCTAssertTrue(d.forceKeyframe)
    }

    func testStormWithAStartupInTheMiddle() {
        // Device pattern: FRAMES_DROPPED x3, STARTUP, FRAMES_DROPPED x2 within 300 ms (was 6 IDRs).
        var sim = Sim(writeMs: 80)
        let t0: UInt64 = 2_000_000
        var actions: [KeyframeRequestCoalescer.Action] = []
        for (off, reason) in [(0, KeyframeReason.framesDropped), (40, .framesDropped), (90, .framesDropped),
                              (130, .startup), (200, .framesDropped), (300, .framesDropped)] {
            actions.append(sim.request(reason, at: t0 + UInt64(off) * ms).action)
        }
        XCTAssertEqual(actions, [.forced, .coalesced, .coalesced, .configResent, .coalesced, .coalesced])
        XCTAssertEqual(sim.forced, 2, "one for FRAMES_DROPPED, one behind the re-sent config")
    }

    func testInternalForceAbsorbsClientRequests() {
        var c = KeyframeRequestCoalescer()
        c.internalForce(nowUs: 0, keyframesPushed: 0)
        XCTAssertEqual(c.request(.framesDropped, nowUs: 30 * ms, keyframesPushed: 0).action, .coalesced)
    }

    func testResetForgetsEarlierWritesButKeepsTheNewConsumerKeyframePending() {
        var c = KeyframeRequestCoalescer()
        c.keyframeWritten(nowUs: 0, bytes: 1)
        c.reset(nowUs: 10 * ms, keyframesPushed: 4)
        // STARTUP of the new client while the new consumer's keyframe is still in the encoder: no second IDR.
        let d = c.request(.startup, nowUs: 15 * ms, keyframesPushed: 4, configResent: true)
        XCTAssertFalse(d.forceKeyframe)
        XCTAssertNil(d.sinceIdrUs)
    }

    func testWindowCountsWrittenKeyframes() {
        var c = KeyframeRequestCoalescer()
        XCTAssertEqual(c.takeWindow().logFields, "idr=0 idr_bytes_max=0")
        c.keyframeWritten(nowUs: 1, bytes: 300_000)
        c.keyframeWritten(nowUs: 2, bytes: 900_000)
        c.keyframeWritten(nowUs: 3, bytes: 400_000)
        XCTAssertEqual(c.takeWindow(), .init(count: 3, bytesMax: 900_000))
        XCTAssertEqual(c.takeWindow(), .init())
    }
}

final class VideoFrameQueueKeyframeCountTests: XCTestCase {
    private func key(_ n: UInt8) -> EncodedVideoFrame { .init(flags: .keyframe, captureTimeUs: UInt64(n), data: [n]) }
    private func delta(_ n: UInt8) -> EncodedVideoFrame { .init(flags: [], captureTimeUs: UInt64(n), data: [n]) }
    private func config() -> EncodedVideoFrame { .init(flags: .codecConfig, captureTimeUs: 0, data: [9]) }

    func testCountsKeyframePushesAndReportsTheCountWithTheResync() {
        let q = VideoFrameQueue(keyframeNeeded: {})
        q.push(key(1)); q.push(delta(2)); q.push(key(3))
        XCTAssertEqual(q.keyframesPushed, 2)
        let r = q.resyncCountingKeyframes(config: { config() })
        XCTAssertEqual(r, .init(configQueued: true, keyframesPushed: 2))
        let none = q.resyncCountingKeyframes(config: { nil })
        XCTAssertEqual(none, .init(configQueued: false, keyframesPushed: 2))
    }
}
