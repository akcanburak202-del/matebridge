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

    var encoded: [Int] { lock.withLock { _encoded } }
    func encode(_ frame: BPFrame, keyframe: Bool, token: EncoderSubmitToken) {
        lock.withLock { _encoded.append(frame.stamp); outstanding.append((token, keyframe, frame.gateUs)) }
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
            downstreamLoad: { queue.queuedCount },
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
