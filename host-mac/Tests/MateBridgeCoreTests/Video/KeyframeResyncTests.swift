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
}
