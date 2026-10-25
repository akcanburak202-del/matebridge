import XCTest
@testable import MateBridgeCore

/// T-378: a temporary `.busy` keeps the encoded frame and retries it (no keyframe, `seq` unchanged); one recovery
/// keyframe at a time while it is on its way.
private final class ScriptedTransport: VideoTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var ready: (@Sendable () -> Void)?
    private var script: [VideoSendResult]
    private(set) var sent: [VideoFrame] = []
    private(set) var attempts: [VideoFrame] = []

    /// Answers the first sends with `script`, then accepts everything.
    init(script: [VideoSendResult]) { self.script = script }

    var canSend: Bool { true }
    func setReadyHandler(_ handler: (@Sendable () -> Void)?) { lock.withLock { ready = handler } }
    func send(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        sendResult(frame, completion: completion).isAccepted
    }
    func sendResult(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void) -> VideoSendResult {
        let r: VideoSendResult = lock.withLock {
            attempts.append(frame)
            let r = script.isEmpty ? .accepted : script.removeFirst()
            if r == .accepted { sent.append(frame) }
            return r
        }
        if r == .accepted { completion(true) }
        return r
    }
    var sentCount: Int { lock.withLock { sent.count } }
    var attemptCount: Int { lock.withLock { attempts.count } }
    var sentData: [[UInt8]] { lock.withLock { sent.map(\.data) } }
    var sentSeqs: [UInt32] { lock.withLock { sent.map(\.frameSeq) } }
}

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

final class BusyRetainTests: XCTestCase {
    private func delta(_ n: UInt8) -> EncodedVideoFrame { .init(flags: [], captureTimeUs: UInt64(n), data: [n]) }
    private func key(_ n: UInt8) -> EncodedVideoFrame { .init(flags: .keyframe, captureTimeUs: UInt64(n), data: [n]) }

    private func waitUntil(_ what: String, timeout: TimeInterval = 2, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(cond(), what)
    }

    // MARK: Sender

    func testBusyKeepsTheFrameRetriesItWithoutAKeyframeAndKeepsTheSequence() async {
        let transport = ScriptedTransport(script: [.accepted, .busy, .busy, .busy])
        let requests = Tally()
        let frames = VideoFrameQueue(keyframeNeeded: {})
        let sender = VideoSender(transport: transport, frames: frames, requestKeyframe: { requests.add("plain") },
                                 requestKeyframeForRefusal: { requests.add($0.rawValue) })
        sender.start()
        frames.push(key(1))
        frames.push(delta(2))
        await waitUntil("both frames sent") { transport.sentCount == 2 }
        await sender.stop()
        XCTAssertEqual(transport.sentData, [[1], [2]], "the busy frame is the same one, in order")
        XCTAssertEqual(transport.sentSeqs, [0, 1], "a busy answer does not use up a sequence number")
        XCTAssertEqual(transport.attemptCount, 5)
        XCTAssertEqual(requests.all, [], "busy never asks for a keyframe")
        let c = sender.currentCounters
        XCTAssertEqual(c.busyRetries, 3)
        XCTAssertEqual(c.framesRejected, 0)
        XCTAssertEqual(c.framesSent, 2)
        XCTAssertEqual(frames.queuedCount, 0)
    }

    func testRealRefusalStillRequestsAKeyframeAndNamesTheKind() async {
        for kind in [VideoRefusal.write, .seal, .invalid] {
            let transport = ScriptedTransport(script: [.refused(kind)])
            let requests = Tally()
            let frames = VideoFrameQueue(keyframeNeeded: {})
            let sender = VideoSender(transport: transport, frames: frames, requestKeyframe: { requests.add("plain") },
                                     requestKeyframeForRefusal: { requests.add($0.rawValue) })
            sender.start()
            frames.push(key(1))
            await waitUntil("refusal seen") { sender.currentCounters.framesRejected == 1 }
            await sender.stop()
            XCTAssertEqual(requests.all, [kind.rawValue])
            XCTAssertEqual(sender.currentCounters.refusals, [kind: 1])
            XCTAssertEqual(sender.currentCounters.busyRetries, 0)
        }
    }

    func testRefusalWithoutAKindCallbackUsesTheTransportBoolPath() async {
        let transport = ScriptedTransport(script: [.refused(.other)])
        let requests = Tally()
        let frames = VideoFrameQueue(keyframeNeeded: {})
        let sender = VideoSender(transport: transport, frames: frames, requestKeyframe: { requests.add("plain") })
        sender.start()
        frames.push(key(1))
        await waitUntil("keyframe requested") { requests.all.count == 1 }
        await sender.stop()
        XCTAssertEqual(requests.all, ["plain"])
    }

    func testPackedBusyKeepsMainAndAuxiliaryFramesInOrder() async {
        let transport = ScriptedTransport(script: [.accepted, .busy, .accepted, .busy, .busy])
        let requests = Tally()
        let main = VideoFrameQueue(keyframeNeeded: {})
        let aux = VideoFrameQueue(keyframeNeeded: {})
        let sender = VideoSender(transport: transport, frames: main, auxFrames: aux,
                                 requestKeyframe: { requests.add("main") },
                                 requestAuxKeyframe: { requests.add("aux") })
        sender.start()
        var m = key(1), a = key(11)
        m.pairID = 1
        a.pairID = 1
        main.push(m)
        aux.push(a)
        var m2 = delta(2), a2 = delta(12)
        m2.pairID = 2
        a2.pairID = 2
        main.push(m2)
        aux.push(a2)
        await waitUntil("all four sent") { transport.sentCount == 4 }
        await sender.stop()
        XCTAssertEqual(transport.sentData.filter { $0[0] < 10 }, [[1], [2]], "main order kept")
        XCTAssertEqual(transport.sentData.filter { $0[0] > 10 }, [[11], [12]], "auxiliary order kept")
        XCTAssertEqual(requests.all, [])
        XCTAssertEqual(sender.currentCounters.busyRetries, 3)
        XCTAssertEqual(sender.currentCounters.auxDropped, 0)
    }

    // MARK: Queue accounting

    func testHeldFrameCountsInTheQueueAndIsTheHead() {
        let q = VideoFrameQueue(keyframeNeeded: {})
        q.push(key(1))
        q.push(delta(2))
        let popped = q.tryPop()
        XCTAssertEqual(q.queuedCount, 1)
        XCTAssertTrue(q.unpop(popped!))
        XCTAssertEqual(q.queuedCount, 2, "the retained frame is counted in the downstream reservation")
        XCTAssertFalse(q.unpop(delta(9)), "only one frame can be held")
        XCTAssertEqual(q.tryPop()?.data, [1])
        XCTAssertEqual(q.tryPop()?.data, [2])
        XCTAssertNil(q.tryPop())
    }

    func testOverflowNeverDropsTheHeldFrameAndHonoursItsSlot() {
        var q = BoundedFrameQueue(capacity: 2)
        q.push(key(1))
        XCTAssertEqual(q.pop()?.data, [1])
        q.unpop(key(1))
        XCTAssertEqual(q.push(delta(2)), 0, "held + one queued fits capacity 2")
        // A third frame overflows: the oldest queued delta goes (and its dependent is purged), the held one stays.
        XCTAssertEqual(q.push(delta(3)), 2)
        XCTAssertTrue(q.isAwaitingKeyframe)
        XCTAssertEqual(q.pop()?.data, [1], "the held keyframe is still the head")
        XCTAssertNil(q.pop())
    }

    func testNewConsumerClearsTheHeldFrame() {
        var q = BoundedFrameQueue(capacity: 2)
        q.unpop(delta(1))
        XCTAssertEqual(q.count, 1)
        q.startNewConsumer(config: nil)
        XCTAssertTrue(q.isEmpty)
        XCTAssertFalse(q.hasHeldFrame)
    }

    func testBreakChainKeepsAHeldKeyframeAndDropsAHeldDelta() {
        var q = BoundedFrameQueue(capacity: 2)
        q.unpop(key(1))
        q.push(key(2))
        q.breakChain()
        XCTAssertEqual(q.count, 2, "a held keyframe restarts the chain")
        XCTAssertFalse(q.isAwaitingKeyframe)

        var r = BoundedFrameQueue(capacity: 2)
        r.unpop(delta(1))
        r.breakChain()
        XCTAssertFalse(r.hasHeldFrame, "a held delta is later than the lost frame: useless")
        XCTAssertTrue(r.isAwaitingKeyframe)
    }

    // MARK: One recovery generation

    /// Codex round 3 #3: the suppression has a hard bound. A write stuck longer than `pendingTimeoutUs` gets exactly
    /// one more IDR after the bound, none before.
    func testStuckWriteSuppressesRepeatedRequestsOnlyUntilTheBound() {
        var c = KeyframeRequestCoalescer()
        let bound = KeyframeRequestCoalescer.defaultPendingTimeoutUs
        let t0: UInt64 = 5_000_000
        XCTAssertTrue(c.request(.framesDropped, nowUs: t0, keyframesPushed: 0).forceKeyframe)
        var forcedAt: [UInt64] = []
        var now = t0 + 100_000
        while now < t0 + bound + 800_000 {   // the IDR reached the queue (count 1); its write never completes
            if c.request(.framesDropped, nowUs: now, keyframesPushed: 1).forceKeyframe { forcedAt.append(now) }
            now += 100_000
        }
        XCTAssertEqual(forcedAt.count, 1, "exactly one extra IDR")
        XCTAssertGreaterThanOrEqual(forcedAt[0] - t0, bound, "none before the bound")
        XCTAssertLessThanOrEqual(forcedAt[0] - t0, bound + 100_000)
    }

    func testHostDropWatchIsBoundedToo() {
        var c = KeyframeRequestCoalescer()
        let bound = KeyframeRequestCoalescer.defaultPendingTimeoutUs
        _ = c.request(.framesDropped, nowUs: 0, keyframesPushed: 0)
        let q = KeyframeQueueState(awaitingKeyframe: true, keyframeQueued: false, keyframesPushed: 1)
        var now: UInt64 = 10_000
        var d = c.hostDrop(nowUs: now, queue: q)
        var forcedAt: [UInt64] = []
        while now < bound + 600_000 {
            if d.forceKeyframe { forcedAt.append(now) }
            now = min(d.recheckAtUs ?? now + 50_000, now + 50_000)
            d = c.checkDeferred(nowUs: now, queue: q)
        }
        XCTAssertEqual(forcedAt.count, 1)
        XCTAssertGreaterThanOrEqual(forcedAt[0], bound)
    }

    /// Codex round 3 #1: a config that is held or with the sender is not queued a second time, so it cannot push the
    /// recovery keyframe out of the queue.
    func testHeldOrChargedConfigIsNotDuplicatedByTheEncodersAnnouncement() {
        var q = BoundedFrameQueue(capacity: 2)
        q.chargesPops = true
        let config = EncodedVideoFrame(flags: .codecConfig, captureTimeUs: 0, data: [7])
        q.push(config)
        let popped = q.pop()!                                   // with the sender (charged)
        q.push(config)                                          // the encoder announces the same config
        XCTAssertEqual(q.reservedCount, 1, "not queued again while the sender has it")
        XCTAssertTrue(q.unpop(popped))                          // busy: held
        q.push(config)
        XCTAssertEqual(q.count, 1, "not queued again while held")
        q.push(key(1))                                          // the recovery keyframe
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q.pop()?.data, [7])
        XCTAssertEqual(q.pop()?.data, [1], "the keyframe was not the overflow victim")
    }

    /// Codex round 3 #2: an auxiliary keyframe counts as written when its write completes, not when it is queued.
    func testAuxKeyframeWrittenIsReportedOnlyWhenTheWriteCompletes() async {
        let transport = ScriptedTransport(script: [.accepted, .busy, .busy, .accepted])
        let written = Tally()
        let main = VideoFrameQueue(keyframeNeeded: {})
        let aux = VideoFrameQueue(keyframeNeeded: {})
        let sender = VideoSender(transport: transport, frames: main, auxFrames: aux, requestKeyframe: {},
                                 auxKeyframeWritten: { written.add("aux \($0)") })
        sender.start()
        var m = key(1), a = key(11)
        m.pairID = 1
        a.pairID = 1
        main.push(m)
        aux.push(a)
        await waitUntil("both sent") { transport.sentCount == 2 }
        await sender.stop()
        XCTAssertEqual(transport.attemptCount, 4, "the aux keyframe was busy twice first")
        XCTAssertEqual(written.all, ["aux 1"], "reported once, after the accepted write; never for the main keyframe")
    }

    /// Codex round 2, P1: STARTUP / DECODE_ERROR always force a new IDR (the T-122 behaviour). A resync reopens nothing
    /// by itself: the queue refuses deltas until a keyframe is pushed, and the IDR being written cannot do that.
    func testStartupDuringASlowIdrWriteForcesAKeyframeAndVideoResumes() {
        var c = KeyframeRequestCoalescer()
        let q = VideoFrameQueue(keyframeNeeded: {})
        q.setChargesPops(true)
        let config = EncodedVideoFrame(flags: .codecConfig, captureTimeUs: 0, data: [7])
        XCTAssertTrue(c.request(.framesDropped, nowUs: 1_000_000, keyframesPushed: q.keyframesPushed).forceKeyframe)
        q.push(key(1))                                         // the recovery IDR reaches the queue ...
        let idr = q.tryPop()                                   // ... and is being written slowly
        XCTAssertNotNil(idr)
        // 600 ms later the client's STARTUP retry arrives.
        let r = q.resyncCountingKeyframes(config: { config })
        let d = c.request(.startup, nowUs: 1_600_000, keyframesPushed: r.keyframesPushed, configResent: r.configQueued)
        XCTAssertTrue(d.forceKeyframe, "a new IDR is forced even though one is being written")
        q.push(delta(2))                                       // refused: the queue awaits a keyframe
        XCTAssertEqual(q.queuedCount, 1)
        q.push(key(3))                                         // the forced keyframe
        XCTAssertEqual([q.tryPop()?.data, q.tryPop()?.data], [[7], [3]], "config, then the new keyframe")
        q.push(delta(4))                                       // deltas flow again
        XCTAssertEqual(q.tryPop()?.data, [4], "video resumes with deltas")
    }

    /// Codex round 2, P2: a recovery keyframe pushed while a popped frame is charged counts that frame toward capacity,
    /// so the frame coming back from a busy transport can never leave the queue over capacity.
    func testChargedPopCountsTowardCapacityWhenTheFrameComesBack() {
        var q = BoundedFrameQueue(capacity: 2)
        q.chargesPops = true
        q.push(delta(1)); q.push(delta(2))
        let a = q.pop()!                                       // A is with the sender; queue [B]
        q.push(key(3))                                         // recovery IDR: [B, K] + charged A = 3 > 2
        XCTAssertLessThanOrEqual(q.reservedCount, 2)
        XCTAssertTrue(q.unpop(a))                              // transport busy: A comes back
        XCTAssertLessThanOrEqual(q.count, 2, "never above capacity")
        XCTAssertEqual(q.pop()?.data, [1])
        XCTAssertEqual(q.pop()?.data, [3], "the keyframe survives; the superseded delta B went")
        XCTAssertNil(q.pop())
        XCTAssertFalse(q.takeKeyframeRequest(), "the keyframe restarts the chain: nothing more to request")
    }

    func testStatsFieldsShowOnlyNonZeroDeltas() {
        var before = VideoSender.Counters()
        before.busyRetries = 2
        var now = before
        XCTAssertEqual(now.retryLogFields(since: before), "")
        now.busyRetries = 5
        now.refusals = [.write: 1, .invalid: 2]
        XCTAssertEqual(now.retryLogFields(since: before), " send_retry=3 refusal_write=1 refusal_invalid=2")
    }

    func testRefusalSubtypeIsLoggedNextToTheCause() {
        var c = KeyframeRequestCoalescer()
        c.internalForce(nowUs: 1_000_000, keyframesPushed: 0, cause: .transportRefused, refusal: .write)
        c.internalForce(nowUs: 2_000_000, keyframesPushed: 0, cause: .queueOverflow)
        let notes = c.takeForceNotes()
        XCTAssertEqual(notes.map(\.logFields), ["cause=transport_refused since_last_ms=- refusal=write",
                                                "cause=queue_overflow since_last_ms=1000"])
    }
}
