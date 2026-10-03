import XCTest
@testable import MateBridgeCore

/// T-176: a host-side queue drop no longer forces an IDR at once while another keyframe is on its way or was just
/// written; the deferred force is issued when the window expires, and the queue never awaits a keyframe for longer
/// than `pendingTimeoutUs` without a force. Fake clock in µs.
final class HostDropKeyframeTests: XCTestCase {
    private let ms: UInt64 = 1000
    private let window = KeyframeRequestCoalescer.defaultWindowUs
    private let timeout = KeyframeRequestCoalescer.defaultPendingTimeoutUs

    /// Encoder -> `BoundedFrameQueue` -> one-at-a-time link, wired like `VideoPipeline` (`hostDrop` on a drop,
    /// `checkDeferred` at `recheckAtUs`). Frame `n` is the encoder's n-th output; a delta references frame `n - 1`.
    private struct Sim {
        var q = BoundedFrameQueue()
        var c = KeyframeRequestCoalescer()
        var now: UInt64 = 10_000_000
        var pushedKeyframes: UInt64 = 0
        var next = 0
        /// The encoder's force flag: the next output is a keyframe.
        var forceNext = false
        var forcesAt: [UInt64] = []
        var recheckAtUs: UInt64?
        /// Encoder-order indices of the frames popped by the link (in pop order) and whether each was a keyframe.
        var popped: [(index: Int, key: Bool, atUs: UInt64)] = []
        /// Link time spent writing keyframes.
        var keyBusyUs: UInt64 = 0
        /// The frame on the link and when its write completes.
        var writing: (index: Int, key: Bool, bytes: Int, doneUs: UInt64)?
        /// Host time from the drop that left the queue awaiting a keyframe; nil while it does not await one.
        var awaitingSinceUs: UInt64?
        var longestAwaitWithoutForceUs: UInt64 = 0
        var lastForceOrDropUs: UInt64 = 0

        var state: KeyframeQueueState {
            .init(awaitingKeyframe: q.isAwaitingKeyframe, keyframeQueued: q.hasQueuedKeyframe,
                  keyframesPushed: pushedKeyframes)
        }

        static func frame(_ n: Int, key: Bool) -> EncodedVideoFrame {
            .init(flags: key ? .keyframe : [], captureTimeUs: UInt64(n), data: [UInt8(n & 0xff), UInt8(n >> 8)])
        }

        mutating func apply(_ d: KeyframeRequestCoalescer.HostDecision) {
            if d.forceKeyframe {
                forceNext = true
                forcesAt.append(now)
                lastForceOrDropUs = now
            }
            if let at = d.recheckAtUs { recheckAtUs = min(recheckAtUs ?? at, at) }
        }

        /// The encoder outputs its next frame (a keyframe when forced or first) and pushes it.
        mutating func encode(forceKey: Bool = false) {
            let key = forceKey || forceNext || next == 0
            forceNext = false
            if key { pushedKeyframes += 1 }
            let wasAwaiting = q.isAwaitingKeyframe
            q.push(Self.frame(next, key: key))
            next += 1
            if q.takeKeyframeRequest() {
                if !wasAwaiting { lastForceOrDropUs = now }
                apply(c.hostDrop(nowUs: now, queue: state))
            }
            trackAwait()
        }

        mutating func trackAwait() {
            if q.isAwaitingKeyframe {
                if awaitingSinceUs == nil { awaitingSinceUs = now }
                longestAwaitWithoutForceUs = max(longestAwaitWithoutForceUs, now - lastForceOrDropUs)
            } else {
                awaitingSinceUs = nil
            }
        }

        /// Runs the re-check timer if due, completes a write if due, and lets the link take the next frame.
        mutating func service(keyBytes: Int = 400_000, deltaBytes: Int = 30_000, bytesPerMs: Int = 2_000) {
            if let at = recheckAtUs, at <= now {
                recheckAtUs = nil
                apply(c.checkDeferred(nowUs: now, queue: state))
            }
            if let w = writing, w.doneUs <= now {
                if w.key { c.keyframeWritten(nowUs: now, bytes: w.bytes) }
                writing = nil
            }
            if writing == nil, let f = q.pop(), !f.isCodecConfig {
                let n = Int(f.data[0]) | Int(f.data[1]) << 8
                let bytes = f.isKeyframe ? keyBytes : deltaBytes
                popped.append((n, f.isKeyframe, now))
                let durationUs = UInt64(max(1, bytes / bytesPerMs)) * 1000
                if f.isKeyframe { keyBusyUs += durationUs }
                writing = (n, f.isKeyframe, bytes, now + durationUs)
            }
            trackAwait()
        }

        /// Every popped delta's reference (the previous encoder output) was popped and decodable.
        var poppedIsDecodable: Bool {
            var lastDecoded: Int?
            for f in popped {
                if f.key || lastDecoded == f.index - 1 { lastDecoded = f.index } else { return false }
            }
            return true
        }
    }

    // MARK: - [IDR, d1] + d2

    func testDropBehindAQueuedKeyframeDefersTheForceAndStaysDecodable() throws {
        var sim = Sim()
        sim.encode()                       // 0: IDR (queued, link idle: not serviced yet)
        sim.encode()                       // 1: d1
        sim.encode()                       // 2: d2 -> d1 dropped, d2 purged, IDR stays
        XCTAssertTrue(sim.forcesAt.isEmpty, "no immediate force while a keyframe is queued ahead")
        XCTAssertTrue(sim.q.isAwaitingKeyframe)
        XCTAssertNotNil(sim.recheckAtUs, "the deferred force is scheduled, not swallowed")
        let dropUs = sim.now

        // The link takes the IDR (200 ms on a 2 MB/s link); the encoder keeps going at ~60 fps.
        var writtenUs: UInt64?
        for _ in 0..<1200 {
            sim.now += ms
            sim.service()
            if writtenUs == nil, sim.writing == nil, sim.popped.count == 1 { writtenUs = sim.now }
            if sim.now % 16_000 == 0 { sim.encode() }
        }
        let written = try XCTUnwrap(writtenUs)
        XCTAssertGreaterThanOrEqual(sim.forcesAt.count, 1)
        XCTAssertGreaterThanOrEqual(sim.forcesAt[0], written + window, "forced only when the window after the write expired")
        XCTAssertLessThan(sim.forcesAt[0], written + window + 2 * ms)
        XCTAssertLessThanOrEqual(sim.forcesAt[0] - dropUs, timeout)
        XCTAssertEqual(sim.popped[0].index, 0)
        XCTAssertTrue(sim.popped.count > 2 && sim.popped[1].key, "after the queued IDR, the next frame out is the new keyframe")
        XCTAssertTrue(sim.poppedIsDecodable, "no delta whose reference was dropped is ever popped: \(sim.popped)")
    }

    func testDropWhileAKeyframeIsStillInTheEncoderDoesNotForce() {
        var q = BoundedFrameQueue()
        var c = KeyframeRequestCoalescer()
        // A client FRAMES_DROPPED forced a keyframe at t=0 (nothing pushed yet).
        XCTAssertTrue(c.request(.framesDropped, nowUs: 0, keyframesPushed: 1).forceKeyframe)
        q.push(Sim.frame(0, key: true)); _ = q.pop()          // keyframe 0 written long before (count 1)
        q.push(Sim.frame(1, key: false)); q.push(Sim.frame(2, key: false)); q.push(Sim.frame(3, key: false))
        XCTAssertTrue(q.takeKeyframeRequest())
        let state = KeyframeQueueState(awaitingKeyframe: q.isAwaitingKeyframe, keyframeQueued: q.hasQueuedKeyframe,
                                       keyframesPushed: 1)
        let d = c.hostDrop(nowUs: 20 * ms, queue: state)
        XCTAssertFalse(d.forceKeyframe, "the keyframe still in the encoder restarts the chain once pushed")
        XCTAssertEqual(d.recheckAtUs, timeout, "watched until the pending keyframe times out")
        // It arrives: the queue no longer awaits a keyframe, and the watch ends.
        q.push(Sim.frame(4, key: true))
        let after = c.checkDeferred(nowUs: 30 * ms, queue: .init(awaitingKeyframe: q.isAwaitingKeyframe,
                                                                 keyframeQueued: true, keyframesPushed: 2))
        XCTAssertEqual(after, .idle)
    }

    func testDropRightAfterAWrittenKeyframeWaitsForTheWindow() {
        var c = KeyframeRequestCoalescer()
        c.keyframeWritten(nowUs: 1_000 * ms, bytes: 400_000)
        let awaiting = KeyframeQueueState(awaitingKeyframe: true, keyframeQueued: false, keyframesPushed: 5)
        let d = c.hostDrop(nowUs: 1_100 * ms, queue: awaiting)
        XCTAssertEqual(d, .init(forceKeyframe: false, recheckAtUs: 1_000 * ms + window))
        XCTAssertFalse(c.checkDeferred(nowUs: 1_000 * ms + window - 1, queue: awaiting).forceKeyframe,
                       "an early timer changes nothing")
        let due = c.checkDeferred(nowUs: 1_000 * ms + window, queue: awaiting)
        XCTAssertTrue(due.forceKeyframe)
        XCTAssertEqual(due.recheckAtUs, 1_000 * ms + window + timeout, "the forced keyframe is watched in turn")
        XCTAssertEqual(c.hostForcedTotal, 1)
        XCTAssertEqual(c.hostDeferredTotal, 1)
    }

    func testIsolatedDropStillForcesAtOnce() {
        var c = KeyframeRequestCoalescer()
        c.keyframeWritten(nowUs: 0, bytes: 1)
        let d = c.hostDrop(nowUs: 5_000 * ms, queue: .init(awaitingKeyframe: true, keyframeQueued: false,
                                                           keyframesPushed: 1))
        XCTAssertTrue(d.forceKeyframe, "nothing on its way and the last IDR is old: same as before T-176")
        XCTAssertEqual(d.recheckAtUs, 5_000 * ms + timeout)
    }

    func testDropThatDidNotLeaveTheQueueAwaitingIsIgnored() {
        var c = KeyframeRequestCoalescer()
        let d = c.hostDrop(nowUs: 0, queue: .init(awaitingKeyframe: false, keyframeQueued: true, keyframesPushed: 3))
        XCTAssertEqual(d, .idle)
    }

    // MARK: - Nothing is swallowed forever

    func testDeferredForceIsReissuedUntilAKeyframeArrives() {
        // The forced keyframe never reaches the queue (e.g. encode failures): forced again every pendingTimeoutUs.
        var c = KeyframeRequestCoalescer()
        let awaiting = KeyframeQueueState(awaitingKeyframe: true, keyframeQueued: false, keyframesPushed: 2)
        c.keyframeWritten(nowUs: 0, bytes: 1)
        var now: UInt64 = 10 * ms
        var d = c.hostDrop(nowUs: now, queue: awaiting)
        var forces: [UInt64] = []
        var lastForceOrDrop = now
        while now < 5_000 * ms {
            if d.forceKeyframe { forces.append(now); lastForceOrDrop = now }
            XCTAssertLessThanOrEqual(now - lastForceOrDrop, timeout, "awaiting without a force for too long")
            guard let at = d.recheckAtUs else { return XCTFail("watch ended while the queue still awaits a keyframe") }
            XCTAssertGreaterThan(at, now)
            now = at
            d = c.checkDeferred(nowUs: now, queue: awaiting)
        }
        XCTAssertEqual(forces.first, window, "first force when the window after the last write expired")
        XCTAssertEqual(zip(forces.dropFirst(), forces).map { $0 - $1 }, Array(repeating: timeout, count: forces.count - 1))
    }

    func testAKeyframeThatStaysQueuedCannotHoldTheForceBackBeyondTheTimeout() throws {
        // A keyframe seen in the queue covers the drop only until pendingTimeoutUs (e.g. it was later discarded).
        var c = KeyframeRequestCoalescer()
        let stuck = KeyframeQueueState(awaitingKeyframe: true, keyframeQueued: true, keyframesPushed: 4)
        var now: UInt64 = 0
        var d = c.hostDrop(nowUs: now, queue: stuck)
        XCTAssertFalse(d.forceKeyframe)
        while !d.forceKeyframe {
            now = try XCTUnwrap(d.recheckAtUs)
            XCTAssertLessThanOrEqual(now, timeout)
            d = c.checkDeferred(nowUs: now, queue: stuck)
        }
        XCTAssertEqual(now, timeout, "hard bound")
    }

    func testKeyframeBeingWrittenDefersUntilItsWriteAndWindow() {
        var c = KeyframeRequestCoalescer()
        // Seen queued at the drop, then popped by the sender (no longer queued) and written 300 ms later.
        var d = c.hostDrop(nowUs: 0, queue: .init(awaitingKeyframe: true, keyframeQueued: true, keyframesPushed: 1))
        let writing = KeyframeQueueState(awaitingKeyframe: true, keyframeQueued: false, keyframesPushed: 1)
        var now: UInt64 = 0
        while let at = d.recheckAtUs, at < 300 * ms {
            XCTAssertFalse(d.forceKeyframe, "the keyframe being written covers the drop")
            now = at
            d = c.checkDeferred(nowUs: now, queue: writing)
        }
        XCTAssertFalse(d.forceKeyframe)
        c.keyframeWritten(nowUs: 300 * ms, bytes: 1)
        d = c.checkDeferred(nowUs: 300 * ms, queue: writing)
        XCTAssertEqual(d, .init(forceKeyframe: false, recheckAtUs: 300 * ms + window))
        XCTAssertTrue(c.checkDeferred(nowUs: 300 * ms + window, queue: writing).forceKeyframe)
    }

    func testClientForceRestartsTheHardBoundAndResetEndsTheWatch() {
        var c = KeyframeRequestCoalescer()
        let awaiting = KeyframeQueueState(awaitingKeyframe: true, keyframeQueued: true, keyframesPushed: 1)
        _ = c.hostDrop(nowUs: 0, queue: awaiting)
        // A client STARTUP forced a keyframe at 600 ms (still in the encoder): it covers the drop.
        XCTAssertTrue(c.request(.startup, nowUs: 600 * ms, keyframesPushed: 1, configResent: true).forceKeyframe)
        let d = c.checkDeferred(nowUs: timeout, queue: .init(awaitingKeyframe: true, keyframeQueued: false,
                                                            keyframesPushed: 1))
        XCTAssertFalse(d.forceKeyframe, "a force issued since the drop: no second one at the old hard bound")
        XCTAssertEqual(d.recheckAtUs, 600 * ms + timeout)
        c.reset(nowUs: 700 * ms, keyframesPushed: 1)
        XCTAssertEqual(c.checkDeferred(nowUs: 800 * ms, queue: awaiting), .idle,
                       "a new consumer forces its own keyframe; the watch of the old connection ends")
    }

    // MARK: - Sustained back-pressure

    /// 60 fps encoder; for the first 3 s the link carries deltas but needs ~170 ms per IDR (Wi-Fi under contention),
    /// so every IDR backs the 2-frame queue up and causes a drop. The old policy forced a keyframe on every such drop
    /// and kept the link busy with IDRs; now each drop waits for the window after the last write, which leaves the
    /// link idle part of the time. After the burst (fast link) the stream recovers to deltas.
    func testBackPressureBurstForcesFewerKeyframesAndRecovers() {
        let burstEndUs: UInt64 = 13_000_000
        func run(immediate: Bool) -> Sim {
            var sim = Sim()
            for _ in 0..<5_000 {
                sim.now += ms
                sim.service(deltaBytes: 32_000, bytesPerMs: sim.now < burstEndUs ? 2_400 : 40_000)
                guard sim.now % 16_000 == 0 else { continue }
                if immediate {  // pre-T-176: force on every drop
                    let key = sim.forceNext || sim.next == 0
                    sim.forceNext = false
                    if key { sim.pushedKeyframes += 1 }
                    sim.q.push(Sim.frame(sim.next, key: key))
                    sim.next += 1
                    if sim.q.takeKeyframeRequest() { sim.forceNext = true; sim.forcesAt.append(sim.now) }
                } else {
                    sim.encode()
                }
            }
            return sim
        }
        let before = run(immediate: true)
        let after = run(immediate: false)
        XCTAssertTrue(before.poppedIsDecodable)
        XCTAssertTrue(after.poppedIsDecodable, "\(after.popped)")
        let burstForces = { (s: Sim) in s.forcesAt.filter { $0 < burstEndUs }.count }
        XCTAssertLessThan(burstForces(after) * 4, burstForces(before), "far fewer forced IDRs during the burst")
        XCTAssertLessThan(after.keyBusyUs * 3, before.keyBusyUs * 2, "IDRs no longer keep the link busy")
        XCTAssertLessThanOrEqual(after.longestAwaitWithoutForceUs, timeout)
        let deltasAfterBurst = after.popped.filter { !$0.key && $0.atUs >= burstEndUs }.count
        XCTAssertGreaterThan(deltasAfterBurst, 50, "deltas flow again once the link is fast")
    }

    // MARK: - Queue snapshot

    func testQueueSnapshotReportsAwaitingAndQueuedKeyframe() {
        let q = VideoFrameQueue(keyframeNeeded: {})
        XCTAssertEqual(q.keyframeState, .init(awaitingKeyframe: false, keyframeQueued: false, keyframesPushed: 0))
        q.push(Sim.frame(0, key: true)); q.push(Sim.frame(1, key: false)); q.push(Sim.frame(2, key: false))
        XCTAssertEqual(q.keyframeState, .init(awaitingKeyframe: true, keyframeQueued: true, keyframesPushed: 1))
        q.push(Sim.frame(3, key: true))
        XCTAssertEqual(q.keyframeState, .init(awaitingKeyframe: false, keyframeQueued: true, keyframesPushed: 2))
    }
}
