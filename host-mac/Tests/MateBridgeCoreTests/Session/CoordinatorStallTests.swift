import Foundation
import Testing
@testable import MateBridgeCore

private let sec: UInt64 = 1_000_000

/// A transport whose writes never complete: `canSend` stays false, so the sender never gets to write.
private final class StuckTransport: VideoTransport, @unchecked Sendable {
    var canSend: Bool { false }
    func setReadyHandler(_ handler: (@Sendable () -> Void)?) {}
    func send(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void) -> Bool { false }
}

/// Holds a continuation that is only resumed by the test, to model an await that never answers.
private final class Blocker: @unchecked Sendable {
    private let lock = NSLock()
    private var conts: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.withLock { conts.append(c) } }
    }
    func releaseAll() { lock.withLock { conts.forEach { $0.resume() }; conts = [] } }
}

@Suite struct BoundedWaitTests {
    @Test func completesWhenOperationFinishes() async {
        let outcome = await BoundedWait.run(timeout: 5) {}
        #expect(outcome == .completed)
    }

    @Test func timesOutWhenOperationNeverReturns() async {
        let never = Blocker()
        let start = ContinuousClock.now
        let outcome = await BoundedWait.run(timeout: 0.2) { await never.wait() }
        let elapsed = ContinuousClock.now - start
        #expect(outcome == .timedOut)
        #expect(elapsed < .seconds(2))
        never.releaseAll()
    }

    @Test func lateCompletionAfterTimeoutIsHarmless() async {
        let never = Blocker()
        let outcome = await BoundedWait.run(timeout: 0.1) { await never.wait() }
        #expect(outcome == .timedOut)
        never.releaseAll()  // the leaked operation finishes later; nothing may crash or resume twice
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    @Test func zeroTimeoutStillReturns() async {
        let never = Blocker()
        let outcome = await BoundedWait.run(timeout: 0) { await never.wait() }
        #expect(outcome == .timedOut)
        never.releaseAll()
    }

    /// The T-325 scenario: the connection never accepts a write. Closing the source first and bounding the sender stop
    /// returns in time either way.
    @Test func senderStopOnStuckTransportReturnsInTime() async {
        let q = VideoFrameQueue(keyframeNeeded: {})
        let sender = VideoSender(transport: StuckTransport(), frames: q, requestKeyframe: {})
        sender.start()
        let start = ContinuousClock.now
        let outcome = await BoundedWait.run(timeout: 2) { await sender.stop() }
        #expect(outcome == .completed)
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}

@Suite struct CoordinatorWatchdogTests {
    @Test func quietEventNeverTriggers() {
        var w = CoordinatorWatchdog()
        w.begin(kind: "tick", nowUs: 0)
        #expect(w.poll(nowUs: 2 * sec).isEmpty)
        #expect(w.end(nowUs: 2 * sec) == nil)
        #expect(w.poll(nowUs: 100 * sec).isEmpty)  // idle: no event in progress
    }

    @Test func escalatesInOrderOncePerEvent() {
        var w = CoordinatorWatchdog()
        w.begin(kind: "sessionEnded", nowUs: 10 * sec)
        #expect(w.poll(nowUs: 12 * sec).isEmpty)
        #expect(w.poll(nowUs: 13 * sec) == [.warn(kind: "sessionEnded", ms: 3_000)])
        #expect(w.poll(nowUs: 14 * sec).isEmpty)
        #expect(w.poll(nowUs: 20 * sec) == [.endSessions(kind: "sessionEnded", ms: 10_000)])
        #expect(w.poll(nowUs: 30 * sec).isEmpty)
        #expect(w.poll(nowUs: 40 * sec) == [.restart(kind: "sessionEnded", ms: 30_000)])
        #expect(w.poll(nowUs: 60 * sec).isEmpty)
        #expect(w.end(nowUs: 61 * sec)?.ms == 51_000)
    }

    @Test func longGapBetweenPollsReturnsAllDueSteps() {
        var w = CoordinatorWatchdog()
        w.begin(kind: "videoAttached", nowUs: 0)
        let actions = w.poll(nowUs: 31 * sec)
        #expect(actions.count == 3)
        #expect(actions.first == .warn(kind: "videoAttached", ms: 31_000))
    }

    @Test func nextEventStartsClean() {
        var w = CoordinatorWatchdog()
        w.begin(kind: "a", nowUs: 0)
        _ = w.poll(nowUs: 11 * sec)
        w.end(nowUs: 11 * sec)
        w.begin(kind: "b", nowUs: 12 * sec)
        #expect(w.poll(nowUs: 13 * sec).isEmpty)
        #expect(w.poll(nowUs: 15 * sec) == [.warn(kind: "b", ms: 3_000)])
    }

    @Test func pausedTimeDoesNotCount() {
        var w = CoordinatorWatchdog()
        w.begin(kind: "pipelineFailed", nowUs: 0)
        w.pause(nowUs: 1 * sec)
        #expect(w.poll(nowUs: 50 * sec).isEmpty)  // an intentional back-off sleep
        w.resume(nowUs: 50 * sec)
        #expect(w.poll(nowUs: 51 * sec).isEmpty)  // 1 s before the pause + 1 s after
        #expect(w.poll(nowUs: 52 * sec) == [.warn(kind: "pipelineFailed", ms: 3_000)])
    }

    @Test func endWhilePausedAndDoublePauseAreSafe() {
        var w = CoordinatorWatchdog()
        w.begin(kind: "x", nowUs: 0)
        w.pause(nowUs: 1 * sec)
        w.pause(nowUs: 5 * sec)
        w.resume(nowUs: 6 * sec)
        w.resume(nowUs: 7 * sec)
        #expect(w.end(nowUs: 8 * sec) == nil)
    }
}
