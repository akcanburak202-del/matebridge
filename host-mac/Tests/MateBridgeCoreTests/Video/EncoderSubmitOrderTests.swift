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

    /// Completes the oldest outstanding frame (the encoder's output callback); returns its token.
    @discardableResult
    func completeOldest(failed: Bool = false) -> EncoderSubmitToken? {
        let token: EncoderSubmitToken? = lock.withLock { outstanding.isEmpty ? nil : outstanding.removeFirst() }
        if let token { order?.release(token, failed: failed) }
        return token
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
                           barrier: SubmitBarrier? = nil,
                           log: @escaping EncoderSubmitOrder<FakeBackend>.LogSink = { _, _, _ in })
        -> (EncoderSubmitOrder<FakeBackend>, FakeBackend) {
        let backend = FakeBackend()
        var hook: (@Sendable (FakeFrame) -> Void)?
        if let barrier { hook = { frame in barrier.hook(frame) } }
        let order = EncoderSubmitOrder<FakeBackend>(
            backend: backend, streamFps: fps, maxInFlight: 2, nowUs: { clock.now },
            scheduleFlush: { _, _ in }, log: log, beforeSubmit: hook)
        backend.order = order
        return (order, backend)
    }

    private func wait(_ s: DispatchSemaphore, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        if s.wait(timeout: .now() + 5) == .timedOut { XCTFail("timed out waiting for \(what)", file: file, line: line) }
    }

    /// Waits until the owner queue has run everything enqueued so far.
    private func drain<B>(_ order: EncoderSubmitOrder<B>, file: StaticString = #filePath, line: UInt = #line) {
        let s = DispatchSemaphore(value: 0)
        order.afterQueued { s.signal() }
        wait(s, "owner queue", file: file, line: line)
    }

    // MARK: - Single thread

    func testFirstFrameIsKeyframeThenDeltas() {
        let (order, backend) = makeOrder()
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 10, gateUs: 1_000) }
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 20, gateUs: 2_000) }
        drain(order)
        XCTAssertEqual(backend.events, [.encode(stamp: 10, key: true, token: 1), .encode(stamp: 20, key: false, token: 2)])
    }

    func testOfferNeverRunsTheBackendOnTheCallerThread() {
        let barrier = SubmitBarrier()
        let (order, backend) = makeOrder(barrier: barrier)
        // The barrier holds the owner queue; the offer must still return.
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 1, gateUs: 1_000) }
        wait(barrier.reached, "frame 1 at the barrier")
        XCTAssertEqual(backend.events, [])
        barrier.open()
        drain(order)
        XCTAssertEqual(backend.encodedStamps, [1])
    }

    func testStampIsMadeStrictlyIncreasingAtReservation() {
        let (order, backend) = makeOrder()
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 10, gateUs: 1_000) }
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 10, gateUs: 2_000) }
        drain(order)
        backend.completeOldest()
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 5, gateUs: 3_000) }
        drain(order)
        XCTAssertEqual(backend.encodedStamps, [10, 11, 12])
    }

    func testSlotsFullHoldsNewestAndReleaseSubmitsIt() {
        let clock = ManualClock()
        let (order, backend) = makeOrder(clock: clock)
        for i in 1...4 { order.offer(bypassGate: true) { _ in FakeFrame(stamp: i, gateUs: UInt64(i) * 1_000) } }
        drain(order)
        XCTAssertEqual(backend.encodedStamps, [1, 2])
        XCTAssertEqual(order.currentInFlight, 2)
        clock.advance(40_000)   // past the send-rate gate
        backend.completeOldest()
        drain(order)
        XCTAssertEqual(backend.encodedStamps, [1, 2, 4], "frame 3 was replaced by the newer pending frame 4")
        XCTAssertEqual(order.currentInFlight, 2)
    }

    func testFailedReleaseForcesKeyframe() {
        let (order, backend) = makeOrder()
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 1, gateUs: 1_000) }
        drain(order)
        backend.completeOldest(failed: true)
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 2, gateUs: 2_000) }
        drain(order)
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
        let again = DispatchSemaphore(value: 0)
        order.stop { again.signal() }
        wait(again, "repeated stop completion")
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 2, gateUs: 2_000) }
        drain(order)
        XCTAssertEqual(backend.events, [.encode(stamp: 1, key: true, token: 1), .invalidate])
        XCTAssertNil(order.lastOffered)
        XCTAssertEqual(order.currentStats.reservations, order.currentStats.releases)
    }

    func testDoubleReleaseIsIgnoredAndLogged() {
        let warnings = LockedList()
        let (order, backend) = makeOrder(log: { level, event, fields in
            if level == .warning { warnings.append("\(event) \(fields)") }
        })
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 1, gateUs: 1_000) }
        order.offer(bypassGate: true) { _ in FakeFrame(stamp: 2, gateUs: 2_000) }
        drain(order)
        let token = backend.completeOldest(failed: true)!   // e.g. VideoToolbox returned an error ...
        order.release(token, failed: false)                // ... and still called the handler
        order.release(EncoderSubmitToken(id: 99), failed: false)   // never reserved
        XCTAssertEqual(order.currentInFlight, 1, "only one release counted for token 1")
        let stats = order.currentStats
        XCTAssertEqual(stats.releases, 1)
        XCTAssertEqual(stats.duplicateReleases, 2)
        XCTAssertEqual(stats.minInFlight, 0)
        XCTAssertEqual(warnings.items, ["slot_double_release token=1", "slot_double_release token=99"])
    }

    // MARK: - Barrier: a second submitter between "reserved" and "backend.encode"

    /// Frame 1 reserves its slot and is held right before `backend.encode`; frame 2 then reserves and submits.
    /// The backend must still see the stamps in reservation order.
    func testBarrierKeepsReservationOrderAtBackend() {
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

    // MARK: - Stress

    /// 10 000 concurrent operations (capture offers, gate-bypassing re-submissions, flush-timer takes, keyframe
    /// requests, completions on a separate callback queue with refused submits and duplicate releases, `stop()`):
    /// the backend sees strictly increasing stamps and nothing after invalidate, every reservation is released
    /// exactly once, and `0 <= inFlight <= maxInFlight` throughout.
    func testStressKeepsOrderAndSlotAccounting() {
        let backend = StressBackend()
        let order = EncoderSubmitOrder<StressBackend>(
            backend: backend, streamFps: 240, maxInFlight: 2,
            nowUs: { DispatchTime.now().uptimeNanoseconds / 1_000 },
            scheduleFlush: { afterUs, fire in
                DispatchQueue.global().asyncAfter(deadline: .now() + .microseconds(Int(min(afterUs, 2_000))),
                                                  execute: fire)
            })
        backend.order = order
        let stamps = Counter()
        let badInFlight = Counter()
        let stopAt = 9_000

        DispatchQueue.concurrentPerform(iterations: 10_000) { i in
            switch i % 6 {
            case 0, 1:
                order.offer(bypassGate: false) { _ in
                    FakeFrame(stamp: stamps.next(), gateUs: DispatchTime.now().uptimeNanoseconds / 1_000)
                }
            case 2:
                order.offer(bypassGate: true) { last in
                    guard let last else { return nil }
                    var f = last
                    f.stamp = stamps.next()
                    f.gateUs = DispatchTime.now().uptimeNanoseconds / 1_000
                    return f
                }
            case 3:
                order.flushPending()
            case 4:
                order.requestKeyframe()
                let n = order.currentInFlight
                if n < 0 || n > order.maxInFlight { badInFlight.add() }
            default:
                if i / 6 == stopAt / 6 { order.stop() }
            }
        }
        let done = DispatchSemaphore(value: 0)
        order.stop { done.signal() }
        wait(done, "teardown")
        XCTAssertEqual(backend.callbacks.wait(timeout: .now() + 5), .success, "callback queue drained")

        let stats = order.currentStats
        let report = backend.report
        XCTAssertGreaterThan(stats.reservations, 100, "the run must exercise the encoder")
        XCTAssertEqual(report.outOfOrder, 0, "backend stamps went backwards")
        XCTAssertEqual(report.afterInvalidate, 0, "encode after invalidate")
        XCTAssertEqual(report.invalidates, 1)
        XCTAssertEqual(report.encoded, stats.reservations, "every reservation reached the backend")
        XCTAssertEqual(stats.releases, stats.reservations, "exactly one release per reservation")
        XCTAssertEqual(stats.duplicateReleases, report.duplicatesSent)
        XCTAssertGreaterThan(report.duplicatesSent, 0)
        XCTAssertGreaterThan(report.refused, 0)
        XCTAssertEqual(order.currentInFlight, 0)
        XCTAssertGreaterThanOrEqual(stats.minInFlight, 0)
        XCTAssertLessThanOrEqual(stats.maxInFlight, order.maxInFlight)
        XCTAssertEqual(badInFlight.value, 0)
    }
}

private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String] = []
    var items: [String] { lock.withLock { _items } }
    func append(_ s: String) { lock.withLock { _items.append(s) } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func next() -> Int { lock.withLock { n += 1; return n } }
    func add() { lock.withLock { n += 1 } }
}

/// Like VideoToolbox: completions arrive on another thread; some submits are refused synchronously; every 11th
/// completion is also released a second time (the duplicate must be ignored); `completeAndInvalidate` delivers the
/// remaining completions before it returns.
private final class StressBackend: CompressionBackend, @unchecked Sendable {
    typealias Frame = FakeFrame
    struct Report { var encoded = 0, outOfOrder = 0, afterInvalidate = 0, invalidates = 0, refused = 0,
                    duplicatesSent = 0 }
    weak var order: EncoderSubmitOrder<StressBackend>?
    let callbacks = DispatchGroup()
    private let lock = NSLock()
    private var _report = Report()
    private var lastStamp: Int?
    private var invalidated = false
    private var outstanding = Set<UInt64>()
    private var completions = 0

    var report: Report { lock.withLock { _report } }

    func encode(_ frame: FakeFrame, keyframe: Bool, token: EncoderSubmitToken) {
        let refuse = lock.withLock { () -> Bool in
            _report.encoded += 1
            if let l = lastStamp, frame.stamp <= l { _report.outOfOrder += 1 }
            lastStamp = frame.stamp
            if invalidated { _report.afterInvalidate += 1 }
            if _report.encoded % 37 == 0 { _report.refused += 1; return true }
            outstanding.insert(token.id)
            return false
        }
        if refuse { order?.release(token, failed: true); return }
        callbacks.enter()
        DispatchQueue.global().async { [self] in
            complete(token)
            callbacks.leave()
        }
    }

    /// Delivers the completion of `token` unless `completeAndInvalidate` already did.
    private func complete(_ token: EncoderSubmitToken) {
        let (claimed, duplicate) = lock.withLock { () -> (Bool, Bool) in
            guard outstanding.remove(token.id) != nil else { return (false, false) }
            completions += 1
            let dup = completions % 11 == 0
            if dup { _report.duplicatesSent += 1 }
            return (true, dup)
        }
        guard claimed else { return }
        order?.release(token, failed: false)
        if duplicate { order?.release(token, failed: false) }
    }

    func completeAndInvalidate() {
        let left = lock.withLock { outstanding }
        for id in left { complete(EncoderSubmitToken(id: id)) }
        lock.withLock { invalidated = true; _report.invalidates += 1 }
    }
}
