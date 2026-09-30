import XCTest
@testable import MateBridgeCore

final class KeyframeResyncTests: XCTestCase {
    private func delta(_ n: UInt8) -> EncodedVideoFrame { .init(flags: [], captureTimeUs: UInt64(n), data: [n]) }
    private func key(_ n: UInt8) -> EncodedVideoFrame { .init(flags: .keyframe, captureTimeUs: UInt64(n), data: [n]) }
    private func config(_ n: UInt8 = 9) -> EncodedVideoFrame { .init(flags: .codecConfig, captureTimeUs: 0, data: [n]) }

    private func drain(_ q: inout BoundedFrameQueue) -> [EncodedVideoFrame] {
        var out: [EncodedVideoFrame] = []
        while let f = q.pop() { out.append(f) }
        return out
    }

    func testReasonsThatResendConfig() {
        XCTAssertTrue(KeyframeReason.startup.resendsCodecConfig)
        XCTAssertTrue(KeyframeReason.decodeError.resendsCodecConfig)
        XCTAssertTrue(KeyframeReason(rawValue: 77).resendsCodecConfig, "unknown reasons behave like DECODE_ERROR")
        XCTAssertFalse(KeyframeReason.framesDropped.resendsCodecConfig)
    }

    func testResyncQueuesConfigBeforeTheForcedKeyframe() {
        var q = BoundedFrameQueue()
        q.push(delta(1)); q.push(delta(2))           // stale deltas queued when the request arrives
        q.resync(config: config())
        q.push(delta(3))                             // in-flight delta from before the request: refused
        q.push(key(4))                               // the forced keyframe
        let out = drain(&q)
        XCTAssertEqual(out.map(\.isCodecConfig), [true, false])
        XCTAssertEqual(out.last?.data, [4])
        XCTAssertTrue(out.last?.isKeyframe == true)
        XCTAssertFalse(q.takeKeyframeRequest())
    }

    func testResyncOnEmptyQueueStillPutsConfigFirst() {
        var q = BoundedFrameQueue()
        q.resync(config: config())
        q.push(key(1))
        XCTAssertEqual(drain(&q).map(\.isCodecConfig), [true, false])
    }

    func testBackToBackResyncsLeaveASingleConfig() {
        var q = BoundedFrameQueue()
        q.resync(config: config())
        q.resync(config: config(10))
        q.push(key(1))
        let out = drain(&q)
        XCTAssertEqual(out.filter(\.isCodecConfig).count, 1)
        XCTAssertEqual(out.first?.data, [10], "the newer config replaces the older one")
        XCTAssertEqual(out.count, 2)
    }

    func testIdenticalConfigFromEncoderIsNotQueuedTwice() {
        var q = BoundedFrameQueue()
        q.resync(config: config())
        XCTAssertEqual(q.push(config()), 0)
        q.push(key(1))
        XCTAssertEqual(drain(&q).map(\.isCodecConfig), [true, false])
        XCTAssertEqual(q.droppedCount, 0)
    }

    func testFramesDroppedPathAddsNoConfig() {
        // The pipeline skips resync for FRAMES_DROPPED, so the queue only ever sees the encoder's own output.
        var q = BoundedFrameQueue()
        q.push(delta(1))
        q.push(key(2))
        XCTAssertEqual(drain(&q).filter(\.isCodecConfig).count, 0)
    }

    func testConfigSurvivesAFullQueueAfterResync() {
        var q = BoundedFrameQueue()
        q.resync(config: config())
        q.push(key(1))                               // [config, key]: full
        q.push(delta(2))                             // overflow: the delta goes, config and keyframe stay
        q.push(delta(3))
        let out = drain(&q)
        XCTAssertTrue(out.first?.isCodecConfig == true)
        XCTAssertTrue(out.contains { $0.isKeyframe })
        XCTAssertLessThanOrEqual(out.count, 2)
    }

    func testAsyncQueueHandsConfigToWaitingConsumerImmediately() async {
        let q = VideoFrameQueue(keyframeNeeded: {})
        let waiting = Task { await q.next() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        q.resync(config: config())                   // no further push needed to wake the consumer
        let first = await waiting.value
        XCTAssertEqual(first?.isCodecConfig, true)
        q.push(delta(1))                             // refused (awaiting keyframe)
        q.push(key(2))
        let second = await q.next()
        XCTAssertEqual(second?.isKeyframe, true)
    }

    func testAsyncResyncDropsStaleFramesAndKeepsOrder() async {
        let q = VideoFrameQueue(keyframeNeeded: {})
        q.push(delta(1)); q.push(delta(2))
        q.resync(config: config())
        q.push(key(3))
        let a = await q.next(), b = await q.next()
        XCTAssertEqual(a?.isCodecConfig, true)
        XCTAssertEqual(b?.data, [3])
    }

    // MARK: Review round 1

    func testPendingConfigRequestIsNotDowngradedByFramesDropped() {
        XCTAssertEqual(KeyframeReason.merged(pending: .startup, incoming: .framesDropped), .startup)
        XCTAssertEqual(KeyframeReason.merged(pending: .decodeError, incoming: .framesDropped), .decodeError)
        XCTAssertEqual(KeyframeReason.merged(pending: KeyframeReason(rawValue: 77), incoming: .framesDropped),
                       KeyframeReason(rawValue: 77), "unknown reasons count as config-requiring")
    }

    func testMergeOtherwiseLatestWins() {
        XCTAssertEqual(KeyframeReason.merged(pending: .framesDropped, incoming: .startup), .startup)
        XCTAssertEqual(KeyframeReason.merged(pending: .framesDropped, incoming: .framesDropped), .framesDropped)
        XCTAssertEqual(KeyframeReason.merged(pending: .startup, incoming: .decodeError), .decodeError)
    }

    func testMailboxMergeKeepsStrongestKeyframeRequest() {
        let m = BoundedMailbox<KeyframeReason>()
        let merge: @Sendable (KeyframeReason, KeyframeReason) -> KeyframeReason = {
            KeyframeReason.merged(pending: $0, incoming: $1)
        }
        m.post(.startup, coalesceKey: 3, merge: merge)
        m.post(.framesDropped, coalesceKey: 3, merge: merge)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.take(), .startup)
        m.post(.framesDropped, coalesceKey: 3, merge: merge)
        m.post(.startup, coalesceKey: 3, merge: merge)
        XCTAssertEqual(m.take(), .startup)
    }

    func testMailboxWithoutMergeIsStillLatestWins() {
        let m = BoundedMailbox<Int>()
        m.post(1, coalesceKey: 1); m.post(2, coalesceKey: 1)
        XCTAssertEqual(m.take(), 2)
    }

    func testChangedConfigReplacesOlderConfigWhileOnlyConfigsWait() {
        var q = BoundedFrameQueue()
        q.resync(config: config(1))
        q.push(config(2))                            // encoder announced new parameter sets after the snapshot
        q.push(key(3))
        let out = drain(&q)
        XCTAssertEqual(out.map(\.data), [[2], [3]], "keyframe keeps its slot; only the newer config remains")
        XCTAssertEqual(q.droppedCount, 0)
    }

    /// The provider runs under the queue lock: a config pushed concurrently (encoder output) cannot land between
    /// the snapshot and the reset and be wiped by it.
    func testSnapshotAndResetAreAtomicWithRespectToPush() {
        let q = VideoFrameQueue(keyframeNeeded: {})
        let pushed = DispatchSemaphore(value: 0)
        let configA = config(1), configB = config(2)
        let resent = q.resync(config: {
            DispatchQueue.global().async { q.push(configB); pushed.signal() }  // encoder announces B
            Thread.sleep(forTimeInterval: 0.15)      // B's push is now waiting on the queue lock
            return configA                           // stale snapshot A
        })
        XCTAssertTrue(resent)
        XCTAssertEqual(pushed.wait(timeout: .now() + 2), .success)
        q.push(key(3))
        let exp = expectation(description: "drained")
        Task {
            let a = await q.next(), b = await q.next()
            XCTAssertEqual(a?.data, [2], "B survives the reset and replaces A")
            XCTAssertEqual(b?.data, [3])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testResyncWithoutConfigLeavesQueueUntouched() {
        let q = VideoFrameQueue(keyframeNeeded: {})
        q.push(delta(1))
        XCTAssertFalse(q.resync(config: { nil }))
        q.push(delta(2))                             // still accepted: no awaiting-keyframe state was entered
        let exp = expectation(description: "drained")
        Task {
            let a = await q.next(), b = await q.next()
            XCTAssertEqual([a?.data, b?.data], [[1], [2]])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}
