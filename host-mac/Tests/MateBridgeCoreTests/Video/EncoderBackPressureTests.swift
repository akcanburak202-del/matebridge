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
    /// Packed full colour: every submit also starts an auxiliary encode that completes on its own (`completeAux`).
    var auxQueue: VideoFrameQueue?
    private var auxPending: [(Bool, UInt64)] = []

    var encoded: [Int] { lock.withLock { _encoded } }
    var auxInFlight: Int { lock.withLock { auxPending.count } }
    func encode(_ frame: BPFrame, keyframe: Bool, token: EncoderSubmitToken) {
        lock.withLock {
            _encoded.append(frame.stamp); outstanding.append((token, keyframe, frame.gateUs))
            if auxQueue != nil { auxPending.append((keyframe, frame.gateUs)) }
        }
    }

    /// The oldest `count` auxiliary encodes finish and reach the auxiliary queue.
    func completeAux(_ count: Int = .max) {
        let batch = lock.withLock { () -> [(Bool, UInt64)] in
            let n = min(count, auxPending.count)
            defer { auxPending.removeFirst(n) }
            return Array(auxPending.prefix(n))
        }
        for (key, us) in batch {
            var f = EncodedVideoFrame(flags: key ? [.keyframe] : [], captureTimeUs: us, data: [4, 5])
            f.view = 1
            auxQueue?.push(f)
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
            downstreamLoad: { queue.queuedCount + $0 },
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

    /// The auxiliary session finishes later than the main one: an auxiliary frame still encoding will land in the
    /// auxiliary queue, so it counts against its capacity even though the main slot was released.
    func testAuxiliaryFramesStillEncodingCountAgainstTheAuxiliaryQueue() {
        let backend = BPBackend()
        let clock = BPClock()
        let flushLock = NSLock()
        nonisolated(unsafe) var flushes: [@Sendable () -> Void] = []
        let counter = NSLock()
        nonisolated(unsafe) var needed = 0
        let main = VideoFrameQueue(keyframeNeeded: {})
        let aux = VideoFrameQueue(keyframeNeeded: { counter.withLock { needed += 1 } })
        backend.queue = main
        backend.auxQueue = aux
        let order = EncoderSubmitOrder<BPBackend>(
            backend: backend, streamFps: 60, maxInFlight: 2, initialBitrateKbps: 60_000,
            nowUs: { clock.now },
            scheduleFlush: { _, fire in flushLock.withLock { flushes.append(fire) } },
            downstreamLoad: { [weak backend] mainInFlight in
                DownstreamBudget.projected(mainInFlight: mainInFlight, mainQueued: main.queuedCount,
                                           auxInFlight: backend?.auxInFlight ?? 0, auxQueued: aux.queuedCount)
            },
            downstreamCapacity: BoundedFrameQueue.defaultCapacity)
        backend.order = order
        func offer(_ n: Int) {
            clock.advance(16_667)
            order.offer(bypassGate: false) { _ in BPFrame(stamp: n, gateUs: clock.now) }
            let s = DispatchSemaphore(value: 0)
            order.afterQueued { s.signal() }
            _ = s.wait(timeout: .now() + 5)
            backend.complete()                       // main output is immediate and drained by the sender
            while main.tryPop() != nil {}
        }
        offer(1)                                     // keyframe; its auxiliary encode stays pending
        backend.completeAux(1)                       // aux keyframe queued (transport stalled: nobody pops)
        offer(2)                                     // aux A: encoding, aux queue holds 1
        offer(3)                                     // B: projected 1 queued + 1 encoding = 2 -> must be held
        XCTAssertEqual(backend.encoded.count, 2, "B waits: A is still encoding and the queue already holds one")
        backend.completeAux()                        // A (and nothing else) lands
        XCTAssertEqual(counter.withLock { needed }, 0, "no auxiliary overflow")
        XCTAssertEqual(aux.discardedCount, 0)
    }

    func testAuxInFlightTrackerResolvesAndForgetsStaleEntries() {
        var t = AuxInFlightTracker()
        t.began(captureTimeUs: 1_000); t.began(captureTimeUs: 2_000)
        XCTAssertEqual(t.count(nowUs: 3_000), 2)
        t.ended(captureTimeUs: 1_000)
        XCTAssertEqual(t.count(nowUs: 3_000), 1)
        t.ended(captureTimeUs: 9_999)   // unknown: ignored
        XCTAssertEqual(t.count(nowUs: 3_000), 1)
        XCTAssertEqual(t.count(nowUs: 2_000 + AuxInFlightTracker.maxAgeUs + 1), 0, "a missed resolution never holds captures for good")
    }

    func testHealthyFastTransportNeverHoldsOrDropsACapture() {
        let rig = makeRig(backPressure: true)
        for _ in 0..<120 { tick(rig, transportOpen: true) }
        XCTAssertEqual(rig.overwritten, 0)
        XCTAssertEqual(rig.backend.encoded.count, 120)
        XCTAssertEqual(rig.needed, 0)
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
