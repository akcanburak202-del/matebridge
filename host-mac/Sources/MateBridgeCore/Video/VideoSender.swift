import Foundation

/// The network side of one video connection, as seen by `VideoSender`.
/// Contract (PROTOCOL.md section 5): at most a small fixed number of sends may be in flight; `send` returns false
/// and transmits nothing when the limit is reached or the frame is invalid.
public protocol VideoTransport: Sendable {
    var canSend: Bool { get }
    /// Called whenever an outstanding send completes. Pass nil to clear.
    func setReadyHandler(_ handler: (@Sendable () -> Void)?)
    @discardableResult
    func send(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void) -> Bool
    /// Like `send`, but tells a temporary `.busy` (nothing sealed or sent, retry the same frame) from a real refusal
    /// (T-378). The default maps `send`'s Bool: a false is `.refused(.other)`.
    func sendResult(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void) -> VideoSendResult
}

extension VideoTransport {
    public func sendResult(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void) -> VideoSendResult {
        send(frame, completion: completion) ? .accepted : .refused(.other)
    }
}

/// Moves encoded frames from the bounded `VideoFrameQueue` to a `VideoTransport`.
///
/// Newest frame wins: the sender only pulls a frame when the transport can take it, so while the socket is
/// backed up frames stay in the 2-frame queue, where the oldest deltas are dropped and a keyframe is requested.
/// `frame_seq` is assigned here, at send time, so dropped frames never leave gaps (PROTOCOL.md section 4).
public final class VideoSender: @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        public var framesSent = 0
        public var keyframesSent = 0
        public var bytesSent = 0
        /// Frames the transport refused (invalid, e.g. over the payload limit); a keyframe was requested.
        public var framesRejected = 0
        /// T-378: frames the transport found `.busy` (temporary): kept and offered again, no keyframe requested.
        public var busyRetries = 0
        /// T-378: `framesRejected` by refusal kind (`VideoRefusal`), for the `refusal=` log field.
        public var refusals: [VideoRefusal: Int] = [:]
        public var sendFailures = 0
        /// Packed full colour (decision 0034): auxiliary frames sent (also counted in `framesSent`), their bytes, and
        /// auxiliary frames dropped because their main frame was never sent.
        public var auxFramesSent = 0
        public var auxBytesSent = 0
        public var auxDropped = 0
        public init() {}

        /// T-378: ` send_retry=<n>` and ` refusal_<kind>=<n>` since `previous`, only non-zero ones (nothing when quiet).
        /// Leading space included.
        public func retryLogFields(since previous: Counters) -> String {
            var out = ""
            let retries = busyRetries - previous.busyRetries
            if retries > 0 { out += " send_retry=\(retries)" }
            for k in VideoRefusal.allCases {
                let n = (refusals[k] ?? 0) - (previous.refusals[k] ?? 0)
                if n > 0 { out += " refusal_\(k.rawValue)=\(n)" }
            }
            return out
        }
    }

    public enum EndReason: Sendable { case queueClosed, transportFailed, cancelled }

    private let transport: VideoTransport
    private let frames: VideoFrameQueue
    private let requestKeyframe: @Sendable () -> Void
    private let requestKeyframeForRefusal: (@Sendable (VideoRefusal) -> Void)?
    private let auxFrames: VideoFrameQueue?
    private let requestAuxKeyframe: @Sendable () -> Void
    private let auxPairingDropped: (@Sendable () -> Void)?
    private let onEnded: @Sendable (EndReason) -> Void
    private let trace: (@Sendable (FrameTrace) -> Void)?
    private let clock: @Sendable () -> UInt64
    private let lock = NSLock()
    private var counters = Counters()
    private var failed = false
    private var lastKeyframeRequestNs: UInt64?
    static let keyframeRequestIntervalNs: UInt64 = 500_000_000
    private var task: Task<Void, Never>?
    /// The packed loop's wake signal (guarded by `lock`).
    private var wakeLoop: (@Sendable () -> Void)?

    /// - Parameters:
    ///   - requestKeyframe: asks the encoder for a keyframe (after a frame the transport refused).
    ///   - requestKeyframeForRefusal: T-378, optional: like `requestKeyframe` for a main-stream frame the transport
    ///     refused for good, but names the refusal kind (for the `idr_forced` log). nil: `requestKeyframe`.
    ///   - onEnded: the loop finished on its own or was stopped; called once, from the sender's task.
    ///   - trace: receives the finished `FrameTrace` of every frame whose write completed (T-070), stamped with
    ///     `clock` (must be the host clock the encoder stamps with) and its `frame_seq`. nil: no measuring, no
    ///     clock reads.
    ///   - auxFrames: packed full colour (decision 0034): the auxiliary stream's queue. The sender then writes both
    ///     streams on the one connection, main first (`PackedSendArbiter`), with a `frame_seq` per stream.
    ///   - requestAuxKeyframe: asks the auxiliary encoder for a keyframe (an auxiliary frame was dropped or refused).
    public init(transport: VideoTransport, frames: VideoFrameQueue,
                auxFrames: VideoFrameQueue? = nil,
                requestKeyframe: @escaping @Sendable () -> Void,
                requestAuxKeyframe: @escaping @Sendable () -> Void = {},
                requestKeyframeForRefusal: (@Sendable (VideoRefusal) -> Void)? = nil,
                auxPairingDropped: (@Sendable () -> Void)? = nil,
                onEnded: @escaping @Sendable (EndReason) -> Void = { _ in },
                trace: (@Sendable (FrameTrace) -> Void)? = nil,
                clock: @escaping @Sendable () -> UInt64 = { 0 }) {
        self.auxFrames = auxFrames
        self.requestAuxKeyframe = requestAuxKeyframe
        self.auxPairingDropped = auxPairingDropped
        self.trace = trace
        self.clock = clock
        self.transport = transport
        self.frames = frames
        self.requestKeyframe = requestKeyframe
        self.requestKeyframeForRefusal = requestKeyframeForRefusal
        self.onEnded = onEnded
    }

    public var currentCounters: Counters { lock.lock(); defer { lock.unlock() }; return counters }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [self] in
            let reason = await run()
            transport.setReadyHandler(nil)
            onEnded(reason)
        }
    }

    /// Stops the loop and waits for it to finish. Idempotent.
    public func stop() async {
        let t = lock.withLock { task }
        t?.cancel()
        await t?.value
    }

    /// Packed full colour loop (decision 0034): one wake signal for the transport and both queues. The main queue is
    /// served first; an auxiliary frame goes only after the main frame with its `capture_time_us` was sent, and one whose
    /// main frame was lost is dropped (with an auxiliary keyframe request). `frame_seq` counts per stream.
    private func runPacked(aux: VideoFrameQueue) async -> EndReason {
        let (ready, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        transport.setReadyHandler { signal.yield() }
        frames.setActivityHandler { signal.yield() }
        aux.setActivityHandler { signal.yield() }
        lock.withLock { wakeLoop = { signal.yield() } }
        frames.setChargesPops(true)  // T-378: a popped frame stays in the downstream reservation until settled
        aux.setChargesPops(true)
        defer {
            signal.finish()
            frames.setActivityHandler(nil)
            aux.setActivityHandler(nil)
            frames.setChargesPops(false)
            aux.setChargesPops(false)
        }
        var iterator = ready.makeAsyncIterator()
        var seqs: [UInt32] = [0, 0]
        var arbiter = PackedSendArbiter()
        var busyStreak = 0
        while !Task.isCancelled {
            if hasFailed { return .transportFailed }
            if frames.isFinished { return .queueClosed }
            if transport.canSend {
                var picked: (frame: EncodedVideoFrame, view: Int)?
                if let f = frames.tryPop() {
                    picked = (f, 0)
                } else if let f = aux.tryPop(where: { head in
                    arbiter.pick(mainAvailable: false, aux: (head.pairID, head.isCodecConfig)) != .wait
                }) {
                    if arbiter.pick(mainAvailable: false, aux: (f.pairID, f.isCodecConfig)) == .aux {
                        picked = (f, 1)
                    } else {
                        // Its main frame never went out: the auxiliary chain has a hole.
                        aux.breakChain()
                        aux.settlePop()
                        lock.withLock { counters.auxDropped += 1 }
                        // Recovery goes through the auxiliary coalescer when wired: a keyframe already queued behind
                        // the hole (kept by `breakChain`) covers it, so no extra IDR is forced.
                        (auxPairingDropped ?? requestAuxKeyframe)()
                        continue
                    }
                }
                if let (encoded, view) = picked {
                    var out = encoded
                    out.view = UInt8(view)
                    switch write(out, seq: seqs[view]) {
                    case .accepted:
                        busyStreak = 0
                        seqs[view] &+= 1
                        if view == 0, !out.isCodecConfig { arbiter.mainSent(pairID: out.pairID) }
                    case .busy:
                        // T-378: nothing was sealed or sent; the same frame goes first next time, `seq` unchanged.
                        (view == 0 ? frames : aux).unpop(encoded)
                        await busyBackoff(&busyStreak)
                    case .refused(let kind):
                        busyStreak = 0
                        if view == 1 {
                            // A transport-refused auxiliary frame is a loss like a dropped one (the fallback rule counts it).
                            lock.withLock { counters.auxDropped += 1 }
                            aux.breakChain()
                            requestAuxKeyframe()
                        } else if keyframeRequestAllowed() {
                            requestMainKeyframe(kind)
                        }
                    }
                    continue
                }
            }
            guard await iterator.next() != nil else { return .cancelled }
        }
        return .cancelled
    }

    /// Hands one frame to the transport and records it; the completion marks the sender failed on a write error.
    private func write(_ encoded: EncodedVideoFrame, seq: UInt32) -> VideoSendResult {
        let frame = encoded.toVideoFrame(seq: seq)
        let size = frame.data.count
        var timing = encoded.trace
        let measure = trace != nil && !encoded.isCodecConfig && encoded.view == 0
        if measure {
            timing.writeStartUs = clock()
            timing.frameSeq = seq
            timing.isKeyframe = encoded.isKeyframe
            timing.bytes = size
        }
        let result = transport.sendResult(frame) { [self, timing] ok in
            if !ok {
                markFailed()
                lock.withLock { wakeLoop }?()
            }
            if ok, measure, let trace {
                var done = timing
                done.writeDoneUs = clock()
                trace(done)
            }
        }
        record(result: result, bytes: size, keyframe: encoded.isKeyframe)
        // T-378: the frame leaves the downstream reservation once the transport took it or refused it for good; a busy
        // one stays charged until the caller hands it back (`unpop`).
        if result != .busy { (encoded.view == 1 ? auxFrames : frames)?.settlePop() }
        if result.isAccepted, encoded.view == 1 {
            lock.withLock { counters.auxFramesSent += 1; counters.auxBytesSent += size }
        }
        return result
    }

    /// A refused main frame asks for a keyframe (the refusal kind goes along when the owner wired it).
    private func requestMainKeyframe(_ kind: VideoRefusal) {
        if let requestKeyframeForRefusal { requestKeyframeForRefusal(kind) } else { requestKeyframe() }
    }

    /// After a busy answer the loop asks `canSend` again at once; when that keeps saying yes while the send says
    /// busy (the two gates disagreed), a short sleep keeps the retry from spinning.
    private func busyBackoff(_ streak: inout Int) async {
        streak += 1
        if streak >= 2 { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    private func run() async -> EndReason {
        if let aux = auxFrames { return await runPacked(aux: aux) }
        let (ready, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        transport.setReadyHandler { signal.yield() }
        lock.withLock { wakeLoop = { signal.yield() } }  // `write` wakes the loop on a failed completion
        frames.setChargesPops(true)  // T-378
        defer {
            signal.finish()
            frames.setChargesPops(false)
        }
        var iterator = ready.makeAsyncIterator()
        var seq: UInt32 = 0
        var busyStreak = 0
        while !Task.isCancelled {
            while !transport.canSend {
                if hasFailed { return .transportFailed }
                guard await iterator.next() != nil else { return .cancelled }
            }
            if hasFailed { return .transportFailed }
            guard let encoded = await frames.next() else {
                if Task.isCancelled { return .cancelled }
                return hasFailed ? .transportFailed : .queueClosed
            }
            switch write(encoded, seq: seq) {
            case .accepted:
                busyStreak = 0
                seq &+= 1
            case .busy:
                frames.unpop(encoded)  // T-378: kept as the queue's head; no keyframe, `seq` unchanged
                await busyBackoff(&busyStreak)
            case .refused(let kind):
                busyStreak = 0
                if keyframeRequestAllowed() { requestMainKeyframe(kind) }
            }
        }
        return .cancelled
    }

    private func record(result: VideoSendResult, bytes: Int, keyframe: Bool) {
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .accepted:
            counters.framesSent += 1
            counters.bytesSent += bytes
            if keyframe { counters.keyframesSent += 1 }
        case .busy:
            counters.busyRetries += 1
        case .refused(let kind):
            counters.framesRejected += 1
            counters.refusals[kind, default: 0] += 1
        }
    }

    private var hasFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }

    /// A refused frame asks for a keyframe, but not more often than every 500 ms.
    private func keyframeRequestAllowed() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return lock.withLock {
            if let last = lastKeyframeRequestNs, now - last < Self.keyframeRequestIntervalNs { return false }
            lastKeyframeRequestNs = now
            return true
        }
    }

    private func markFailed() {
        lock.lock()
        failed = true
        counters.sendFailures += 1
        lock.unlock()
        frames.detachConsumer()  // wakes run() if it is waiting for a frame, so it ends promptly
    }
}
