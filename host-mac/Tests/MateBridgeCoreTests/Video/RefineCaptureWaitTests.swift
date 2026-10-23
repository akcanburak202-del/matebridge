import Foundation
import XCTest
@testable import MateBridgeCore

/// T-374: a real capture that arrives while or right after a still-screen refinement train (T-253) must not wait for
/// anything the train did. Two suspected causes: (1) the synthetic refine frames advance the send-rate grid and run
/// it up to one tolerance ahead, so the first real frame waits for the last refine frame's slot; (2) refine frames
/// in the encoder / output queue fill the T-370 downstream budget and hold the real frame.
final class RefineCaptureWaitTests: XCTestCase {
    private let period: UInt64 = 16_667

    // MARK: path 1 - send-rate grid

    /// A train at stream rate: each refine frame is offered 4.2 ms after the previous one was submitted (encode
    /// time), exactly as `HEVCEncoder.resubmitLast` chains them, and waits for its slot.
    private func runTrain(_ pacer: inout FramePacer<UInt64>, frames: Int, startUs: UInt64) -> UInt64 {
        var t = startUs
        var id: UInt64 = 1000
        var lastSubmit = startUs
        for _ in 0..<frames {
            id += 1
            var submitted = false
            if case .submit = pacer.offer(id, ptsUs: t, nowUs: t, slotFree: true, synthetic: true) { submitted = true }
            while !submitted {
                t += 100
                if case .submit = pacer.takePending(nowUs: t, slotFree: true) { submitted = true }
            }
            lastSubmit = t
            t += 4_200
        }
        return lastSubmit
    }

    func testRealCaptureAfterRefineTrainDoesNotWaitForTheGrid() {
        var pacer = FramePacer<UInt64>(streamFps: 60)
        let lastRefine = runTrain(&pacer, frames: 13, startUs: 1_000_000)
        // Motion resumes 5 ms after the last refine frame (the train is cancelled; no more synthetic frames).
        let arrival = lastRefine + 5_000
        var waited: UInt64 = 0
        switch pacer.offer(1, ptsUs: arrival, nowUs: arrival, slotFree: true) {
        case .submit: waited = 0
        case .hold:
            var t = arrival
            var done = false
            while !done && t < arrival + 100_000 {
                t += 100
                if case .submit = pacer.takePending(nowUs: t, slotFree: true) { done = true }
            }
            waited = t - arrival
        case .drop: XCTFail("dropped")
        }
        XCTAssertLessThanOrEqual(waited, 1_000, "real capture waited \(waited) us behind the refine train")
    }

    func testFollowingRealFramesKeepTheirCadenceAndRateStaysCapped() {
        var pacer = FramePacer<UInt64>(streamFps: 60)
        let lastRefine = runTrain(&pacer, frames: 13, startUs: 1_000_000)
        var submits: [UInt64] = []
        var t = lastRefine + 5_000
        var id: UInt64 = 1
        let end = t + 600_000
        var nextArrival = t
        while t < end {
            if t >= nextArrival {
                id += 1
                if case .submit = pacer.offer(id, ptsUs: t, nowUs: t, slotFree: true) { submits.append(t) }
                nextArrival += period
            }
            if case .submit = pacer.takePending(nowUs: t, slotFree: true) { submits.append(t) }
            t += 500
        }
        XCTAssertGreaterThanOrEqual(submits.count, 34, "stream keeps flowing")
        let span = Double(submits.last! - submits.first!) / 1e6
        XCTAssertLessThanOrEqual(Double(submits.count - 1) / span, 61.5, "rate stays at or below the stream fps")
    }

    func testRefineFramesStillRunAtStreamRate() {
        var pacer = FramePacer<UInt64>(streamFps: 60)
        let start: UInt64 = 1_000_000
        let last = runTrain(&pacer, frames: 13, startUs: start)
        let rate = 12.0 / (Double(last - start) / 1e6)
        XCTAssertLessThanOrEqual(rate, 64, "train does not burst")
        XCTAssertGreaterThanOrEqual(rate, 55, "train is not slowed")
    }

    // MARK: path 2 - downstream budget

    private struct F: EncoderSubmitFrame {
        var stamp: Int
        var gateUs: UInt64
        var refine = false
        static func stamp(after previous: Int) -> Int { previous + 1 }
        var skipsOnPendingKeyframe: Bool { refine }
        var isSynthetic: Bool { refine }
    }

    private final class Backend: CompressionBackend, @unchecked Sendable {
        typealias Frame = F
        let lock = NSLock()
        var _tokens: [EncoderSubmitToken] = []
        var _encoded: [Int] = []
        var encoded: [Int] { lock.withLock { _encoded } }
        var tokens: [EncoderSubmitToken] { lock.withLock { _tokens } }
        func encode(_ frame: F, keyframe: Bool, token: EncoderSubmitToken) {
            lock.withLock { _encoded.append(frame.stamp); _tokens.append(token) }
        }
        func completeAndInvalidate() {}
    }

    private final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var t: UInt64 = 1_000_000
        var now: UInt64 { lock.withLock { t } }
        func advance(_ us: UInt64) { lock.withLock { t += us } }
    }

    private final class Queued: @unchecked Sendable {
        let lock = NSLock()
        var n = 0
        var count: Int { lock.withLock { n } }
        func set(_ v: Int) { lock.withLock { n = v } }
    }

    private func drain(_ o: EncoderSubmitOrder<Backend>) {
        let s = DispatchSemaphore(value: 0)
        o.afterQueued { s.signal() }
        XCTAssertEqual(s.wait(timeout: .now() + 5), .success)
    }

    /// Slow transport: the sender has not popped the previous refine frame. A refine frame must not be admitted on
    /// top of it, because inFlight + queued would reach the capacity and hold the real capture that follows.
    func testRefineFrameDoesNotUseTheBudgetARealCaptureNeeds() {
        let backend = Backend(), clock = Clock(), queued = Queued()
        let order = EncoderSubmitOrder<Backend>(
            backend: backend, streamFps: 60, maxInFlight: 2,
            nowUs: { clock.now },
            scheduleFlush: { _, _ in },
            downstreamLoad: { m, _ in queued.count + m },
            downstreamCapacity: BoundedFrameQueue.defaultCapacity)
        // A first real frame consumes the start keyframe request (a refine frame never does).
        order.offer(bypassGate: false) { _ in F(stamp: 0, gateUs: clock.now) }
        drain(order)
        order.release(backend.tokens[0], failed: false)
        clock.advance(100_000)
        // Refine frame A is encoded; its output sits in the queue (transport slow).
        order.offerChecked(bypassGate: false) { _, _ in F(stamp: 1, gateUs: clock.now, refine: true) }
        drain(order)
        queued.set(1)
        order.release(backend.tokens[1], failed: false)
        clock.advance(20_000)
        // Refine frame B is offered while A is still queued.
        order.offerChecked(bypassGate: false) { _, _ in F(stamp: 2, gateUs: clock.now, refine: true) }
        drain(order)
        clock.advance(5_000)
        // Motion resumes: the real capture arrives.
        order.offer(bypassGate: false) { _ in F(stamp: 3, gateUs: clock.now) }
        drain(order)
        XCTAssertTrue(backend.encoded.contains(3), "real capture reached the encoder at once, encoded: \(backend.encoded)")
    }
}
