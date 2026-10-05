import Foundation

/// A frame `EncoderSubmitOrder` hands to a `CompressionBackend` (T-162).
public protocol EncoderSubmitFrame: Sendable {
    associatedtype Stamp: Comparable & Sendable
    /// Presentation stamp given to the backend; made strictly increasing when the frame claims its slot.
    var stamp: Stamp { get set }
    /// The stamp used when a frame's own stamp does not sort after the previous one.
    static func stamp(after previous: Stamp) -> Stamp
    /// Capture time on the host clock in microseconds: the pacer's gate and staleness key.
    var gateUs: UInt64 { get }
    /// Called under the lock when the frame is offered; `slotFree`: a slot was free at arrival.
    mutating func arrived(slotFree: Bool)
    /// Called under the lock when the frame claims a slot; `lastSlotFreeUs`: host time of the last slot release.
    mutating func reserved(lastSlotFreeUs: UInt64)
    /// An optional frame (T-253 still-screen refinement) is never allowed to consume a pending keyframe request: if one
    /// is pending when the frame would claim its slot, the frame is skipped instead (nothing was encoded yet).
    var skipsOnPendingKeyframe: Bool { get }
}

extension EncoderSubmitFrame {
    public mutating func arrived(slotFree: Bool) {}
    public mutating func reserved(lastSlotFreeUs: UInt64) {}
    public var skipsOnPendingKeyframe: Bool { false }
}

/// Identifies one slot reservation. Every reservation is released exactly once (`EncoderSubmitOrder.release`).
public struct EncoderSubmitToken: Hashable, Sendable, CustomStringConvertible {
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
    public var description: String { "\(id)" }
}

/// The encoder session behind `EncoderSubmitOrder` (VideoToolbox in `HEVCEncoder`, a fake in tests). Both calls
/// arrive only on the order's owner queue, one at a time.
public protocol CompressionBackend: AnyObject, Sendable {
    associatedtype Frame: EncoderSubmitFrame
    /// Submits one frame that holds the slot `token`. The backend releases the token (`EncoderSubmitOrder.release`)
    /// from its completion, or right away when the submit is refused.
    func encode(_ frame: Frame, keyframe: Bool, token: EncoderSubmitToken)
    /// The last call: completes every outstanding frame (their completions may run during the call) and closes
    /// the session.
    func completeAndInvalidate()
    /// Changes the target bitrate of the live session (T-177). Arrives in FIFO order with `encode`, never after
    /// `completeAndInvalidate`. `kbps` is already clamped and deduplicated (`BitrateRequest`).
    func setBitrate(kbps: Int)
}

extension CompressionBackend {
    public func setBitrate(kbps: Int) {}
}

/// Live bitrate requests for one encoder session (T-177). Pure; `EncoderSubmitOrder` owns one under its lock.
/// A request is clamped to `range`, dropped when it equals the last applied value (the session starts at the
/// configured bitrate), and refused once the session is stopped.
public struct BitrateRequest: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Set the session to this value (kbps, clamped).
        case apply(Int)
        /// Equal to the value in force: nothing to do.
        case unchanged
        /// The session is stopped (or stopping): never touch it again.
        case stopped
    }

    /// Same bounds as a user `STREAM_PREFS.bitrate_kbps` (decision 0013).
    public static let defaultRange = VideoSettings.userBitrateRangeKbps

    public let range: ClosedRange<Int>
    /// The value in force (kbps); the configured bitrate until the first change.
    public private(set) var currentKbps: Int
    public private(set) var isStopped = false

    public init(initialKbps: Int, range: ClosedRange<Int> = BitrateRequest.defaultRange) {
        self.range = range
        currentKbps = initialKbps
    }

    public func clamped(_ kbps: Int) -> Int { min(max(kbps, range.lowerBound), range.upperBound) }

    public mutating func request(_ kbps: Int) -> Decision {
        guard !isStopped else { return .stopped }
        let v = clamped(kbps)
        guard v != currentKbps else { return .unchanged }
        currentKbps = v
        return .apply(v)
    }

    public mutating func stop() { isStopped = true }
}

/// `kVTCompressionPropertyKey_DataRateLimits` pairs for a bitrate (T-177). The default is the cap in use since the
/// start: `[2 x average bytes per second, 1 s]`. `shortWindowMs` (diagnostics, `MATEBRIDGE_RATE_WINDOW_MS`) adds a
/// second pair with the same 2x burst factor over a shorter window, `[2 x average bytes per second x w, w]`.
public enum RateLimitWindows {
    public struct Pair: Equatable, Sendable {
        public var bytes: Int
        /// Window length in milliseconds (1000 = the default 1 s pair).
        public var windowMs: Int
        public init(bytes: Int, windowMs: Int) { self.bytes = bytes; self.windowMs = windowMs }
    }

    public static func pairs(kbps: Int, shortWindowMs: Int?) -> [Pair] {
        let perSecond = kbps * 1000 / 8 * 2
        var p = [Pair(bytes: perSecond, windowMs: 1000)]
        if let w = shortWindowMs, w > 0, w < 1000 { p.append(Pair(bytes: perSecond * w / 1000, windowMs: w)) }
        return p
    }
}

/// Decides which frame goes to the encoder session and in which order (T-162): the `FramePacer` (newest frame wins,
/// one pending frame), `maxInFlight` slots, the keyframe flag, strictly increasing stamps, the flush timer and
/// teardown. All state is guarded by one lock.
///
/// **Single submit owner.** Every `backend.encode` and the final `backend.completeAndInvalidate` run on one serial
/// owner queue, and each block is enqueued (`async`) while the lock that reserved its slot is still held. FIFO order
/// therefore equals reservation order: stamps reach the backend strictly increasing, and the teardown block, enqueued
/// under the same lock that sets `stopped`, runs after every submit and before none. Nothing waits on the owner queue
/// with `sync`. Callers on any thread (capture, timers, the backend's completion thread) only take the lock and
/// enqueue, so `offer` never blocks on the encoder.
public final class EncoderSubmitOrder<Backend: CompressionBackend>: @unchecked Sendable {
    public typealias Frame = Backend.Frame
    /// `(afterUs, fire)`: call `fire` once after `afterUs` microseconds.
    public typealias FlushScheduler = @Sendable (_ afterUs: UInt64, _ fire: @escaping @Sendable () -> Void) -> Void
    /// Pacer counters since the last report: replaced/stale, decimated, deferred frames. Called under the lock.
    public typealias PacerCounts = @Sendable (_ overwritten: Int, _ decimated: Int, _ deferred: Int) -> Void
    public typealias LogSink = @Sendable (LogLevel, String, String) -> Void

    /// Bookkeeping for tests and diagnostics.
    public struct Stats: Sendable, Equatable {
        public var reservations = 0
        public var releases = 0
        public var duplicateReleases = 0
        public var minInFlight = 0
        public var maxInFlight = 0
        /// Bitrate apply blocks put on the owner queue (T-177).
        public var bitrateBlocksEnqueued = 0
        /// Bitrate targets that replaced a not yet applied one in a queued block.
        public var bitrateCoalesced = 0
    }

    /// The target of one queued bitrate block; written under `lock` until the block runs or a submit is queued
    /// behind it.
    private final class PendingBitrate: @unchecked Sendable {
        var kbps: Int
        init(_ kbps: Int) { self.kbps = kbps }
    }

    public static func defaultFlushScheduler() -> FlushScheduler {
        { afterUs, fire in
            DispatchQueue.global(qos: .userInteractive).asyncAfter(
                deadline: .now() + .microseconds(Int(min(afterUs, UInt64(Int32.max)))), execute: fire)
        }
    }

    public let maxInFlight: Int
    private let backend: Backend
    private let nowUs: @Sendable () -> UInt64
    private let scheduleFlush: FlushScheduler
    private let pacerCounts: PacerCounts
    private let log: LogSink
    /// Test seam: runs right before `backend.encode`, on the owner queue.
    private let beforeSubmit: (@Sendable (Frame) -> Void)?
    /// Called (outside the lock) for a frame skipped because a keyframe was pending (`skipsOnPendingKeyframe`).
    private let onSkipped: @Sendable (Frame) -> Void
    /// Frames skipped under the lock, delivered to `onSkipped` after it is released. Guarded by `lock`.
    private var skipped: [Frame] = []
    /// The single submit owner.
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    private let lock = NSLock()
    // Guarded by `lock`.
    private var stopped = false
    private var pacer: FramePacer<Frame>
    private var last: Frame?
    private var forceKeyframe = true          // the very first frame is a keyframe
    private var inFlight = 0
    private var nextToken: UInt64 = 0
    /// Reserved and not yet released (release is idempotent per token).
    private var outstanding = Set<UInt64>()
    private var lastStamp: Frame.Stamp?
    private var lastSlotFreeUs: UInt64 = 0
    private var lastReserveUs: UInt64
    private var flushScheduled = false
    private var stats = Stats()
    /// Live bitrate requests (T-177); stopped together with `stopped`.
    private var bitrate: BitrateRequest
    /// The bitrate block that is the newest block on the owner queue (nothing queued behind it yet): a new target
    /// replaces its value instead of queueing another block. Cleared when a submit is queued or the block runs.
    private var openBitrate: PendingBitrate?
    /// The last value handed to `backend.setBitrate` (or the initial one).
    private var sentBitrateKbps: Int

    /// - Parameter initialBitrateKbps: the bitrate the backend session was created with (`setBitrate` deduplicates
    ///   against it).
    public init(backend: Backend, streamFps: Int, maxInFlight: Int = 2,
                initialBitrateKbps: Int = 0,
                bitrateRange: ClosedRange<Int> = BitrateRequest.defaultRange,
                nowUs: @escaping @Sendable () -> UInt64,
                scheduleFlush: @escaping FlushScheduler = EncoderSubmitOrder.defaultFlushScheduler(),
                pacerCounts: @escaping PacerCounts = { _, _, _ in },
                log: @escaping LogSink = { _, _, _ in },
                queueLabel: String = "matebridge.encoder.submit",
                beforeSubmit: (@Sendable (Frame) -> Void)? = nil,
                onSkipped: @escaping @Sendable (Frame) -> Void = { _ in }) {
        self.onSkipped = onSkipped
        self.backend = backend
        self.maxInFlight = maxInFlight
        self.nowUs = nowUs
        self.scheduleFlush = scheduleFlush
        self.pacerCounts = pacerCounts
        self.log = log
        self.beforeSubmit = beforeSubmit
        pacer = FramePacer<Frame>(streamFps: streamFps)
        bitrate = BitrateRequest(initialKbps: initialBitrateKbps, range: bitrateRange)
        sentBitrateKbps = initialBitrateKbps
        lastReserveUs = nowUs()
        queue = DispatchQueue(label: queueLabel, qos: .userInteractive)
        queue.setSpecific(key: queueKey, value: 1)
    }

    private struct Submit: Sendable {
        var frame: Frame
        var keyframe: Bool
        var token: EncoderSubmitToken
    }

    // MARK: - Callers

    /// Offers a frame. `build` runs under the lock with the last offered frame and returns the frame to offer (nil:
    /// nothing), so a re-submission of `last` can never replace a newer capture. `build` must not call back into
    /// this object. `bypassGate`: keyframe re-submissions do not wait for the send-rate slot. Never blocks on the
    /// encoder.
    public func offer(bypassGate: Bool, build: (_ last: Frame?) -> Frame?) {
        offerChecked(bypassGate: bypassGate) { last, _ in build(last) }
    }

    /// `offer` whose `build` also sees whether a keyframe is pending (T-253: a still-screen refinement frame must not
    /// consume a keyframe request). Same lock rules as `offer`.
    public func offerChecked(bypassGate: Bool, build: (_ last: Frame?, _ keyframePending: Bool) -> Frame?) {
        lock.lock()
        guard !stopped, var frame = build(last, forceKeyframe) else { lock.unlock(); return }
        let slotFree = inFlight < maxInFlight
        frame.arrived(slotFree: slotFree)
        last = frame
        var delay: UInt64?
        // The pacer decides: send now, hold as the single pending frame (newest wins), or drop a stale one.
        switch pacer.offer(frame, ptsUs: frame.gateUs, nowUs: nowUs(), slotFree: slotFree, bypassGate: bypassGate) {
        case .submit(let f): reserveOrSkipLocked(f)
        case .hold(let retryAfterUs): if let r = retryAfterUs { delay = scheduleFlushLocked(afterUs: r) }
        case .drop: break
        }
        reportPacerLocked()
        let skippedNow = takeSkippedLocked()
        lock.unlock()
        skippedNow.forEach(onSkipped)
        if let delay { armFlush(delay) }
    }

    /// A keyframe was requested and no frame has been submitted since.
    public var keyframePending: Bool { lock.withLock { forceKeyframe } }

    /// The next submitted frame will be a keyframe.
    public func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    /// Target send rate (T-058); see `FramePacer.setTargetFps`.
    public func setTargetFps(_ fps: Int) {
        lock.lock(); pacer.setTargetFps(fps); lock.unlock()
    }

    /// Changes the live session's bitrate (T-177) without a restart. Clamped and deduplicated (`BitrateRequest`).
    /// Never blocks on the encoder.
    ///
    /// **Bounded and ordered.** An `.apply` goes onto the owner queue under the lock, like a submit, so it reaches
    /// the backend in call order with the frames and never after the teardown block. If the newest block on the
    /// owner queue is already a bitrate block (no submit queued behind it), the new target replaces that block's
    /// value instead of queueing another one; superseded targets are dropped. So at most one bitrate block sits
    /// between two submits (at most `maxInFlight + 1` in all), however fast requests arrive while the queue is
    /// stalled. When the block runs it skips a value equal to the one last sent (e.g. 60 -> 15 -> 60 coalesced).
    @discardableResult
    public func setBitrate(kbps: Int) -> BitrateRequest.Decision {
        lock.lock()
        defer { lock.unlock() }
        let decision = bitrate.request(kbps)
        guard case .apply(let v) = decision else { return decision }
        if let open = openBitrate {
            open.kbps = v
            stats.bitrateCoalesced += 1
        } else {
            let pending = PendingBitrate(v)
            openBitrate = pending
            stats.bitrateBlocksEnqueued += 1
            // Weak: like the teardown block, a queued block must not keep the order alive.
            queue.async { [weak self, backend] in
                guard let v = self?.takeBitrate(pending) else { return }
                backend.setBitrate(kbps: v)
            }
        }
        return decision
    }

    /// Owner queue: closes `pending` for further coalescing and returns its value, nil when it equals the value
    /// last sent.
    private func takeBitrate(_ pending: PendingBitrate) -> Int? {
        lock.withLock {
            if openBitrate === pending { openBitrate = nil }
            guard pending.kbps != sentBitrateKbps else { return nil }
            sentBitrateKbps = pending.kbps
            return pending.kbps
        }
    }

    /// The newest requested bitrate (kbps), or the initial value.
    public var currentBitrateKbps: Int { lock.withLock { bitrate.currentKbps } }

    /// Releases the slot of `token` (the frame produced output, none, or was refused) and starts the pending frame,
    /// if any. `failed`: the frame broke the reference chain, so the next frame is a keyframe. Idempotent per token:
    /// a second release of the same token (e.g. an encode error and a completion for one frame) is logged at
    /// `warning` and changes nothing.
    public func release(_ token: EncoderSubmitToken, failed: Bool) {
        lock.lock()
        guard outstanding.remove(token.id) != nil else {
            stats.duplicateReleases += 1
            lock.unlock()
            log(.warning, "slot_double_release", "token=\(token.id)")
            return
        }
        if failed { forceKeyframe = true }
        inFlight -= 1
        stats.releases += 1
        noteInFlightLocked()
        lastSlotFreeUs = nowUs()
        let delay = takePendingLocked()
        let skippedNow = takeSkippedLocked()
        lock.unlock()
        skippedNow.forEach(onSkipped)
        if let delay { armFlush(delay) }
    }

    /// Flush timer: submits the pending frame if a slot is free and the gate is open.
    public func flushPending() {
        lock.lock()
        flushScheduled = false
        let delay = takePendingLocked()
        let skippedNow = takeSkippedLocked()
        lock.unlock()
        skippedNow.forEach(onSkipped)
        if let delay { armFlush(delay) }
    }

    /// Stops accepting frames and tears the backend down on the owner queue, after every frame already reserved.
    /// Never blocks; safe from `deinit` and from any thread. Idempotent. `completion` runs on the owner queue once
    /// the backend is closed (also for a repeated call).
    public func stop(completion: (@Sendable () -> Void)? = nil) {
        lock.lock()
        if stopped {
            lock.unlock()
            // FIFO: the teardown block was enqueued earlier, so this runs after it.
            if let completion { queue.async(execute: completion) }
            return
        }
        stopped = true
        bitrate.stop()
        pacer.clearPending()
        last = nil
        // Captures only the backend and the completion (never `self`): reachable from an owner's `deinit`.
        queue.async { [backend] in
            backend.completeAndInvalidate()
            completion?()
        }
        lock.unlock()
    }

    // MARK: - Readers

    public var isStopped: Bool { lock.withLock { stopped } }
    /// The last offered frame (what a re-submission re-encodes); nil once stopped.
    public var lastOffered: Frame? { lock.withLock { stopped ? nil : last } }
    public var currentInFlight: Int { lock.withLock { inFlight } }
    public var currentStats: Stats { lock.withLock { stats } }
    /// The caller runs on the owner queue (waiting for teardown there would deadlock).
    public var isOnOwnerQueue: Bool { DispatchQueue.getSpecific(key: queueKey) != nil }

    /// Runs `body` on the owner queue after everything enqueued so far (tests and diagnostics; never waits).
    public func afterQueued(_ body: @escaping @Sendable () -> Void) { queue.async(execute: body) }

    /// A keyframe is requested, a frame to re-encode exists and nothing was submitted for `idleUs`.
    public func keyframeDue(idleUs: UInt64) -> Bool {
        lock.withLock {
            !stopped && forceKeyframe && last != nil && nowUs() &- lastReserveUs >= idleUs
        }
    }

    // MARK: - Internals

    /// Must hold `lock`. Enqueues the submit on the owner queue while the reservation's lock is held, so the queue
    /// sees submits in reservation order and teardown (enqueued under the same lock) after all of them.
    private func submitLocked(_ s: Submit) {
        // A later bitrate target must not move ahead of this frame: it gets its own block behind it.
        openBitrate = nil
        queue.async { [backend, beforeSubmit] in
            beforeSubmit?(s.frame)
            backend.encode(s.frame, keyframe: s.keyframe, token: s.token)
        }
    }

    /// Must hold `lock`. Claims an in-flight slot, consumes the keyframe flag and makes the stamp increase.
    private func reserveLocked(_ input: Frame) -> Submit {
        inFlight += 1
        stats.reservations += 1
        noteInFlightLocked()
        nextToken += 1
        outstanding.insert(nextToken)
        var f = input
        f.reserved(lastSlotFreeUs: lastSlotFreeUs)
        if let l = lastStamp, f.stamp <= l { f.stamp = Frame.stamp(after: l) }
        lastStamp = f.stamp
        lastReserveUs = nowUs()
        let key = forceKeyframe
        forceKeyframe = false
        return Submit(frame: f, keyframe: key, token: EncoderSubmitToken(id: nextToken))
    }

    /// Must hold `lock`. Reserves and submits `f`, unless it is an optional frame and a keyframe is pending: the
    /// request stays for the next regular frame (`reserveLocked` would hand the flag to `f`).
    private func reserveOrSkipLocked(_ f: Frame) {
        if f.skipsOnPendingKeyframe && forceKeyframe { skipped.append(f); return }
        submitLocked(reserveLocked(f))
    }

    private func takeSkippedLocked() -> [Frame] {
        if skipped.isEmpty { return [] }
        defer { skipped.removeAll() }
        return skipped
    }

    /// Must hold `lock`. Submits the pending frame if a slot is free and the gate is open (judged by the current
    /// time, not the frame's capture time); otherwise returns the delay after which a flush should retry.
    private func takePendingLocked() -> UInt64? {
        guard !stopped else { return nil }
        defer { reportPacerLocked() }
        switch pacer.takePending(nowUs: nowUs(), slotFree: inFlight < maxInFlight) {
        case .submit(let f): reserveOrSkipLocked(f); return nil
        case .retry(let wait): return scheduleFlushLocked(afterUs: wait)
        case .none: return nil
        }
    }

    /// Must hold `lock`. Returns the delay to arm, or nil if a flush is already scheduled.
    private func scheduleFlushLocked(afterUs: UInt64) -> UInt64? {
        if flushScheduled { return nil }
        flushScheduled = true
        return afterUs
    }

    private func armFlush(_ delayUs: UInt64) {
        scheduleFlush(delayUs) { [weak self] in self?.flushPending() }
    }

    private func reportPacerLocked() {
        let o = pacer.takeOverwritten(), d = pacer.takeDecimated(), f = pacer.takeDeferred()
        if o + d + f > 0 { pacerCounts(o, d, f) }
    }

    private func noteInFlightLocked() {
        stats.minInFlight = min(stats.minInFlight, inFlight)
        stats.maxInFlight = max(stats.maxInFlight, inFlight)
    }
}
