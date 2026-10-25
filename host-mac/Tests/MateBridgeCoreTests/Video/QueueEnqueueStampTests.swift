import XCTest
@testable import MateBridgeCore

/// T-379: every queue insertion carries an enqueue stamp, so the age of the head frame (part of the stall signal) is
/// known for resync and new-consumer config frames too.
final class QueueEnqueueStampTests: XCTestCase {
    private func config() -> EncodedVideoFrame { .init(flags: .codecConfig, captureTimeUs: 0, data: [9]) }
    private func key(_ n: UInt8) -> EncodedVideoFrame { .init(flags: .keyframe, captureTimeUs: UInt64(n), data: [n]) }

    func testPushStampsAnUnstampedFrameAndKeepsAnExistingStamp() {
        let q = VideoFrameQueue(clockUs: { 5_000 }, keyframeNeeded: {})
        q.push(key(1))
        XCTAssertEqual(q.headEnqueuedUs, 5_000)
        _ = q.tryPop()
        var stamped = key(2)
        stamped.trace.enqueuedUs = 1_234
        q.push(stamped)
        XCTAssertEqual(q.headEnqueuedUs, 1_234, "the pipeline's own stamp is kept")
    }

    func testResyncConfigIsStamped() {
        let q = VideoFrameQueue(clockUs: { 7_000 }, keyframeNeeded: {})
        let r = q.resyncCountingKeyframes(config: { self.config() })
        XCTAssertTrue(r.configQueued)
        XCTAssertEqual(q.headEnqueuedUs, 7_000, "a config stuck at the head must show its age")
        XCTAssertEqual(q.tryPop()?.data, [9])
    }

    func testNewConsumerConfigIsStamped() {
        let q = VideoFrameQueue(clockUs: { 8_000 }, keyframeNeeded: {})
        q.startNewConsumer(configProvider: { self.config() })
        XCTAssertEqual(q.headEnqueuedUs, 8_000)
    }

    func testEmptyQueueHasNoHead() {
        let q = VideoFrameQueue(clockUs: { 1 }, keyframeNeeded: {})
        XCTAssertNil(q.headEnqueuedUs)
    }
}
