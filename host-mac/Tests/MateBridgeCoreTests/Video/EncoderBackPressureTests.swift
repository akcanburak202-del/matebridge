import Foundation
import XCTest
@testable import MateBridgeCore

/// T-370: the encoder input must not take new captures while the encoded frames cannot leave (output queue full).
/// Dropping a capture before encoding (pacer `overwritten`) keeps the reference chain; dropping an encoded delta in the
/// queue breaks it and forces an IDR (docs/research/2026-10-23-forced-idr-chain.md, ring 3).
private struct BPFrame: EncoderSubmitFrame {
    var stamp: Int
    var gateUs: UInt64
    static func stamp(after previous: Int) -> Int { previous + 1 }
}

private final class BPClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: UInt64 = 1_000_000
    var now: UInt64 { lock.withLock { t } }
    func advance(_ us: UInt64) { lock.withLock { t += us } }
}

/// Encodes instantly: each submitted frame becomes an `EncodedVideoFrame` pushed to the real output queue when the
/// test calls `complete()`.
private final class BPBackend: CompressionBackend, @unchecked Sendable {
    typealias Frame = BPFrame
    private let lock = NSLock()
    private var outstanding: [(EncoderSubmitToken, Bool, UInt64)] = []
    private var _encoded: [Int] = []
    weak var order: EncoderSubmitOrder<BPBackend>?
    var queue: VideoFrameQueue!
    /// Packed full colour: every submit owes an auxiliary frame, finished by `completeAux`.
    var auxQueue: VideoFrameQueue?
    private var auxPending: [(EncoderSubmitToken, Bool, UInt64)] = []

    var encoded: [Int] { lock.withLock { _encoded } }
    func encode(_ frame: BPFrame, keyframe: Bool, token: EncoderSubmitToken) {
        lock.withLock {
            _encoded.append(frame.stamp); outstanding.append((token, keyframe, frame.gateUs))
            if auxQueue != nil { auxPending.append((token, keyframe, frame.gateUs)) }
        }
    }

    /// The oldest `count` auxiliary encodes finish: pushed to the auxiliary queue first, then resolved (the order the
    /// real encoder uses).
    func completeAux(_ count: Int = .max) {
        let batch = lock.withLock { () -> [(EncoderSubmitToken, Bool, UInt64)] in
            let n = min(count, auxPending.count)
            defer { auxPending.removeFirst(n) }
            return Array(auxPending.prefix(n))
        }
        for (token, key, us) in batch {
            var f = EncodedVideoFrame(flags: key ? [.keyframe] : [], captureTimeUs: us, data: [4, 5])
            f.view = 1
            auxQueue?.push(f)
            order?.auxResolved(token)
        }
    }
    func completeAndInvalidate() {}

    /// Output callback for everything submitted so far.
    func complete() {
        let batch = lock.withLock { () -> [(EncoderSubmitToken, Bool, UInt64)] in defer { outstanding = [] }; return outstanding }
        for (token, key, us) in batch {
            queue.push(EncodedVideoFrame(flags: key ? [.keyframe] : [], captureTimeUs: us, data: [1, 2, 3]))
            order?.release(token, failed: false)
        }
    }
}

final class EncoderBackPressureTests: XCTestCase {
    private let tickUs: UInt64 = 16_667

    private final class Rig: @unchecked Sendable {
        let clock = BPClock()
        let backend = BPBackend()
        var order: EncoderSubmitOrder<BPBackend>!
        let counterLock = NSLock()
        var _needed = 0
        var needed: Int { counterLock.withLock { _needed } }
        var overwritten = 0
        var delivered = 0
        var flushes: [@Sendable () -> Void] = []
        let flushLock = NSLock()
        var stamp = 0
        var queue: VideoFrameQueue!
    }

    private func makeRig(backPressure: Bool) -> Rig {
        let rig = Rig()
        rig.queue = VideoFrameQueue(keyframeNeeded: { [unowned rig] in
            rig.counterLock.withLock { rig._needed += 1 }
        })
        rig.backend.queue = rig.queue
        let queue = rig.queue!
        rig.order = EncoderSubmitOrder<BPBackend>(
            backend: rig.backend, streamFps: 60, maxInFlight: 2, initialBitrateKbps: 60_000,
            nowUs: { [clock = rig.clock] in clock.now },
            scheduleFlush: { [unowned rig] _, fire in rig.flushLock.withLock { rig.flushes.append(fire) } },
            pacerCounts: { [unowned rig] o, _, _ in rig.overwritten += o },
            downstreamLoad: { m, _ in queue.queuedCount + m },
            downstreamCapacity: backPressure ? BoundedFrameQueue.defaultCapacity : .max)
        rig.backend.order = rig.order
        return rig
    }

    private func drain(_ rig: Rig) {
        let s = DispatchSemaphore(value: 0)
        rig.order.afterQueued { s.signal() }
        XCTAssertEqual(s.wait(timeout: .now() + 5), .success)
    }

    /// One 60 fps source interval in 2 ms steps: the capture arrives at the start; encode completions, flush timers
    /// and (when `transportOpen`) the sender popping the queue run at every step.
    private func tick(_ rig: Rig, transportOpen: Bool) {
        rig.stamp += 1
        rig.order.offer(bypassGate: false) { _ in BPFrame(stamp: rig.stamp, gateUs: rig.clock.now) }
        var elapsed: UInt64 = 0
        while elapsed < tickUs {
            drain(rig)
            rig.backend.complete()
            if transportOpen { while rig.queue.tryPop() != nil { rig.delivered += 1 } }
            let step = min(2_000, tickUs - elapsed)
            rig.clock.advance(step); elapsed += step
            let fires = rig.flushLock.withLock { () -> [@Sendable () -> Void] in defer { rig.flushes = [] }; return rig.flushes }
            fires.forEach { $0() }
        }
    }

    func testStalledTransportDoesNotOverflowQueueOrForceKeyframe() {
        let rig = makeRig(backPressure: true)
        for _ in 0..<5 { tick(rig, transportOpen: true) }
        XCTAssertEqual(rig.overwritten, 0, "healthy flow loses nothing")
        // 200 ms of stalled transport at 60 fps (12 captures).
        for _ in 0..<12 { tick(rig, transportOpen: false) }
        XCTAssertEqual(rig.needed, 0, "no encoded frame was dropped, so no keyframe is needed")
        XCTAssertEqual(rig.queue.discardedCount, 0)
        XCTAssertGreaterThan(rig.overwritten, 0, "captures are dropped before encoding instead")
        // The transport opens: the stream continues within two frames.
        let before = rig.backend.encoded.count
        for _ in 0..<2 { tick(rig, transportOpen: true) }
        XCTAssertGreaterThanOrEqual(rig.backend.encoded.count - before, 1)
        XCTAssertEqual(rig.needed, 0)
        for _ in 0..<3 { tick(rig, transportOpen: true) }
        XCTAssertGreaterThanOrEqual(rig.backend.encoded.count - before, 4, "about one encoded frame per tick again")
    }

    // MARK: - Packed full colour (auxiliary stream)

    private final class PackedRig: @unchecked Sendable {
        let clock = BPClock()
        let backend = BPBackend()
        let main = VideoFrameQueue(keyframeNeeded: {})
        let aux = VideoFrameQueue(keyframeNeeded: {})
        var order: EncoderSubmitOrder<BPBackend>!
        let lock = NSLock()
        var flushes: [@Sendable () -> Void] = []
        /// Runs inside the budget snapshot, between the in-flight read and the queue read.
        var duringSnapshot: (@Sendable () -> Void)?
        var stamp = 0
        let gate = DispatchSemaphore(value: 0)
        var blockFirstSubmit = false
        private var blocked = false

        func hook() {
            let block = lock.withLock { () -> Bool in
                guard blockFirstSubmit, !blocked else { return false }
                blocked = true
                return true
            }
            if block { gate.wait() }
        }
        func fireFlushes() {
            let fires = lock.withLock { () -> [@Sendable () -> Void] in defer { flushes = [] }; return flushes }
            fires.forEach { $0() }
        }
        func offer() {
            stamp += 1
            clock.advance(16_667)
            order.offer(bypassGate: false) { [stamp, clock] _ in BPFrame(stamp: stamp, gateUs: clock.now) }
        }
        func settle() {
            let s = DispatchSemaphore(value: 0)
            order.afterQueued { s.signal() }
            XCTAssertEqual(s.wait(timeout: .now() + 5), .success)
        }
        func landAuxiliaryFrame() { aux.push(EncodedVideoFrame(flags: [], captureTimeUs: 1, data: [9])) }
    }

    private func makePacked(blockFirstSubmit: Bool = false) -> PackedRig {
        let rig = PackedRig()
        rig.blockFirstSubmit = blockFirstSubmit
        rig.backend.queue = rig.main
        rig.backend.auxQueue = rig.aux
        let main = rig.main, aux = rig.aux
        rig.order = EncoderSubmitOrder<BPBackend>(
            backend: rig.backend, streamFps: 60, maxInFlight: 2, initialBitrateKbps: 60_000,
            nowUs: { [clock = rig.clock] in clock.now },
            scheduleFlush: { [unowned rig] _, fire in rig.lock.withLock { rig.flushes.append(fire) } },
            downstreamLoad: { [unowned rig] mainInFlight, auxInFlight in
                rig.duringSnapshot?()
                return DownstreamBudget.projected(mainInFlight: mainInFlight, mainQueued: main.queuedCount,
                                                  auxInFlight: auxInFlight, auxQueued: aux.queuedCount)
            },
            downstreamCapacity: BoundedFrameQueue.defaultCapacity,
            beforeSubmit: { [unowned rig] _ in rig.hook() })
        rig.backend.order = rig.order
        rig.order.trackAuxiliary()
        return rig
    }

    /// A reserved frame owes an auxiliary frame from the moment it holds its slot, not from when the owner queue runs
    /// its submit: with the owner queue stalled, the next capture must still see that frame's auxiliary capacity.
    func testReservedFrameReservesAuxiliaryCapacityBeforeItsSubmitRuns() {
        let rig = makePacked(blockFirstSubmit: true)
        rig.offer()                       // the keyframe: reserved, its submit blocks on the owner queue
        rig.landAuxiliaryFrame()          // the stalled transport left one auxiliary frame in the queue
        rig.offer()                       // A: owed 1 + queued 1 = capacity, so it must wait even though no submit ran yet
        rig.offer()                       // B
        XCTAssertEqual(rig.order.currentStats.reservations, 1, "A and B wait: the keyframe owes one and one is queued")
        XCTAssertEqual(rig.order.auxOwedCount, 1)
        rig.gate.signal()
        rig.settle()
    }

    /// The budget reads the owed auxiliary count first and the queue second, so a frame that lands between the two
    /// reads is counted twice (safe) and never zero times.
    func testSnapshotCannotUnderCountAnAuxiliaryFrameThatLandsMidRead() {
        let rig = makePacked()
        rig.offer()                       // keyframe, exempt
        rig.settle()
        rig.backend.complete()            // main output drained; the auxiliary frame is still owed
        rig.duringSnapshot = { [unowned rig] in rig.landAuxiliaryFrame() }   // the owed one lands mid-snapshot
        rig.offer()
        XCTAssertEqual(rig.order.currentStats.reservations, 1, "owed 1 (read first) + 1 that landed mid-snapshot = capacity: held")
        rig.duringSnapshot = nil
    }

    /// Reserved capacity is released only by completion, loss or an explicit reset; time alone never frees it.
    func testOwedAuxiliaryCapacityDoesNotExpireWithTime() {
        let rig = makePacked()
        rig.offer(); rig.settle(); rig.backend.complete()
        rig.landAuxiliaryFrame()
        rig.offer()                       // A: reserved, auxiliary owed (queued 1 + owed 2 is over, but A is the second owed)
        rig.offer()
        rig.clock.advance(10_000_000)
        rig.fireFlushes()
        rig.offer()
        let held = rig.order.currentStats.reservations
        rig.clock.advance(10_000_000)
        rig.fireFlushes()
        XCTAssertEqual(rig.order.currentStats.reservations, held, "10 s later the owed frames still count")
        XCTAssertGreaterThan(rig.order.auxOwedCount, 0)
    }

    func testEveryResetPathClearsOwedAuxiliaryCapacity() {
        // resolve is idempotent per token and never goes negative
        let a = makePacked()
        a.offer(); a.settle()
        XCTAssertEqual(a.order.auxOwedCount, 1)
        a.backend.completeAux(); a.backend.completeAux()
        XCTAssertEqual(a.order.auxOwedCount, 0)

        // clearAuxiliary (aux session replaced / packed fallback) frees a waiting capture
        let b = makePacked()
        b.offer(); b.settle(); b.backend.complete()
        b.landAuxiliaryFrame()
        b.offer(); b.settle(); b.backend.complete()   // A: second owed -> aux 1 queued + 2 owed... capacity reached
        b.offer()                                      // C waits
        let before = b.order.currentStats.reservations
        b.order.clearAuxiliary()
        XCTAssertEqual(b.order.auxOwedCount, 0)
        b.aux.tryPop().map { _ in () }
        b.fireFlushes()
        XCTAssertEqual(b.order.currentStats.reservations, before + 1, "the waiting capture goes out after the reset")

        // stop clears too
        let c = makePacked()
        c.offer(); c.settle()
        XCTAssertEqual(c.order.auxOwedCount, 1)
        c.order.stop()
        XCTAssertEqual(c.order.auxOwedCount, 0)
    }

    // MARK: - Recovery frames keep their exemption when deferred

    /// A keyframe re-submission (`bypassGate`) that arrives while both encoder slots are busy waits as the pending
    /// frame. When a slot frees up while the output queue is full, it must still go out: it is the recovery.
    func testDeferredMainRecoveryFrameBypassesBackPressure() {
        let rig = makeRig(backPressure: true)
        func offer(bypass: Bool) {
            rig.stamp += 1
            rig.clock.advance(16_667)
            rig.order.offer(bypassGate: bypass) { [stamp = rig.stamp, clock = rig.clock] _ in BPFrame(stamp: stamp, gateUs: clock.now) }
            drain(rig)
        }
        offer(bypass: false)              // keyframe, slot 1
        offer(bypass: false)              // slot 2
        for _ in 0..<2 { rig.queue.push(EncodedVideoFrame(flags: [], captureTimeUs: 1, data: [1])) }   // queue full
        offer(bypass: true)               // recovery: both slots busy -> pending
        XCTAssertEqual(rig.backend.encoded.count, 2)
        rig.backend.complete()            // slots free up; the queue is still full
        drain(rig)
        XCTAssertEqual(rig.backend.encoded.count, 3, "the deferred recovery frame is not held back by back pressure")
    }

    func testDeferredAuxiliaryRecoveryFrameBypassesBackPressure() {
        let rig = makePacked()
        rig.offer(); rig.settle()         // keyframe: owes an auxiliary frame
        rig.offer(); rig.settle()         // second slot; two auxiliary frames owed = capacity
        XCTAssertEqual(rig.order.auxOwedCount, 2)
        rig.stamp += 1
        rig.clock.advance(16_667)
        rig.order.offer(bypassGate: true) { [stamp = rig.stamp, clock = rig.clock] _ in BPFrame(stamp: stamp, gateUs: clock.now) }
        rig.settle()
        XCTAssertEqual(rig.order.currentStats.reservations, 2, "both slots busy: the recovery frame is pending")
        rig.backend.complete()            // main slots free; auxiliary frames are still owed
        rig.settle()
        XCTAssertEqual(rig.order.currentStats.reservations, 3, "the deferred auxiliary recovery frame goes out")
    }

    /// The exemption is for the recovery frame only: once it is out, ordinary captures are held again.
    func testRecoveryExemptionEndsWhenTheFrameIsSubmitted() {
        let rig = makePacked()
        rig.offer(); rig.settle()
        rig.offer(); rig.settle()
        rig.stamp += 1
        rig.clock.advance(16_667)
        rig.order.offer(bypassGate: true) { [stamp = rig.stamp, clock = rig.clock] _ in BPFrame(stamp: stamp, gateUs: clock.now) }
        rig.settle()
        rig.backend.complete(); rig.settle()
        XCTAssertEqual(rig.order.currentStats.reservations, 3)
        rig.backend.complete(); rig.settle()
        rig.offer()                       // ordinary capture: auxiliary owed 3 >= capacity -> held
        XCTAssertEqual(rig.order.currentStats.reservations, 3)
    }

    func testHealthyFastTransportNeverHoldsOrDropsACapture() {
        let rig = makeRig(backPressure: true)
        for _ in 0..<120 { tick(rig, transportOpen: true) }
        XCTAssertEqual(rig.overwritten, 0)
        XCTAssertEqual(rig.backend.encoded.count, 120)
        XCTAssertEqual(rig.needed, 0)
    }

    // MARK: - T-378: one recovery keyframe escapes the accounting at a time

    private func offerPlain(_ rig: Rig) {
        rig.stamp += 1
        rig.clock.advance(16_667)
        rig.order.offer(bypassGate: false) { [stamp = rig.stamp, clock = rig.clock] _ in BPFrame(stamp: stamp, gateUs: clock.now) }
        drain(rig)
    }

    func testRecoveryKeyframeEntersAQueueFullOfDeltasItSupersedes() {
        let rig = makeRig(backPressure: true)
        offerPlain(rig); rig.backend.complete(); drain(rig)          // the first (start) keyframe is out
        _ = rig.queue.tryPop()
        for _ in 0..<2 { rig.queue.push(EncodedVideoFrame(flags: [], captureTimeUs: 1, data: [1])) }   // full of deltas
        rig.order.requestKeyframe()
        let before = rig.backend.encoded.count
        offerPlain(rig)
        XCTAssertEqual(rig.backend.encoded.count, before + 1, "the recovery keyframe is not held behind the deltas")
        rig.backend.complete(); drain(rig)
        XCTAssertEqual(rig.needed, 0, "the keyframe restarts the chain: the deltas it displaced need no new keyframe")
        XCTAssertTrue(rig.queue.tryPop() != nil)
    }

    func testSecondRecoveryKeyframeWaitsWhileTheFirstIsStillInTheEncoder() {
        let rig = makeRig(backPressure: true)
        offerPlain(rig); rig.backend.complete(); drain(rig)
        _ = rig.queue.tryPop()
        for _ in 0..<2 { rig.queue.push(EncodedVideoFrame(flags: [], captureTimeUs: 1, data: [1])) }   // queue full
        rig.order.requestKeyframe()
        offerPlain(rig)                                              // recovery keyframe #1: in the encoder
        let afterFirst = rig.backend.encoded.count
        rig.order.requestKeyframe()                                  // a repeated request for the same recovery
        offerPlain(rig)
        XCTAssertEqual(rig.backend.encoded.count, afterFirst, "the second recovery frame does not escape the accounting")
        XCTAssertTrue(rig.order.keyframePending, "the request is kept, not lost")
        // The first keyframe lands and the link drains: nothing deadlocks, the repeated request is served.
        rig.backend.complete(); drain(rig)
        while rig.queue.tryPop() != nil {}
        for _ in 0..<3 { tick(rig, transportOpen: true) }
        XCTAssertGreaterThan(rig.backend.encoded.count, afterFirst)
        XCTAssertFalse(rig.order.keyframePending)
    }

    /// Codex P2 (T-378): a bypass re-submission also waits while an earlier recovery keyframe is in the encoder.
    func testBypassResubmissionWaitsWhileARecoveryKeyframeIsInTheEncoder() {
        let rig = makeRig(backPressure: true)
        offerPlain(rig)                                   // the start keyframe: in the encoder
        XCTAssertEqual(rig.backend.encoded.count, 1)
        for _ in 0..<2 { rig.queue.push(EncodedVideoFrame(flags: [], captureTimeUs: 1, data: [1])) }   // queue full
        rig.stamp += 1
        rig.clock.advance(16_667)
        rig.order.offer(bypassGate: true) { [stamp = rig.stamp, clock = rig.clock] _ in BPFrame(stamp: stamp, gateUs: clock.now) }
        drain(rig)
        XCTAssertEqual(rig.backend.encoded.count, 1, "no second recovery frame escapes the accounting")
        // The keyframe lands, the link drains: the re-submission is served (no deadlock).
        rig.backend.complete(); drain(rig)
        while rig.queue.tryPop() != nil {}
        let fires = rig.flushLock.withLock { () -> [@Sendable () -> Void] in defer { rig.flushes = [] }; return rig.flushes }
        fires.forEach { $0() }
        drain(rig)
        XCTAssertEqual(rig.backend.encoded.count, 2)
    }

    /// Codex P2 (T-378): the frame the sender popped stays charged while the transport decides.
    func testPoppedFrameStaysInTheReservationUntilSettled() {
        let rig = makeRig(backPressure: true)
        rig.queue.setChargesPops(true)
        offerPlain(rig); rig.backend.complete(); drain(rig)   // start keyframe through (queue: keyframe)
        rig.queue.push(EncodedVideoFrame(flags: [], captureTimeUs: 2, data: [2]))   // queue: A, B
        let a = rig.queue.tryPop()!                                                  // sender pops A: B + A charged
        XCTAssertEqual(rig.queue.queuedCount, 2)
        let before = rig.backend.encoded.count
        offerPlain(rig)
        XCTAssertEqual(rig.backend.encoded.count, before, "A's slot is not free yet: the capture C is held, not admitted")
        XCTAssertTrue(rig.queue.unpop(a))                                            // busy: A comes back
        XCTAssertEqual(rig.queue.queuedCount, 2, "held A is still reserved")
        _ = rig.queue.tryPop()                                                       // retry pops A again ...
        rig.queue.settlePop()                                                        // ... the transport takes it
        XCTAssertEqual(rig.queue.queuedCount, 1)
        XCTAssertEqual(rig.needed, 0)
        XCTAssertEqual(rig.queue.discardedCount, 0)
    }

    func testStaleUnpopAfterAResyncIsDiscarded() {
        let rig = makeRig(backPressure: true)
        let q = rig.queue!
        q.setChargesPops(true)
        let config = EncodedVideoFrame(flags: .codecConfig, captureTimeUs: 0, data: [7])
        q.push(config)
        let popped = q.tryPop()!
        _ = q.resyncCountingKeyframes(config: { config })      // STARTUP resync resets the queue to [config]
        XCTAssertFalse(q.unpop(popped), "the old config must not come back behind the new one")
        XCTAssertEqual(q.queuedCount, 1)
        q.push(EncodedVideoFrame(flags: .keyframe, captureTimeUs: 1, data: [8]))
        XCTAssertEqual(q.queuedCount, 2)
        XCTAssertEqual(rig.needed, 0, "the recovery keyframe is not dropped")
    }

    func testPendingKeyframeIsNotHeldBack() {
        let rig = makeRig(backPressure: true)
        for _ in 0..<4 { tick(rig, transportOpen: false) }   // queue full
        rig.order.requestKeyframe()
        let before = rig.backend.encoded.count
        tick(rig, transportOpen: false)
        XCTAssertGreaterThan(rig.backend.encoded.count, before, "a requested keyframe still reaches the encoder")
    }
}
