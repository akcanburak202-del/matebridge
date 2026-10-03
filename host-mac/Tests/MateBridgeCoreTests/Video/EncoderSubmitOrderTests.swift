import Foundation
import XCTest
@testable import MateBridgeCore

/// Fake frame: an integer stamp and a capture time.
private struct FakeFrame: EncoderSubmitFrame {
    var stamp: Int
    var gateUs: UInt64
    static func stamp(after previous: Int) -> Int { previous + 1 }
}

/// What the fake backend saw, in call order.
private enum Event: Equatable {
    case encode(stamp: Int, key: Bool, token: UInt64)
    case invalidate
}

/// Records every call. `completeAndInvalidate` completes the outstanding frames first (as VideoToolbox's
/// `CompleteFrames` delivers their callbacks), then records the invalidate.
private final class FakeBackend: CompressionBackend, @unchecked Sendable {
    typealias Frame = FakeFrame
    private let lock = NSLock()
    private var _events: [Event] = []
    private var outstanding: [EncoderSubmitToken] = []
    weak var order: EncoderSubmitOrder<FakeBackend>?

    var events: [Event] { lock.withLock { _events } }
    var encodedStamps: [Int] {
        events.compactMap { if case .encode(let s, _, _) = $0 { return s } else { return nil } }
    }

    func encode(_ frame: FakeFrame, keyframe: Bool, token: EncoderSubmitToken) {
        lock.withLock {
            _events.append(.encode(stamp: frame.stamp, key: keyframe, token: token.id))
            outstanding.append(token)
        }
    }

    /// Completes the oldest outstanding frame (the encoder's output callback).
    func completeOldest(failed: Bool = false) {
        let token: EncoderSubmitToken? = lock.withLock { outstanding.isEmpty ? nil : outstanding.removeFirst() }
        if let token { order?.release(token, failed: failed) }
    }

    func completeAndInvalidate() {
        while lock.withLock({ !outstanding.isEmpty }) { completeOldest() }
        lock.withLock { _events.append(.invalidate) }
    }
}

/// Clock the tests advance by hand.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: UInt64 = 1_000_000
    var now: UInt64 { lock.withLock { t } }
    func advance(_ us: UInt64) { lock.withLock { t += us } }
}

/// Blocks the first frame that reaches `beforeSubmit` (the step between "slot reserved" and "backend.encode")
/// until `open()`; every later frame passes.
private final class SubmitBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    let reached = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    func hook(_ frame: FakeFrame) {
        let block = lock.withLock { () -> Bool in defer { armed = false }; return armed }
        guard block else { return }
        reached.signal()
        gate.wait()
    }
    func open() { gate.signal() }
}

final class EncoderSubmitOrderTests: XCTestCase {
    private func makeOrder(clock: ManualClock = ManualClock(), fps: Int = 60,
                           barrier: SubmitBarrier? = nil) -> (EncoderSubmitOrder<FakeBackend>, FakeBackend) {
        let backend = FakeBackend()
        var hook: (@Sendable (FakeFrame) -> Void)?
        if let barrier { hook = { frame in barrier.hook(frame) } }
        let order = EncoderSubmitOrder<FakeBackend>(
            backend: backend, streamFps: fps, maxInFlight: 2, nowUs: { clock.now },
            scheduleFlush: { _, _ in }, beforeSubmit: hook)
        backend.order = order
        return (order, backend)
    }

    private func wait(_ s: DispatchSemaphore, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        if s.wait(timeout: .now() + 5) == .timedOut { XCTFail("timed out waiting for \(what)", file: file, line: line) }
    }

    // MARK: - Today's ordering (single thread)

    func testFirstFrameIsKeyframeThenDeltas() {
        let clock = ManualClock()
        let (order, backend) = makeOrder(clock: clock)
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 10, gateUs: 1_000) }
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 20, gateUs: 2_000) }
        XCTAssertEqual(backend.events, [.encode(stamp: 10, key: true, token: 1), .encode(stamp: 20, key: false, token: 2)])
    }

    func testStampIsMadeStrictlyIncreasingAtReservation() {
        let (order, backend) = makeOrder()
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 10, gateUs: 1_000) }
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 10, gateUs: 2_000) }
        backend.completeOldest()
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 5, gateUs: 3_000) }
        XCTAssertEqual(backend.encodedStamps, [10, 11, 12])
    }

    func testSlotsFullHoldsNewestAndReleaseSubmitsIt() {
        let clock = ManualClock()
        let (order, backend) = makeOrder(clock: clock)
        for i in 1...4 { order.offer(bypassGate: true) { _ in FakeFrame(stamp: i, gateUs: UInt64(i) * 1_000) } }
        XCTAssertEqual(backend.encodedStamps, [1, 2])
        XCTAssertEqual(order.currentInFlight, 2)
        clock.advance(40_000)   // past the send-rate gate
        backend.completeOldest()
        XCTAssertEqual(backend.encodedStamps, [1, 2, 4], "frame 3 was replaced by the newer pending frame 4")
        XCTAssertEqual(order.currentInFlight, 2)
    }

    func testFailedReleaseForcesKeyframe() {
        let (order, backend) = makeOrder()
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 1, gateUs: 1_000) }
        backend.completeOldest(failed: true)
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 2, gateUs: 2_000) }
        XCTAssertEqual(backend.events.last, .encode(stamp: 2, key: true, token: 2))
    }

    func testBuildSeesLastOfferedFrame() {
        let (order, _) = makeOrder()
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 7, gateUs: 1_000) }
        var seen: Int?
        order.offer(bypassGate: true) { last in seen = last?.stamp; return nil }
        XCTAssertEqual(seen, 7)
        XCTAssertEqual(order.lastOffered?.stamp, 7)
    }

    func testStopClosesBackendOnceAndRejectsLaterFrames() {
        let (order, backend) = makeOrder()
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 1, gateUs: 1_000) }
        let done = DispatchSemaphore(value: 0)
        order.stop { done.signal() }
        wait(done, "teardown")
        order.stop()
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 2, gateUs: 2_000) }
        XCTAssertEqual(backend.events, [.encode(stamp: 1, key: true, token: 1), .invalidate])
        XCTAssertNil(order.lastOffered)
        XCTAssertEqual(order.currentStats.reservations, order.currentStats.releases)
    }

    // MARK: - Barrier: a second submitter between "reserved" and "backend.encode"

    /// Frame 1 reserves its slot and is held right before `backend.encode`; frame 2 then reserves and submits.
    /// The backend must still see the stamps in reservation order.
    func testBarrierKeepsReservationOrderAtBackend() {
        XCTExpectFailure("T-162 step 1: today's unlock-then-send order inverts the stamps")
        let barrier = SubmitBarrier()
        let (order, backend) = makeOrder(barrier: barrier)
        let first = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            order.offer(bypassGate: true) { _ in FakeFrame(stamp: 1, gateUs: 1_000) }
            first.signal()
        }
        wait(barrier.reached, "frame 1 at the barrier")
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 2, gateUs: 2_000) }
        barrier.open()
        wait(first, "frame 1 offer")
        let done = DispatchSemaphore(value: 0)
        order.stop { done.signal() }
        wait(done, "teardown")
        XCTAssertEqual(backend.encodedStamps, [1, 2])
    }

    /// Frame 1 reserves its slot and is held right before `backend.encode` while `stop()` runs: nothing may reach
    /// the backend after it was invalidated.
    func testBarrierStopNeverEncodesAfterInvalidate() {
        XCTExpectFailure("T-162 step 1: today's stop() invalidates while a reserved frame is still to be sent")
        let barrier = SubmitBarrier()
        let (order, backend) = makeOrder(barrier: barrier)
        let first = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            order.offer(bypassGate: true) { _ in FakeFrame(stamp: 1, gateUs: 1_000) }
            first.signal()
        }
        wait(barrier.reached, "frame 1 at the barrier")
        let done = DispatchSemaphore(value: 0)
        order.stop { done.signal() }
        barrier.open()
        wait(first, "frame 1 offer")
        wait(done, "teardown")
        let events = backend.events
        XCTAssertEqual(events.last, .invalidate, "events: \(events)")
        XCTAssertEqual(events.filter { $0 == .invalidate }.count, 1)
    }
}
