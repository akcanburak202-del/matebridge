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
}

extension EncoderSubmitFrame {
    public mutating func arrived(slotFree: Bool) {}
    public mutating func reserved(lastSlotFreeUs: UInt64) {}
}

/// Identifies one slot reservation. Every reservation is released exactly once (`EncoderSubmitOrder.release`).
public struct EncoderSubmitToken: Hashable, Sendable, CustomStringConvertible {
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
    public var description: String { "\(id)" }
}

/// The encoder session behind `EncoderSubmitOrder` (VideoToolbox in `HEVCEncoder`, a fake in tests).
public protocol CompressionBackend: AnyObject, Sendable {
    associatedtype Frame: EncoderSubmitFrame
    /// Submits one frame that holds the slot `token`. The backend releases the token exactly once
    /// (`EncoderSubmitOrder.release`): from its completion, or right away when the submit is refused.
    func encode(_ frame: Frame, keyframe: Bool, token: EncoderSubmitToken)
    /// The last call: completes every outstanding frame (their completions may run during the call) and closes
    /// the session.
    func completeAndInvalidate()
}

/// Decides which frame goes to the encoder session and in which order (T-162): the `FramePacer` (newest frame wins,
/// one pending frame), `maxInFlight` slots, the keyframe flag, strictly increasing stamps, the flush timer and
/// teardown. All state is guarded by one lock.
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
    /// Test seam: runs right before `backend.encode`, on the thread that calls it.
    private let beforeSubmit: (@Sendable (Frame) -> Void)?

    private let lock = NSLock()
    // Guarded by `lock`.
    private var stopped = false
    private var pacer: FramePacer<Frame>
    private var last: Frame?
    private var forceKeyframe = true          // the very first frame is a keyframe
    private var inFlight = 0
    private var nextToken: UInt64 = 0
    private var lastStamp: Frame.Stamp?
    private var lastSlotFreeUs: UInt64 = 0
    private var lastReserveUs: UInt64
    private var flushScheduled = false
    private var stats = Stats()

    public init(backend: Backend, streamFps: Int, maxInFlight: Int = 2,
                nowUs: @escaping @Sendable () -> UInt64,
                scheduleFlush: @escaping FlushScheduler = EncoderSubmitOrder.defaultFlushScheduler(),
                pacerCounts: @escaping PacerCounts = { _, _, _ in },
                log: @escaping LogSink = { _, _, _ in },
                beforeSubmit: (@Sendable (Frame) -> Void)? = nil) {
        self.backend = backend
        self.maxInFlight = maxInFlight
        self.nowUs = nowUs
        self.scheduleFlush = scheduleFlush
        self.pacerCounts = pacerCounts
        self.log = log
        self.beforeSubmit = beforeSubmit
        pacer = FramePacer<Frame>(streamFps: streamFps)
        lastReserveUs = nowUs()
    }

    private struct Submit {
        var frame: Frame
        var keyframe: Bool
        var token: EncoderSubmitToken
    }

    // MARK: - Callers

    /// Offers a frame. `build` runs under the lock with the last offered frame and returns the frame to offer (nil:
    /// nothing), so a re-submission of `last` can never replace a newer capture. `build` must not call back into
    /// this object. `bypassGate`: keyframe re-submissions do not wait for the send-rate slot.
    public func offer(bypassGate: Bool, build: (_ last: Frame?) -> Frame?) {
        lock.lock()
        guard !stopped, var frame = build(last) else { lock.unlock(); return }
        let slotFree = inFlight < maxInFlight
        frame.arrived(slotFree: slotFree)
        last = frame
        var submit: Submit?
        var delay: UInt64?
        // The pacer decides: send now, hold as the single pending frame (newest wins), or drop a stale one.
        switch pacer.offer(frame, ptsUs: frame.gateUs, nowUs: nowUs(), slotFree: slotFree, bypassGate: bypassGate) {
        case .submit(let f): submit = reserveLocked(f)
        case .hold(let retryAfterUs): if let r = retryAfterUs { delay = scheduleFlushLocked(afterUs: r) }
        case .drop: break
        }
        reportPacerLocked()
        lock.unlock()
        perform(submit: submit, delay: delay)
    }

    /// The next submitted frame will be a keyframe.
    public func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    /// Target send rate (T-058); see `FramePacer.setTargetFps`.
    public func setTargetFps(_ fps: Int) {
        lock.lock(); pacer.setTargetFps(fps); lock.unlock()
    }

    /// Releases the slot of `token` (the frame produced output, none, or was refused) and starts the pending frame,
    /// if any. `failed`: the frame broke the reference chain, so the next frame is a keyframe.
    public func release(_ token: EncoderSubmitToken, failed: Bool) {
        lock.lock()
        if failed { forceKeyframe = true }
        inFlight -= 1
        stats.releases += 1
        noteInFlightLocked()
        lastSlotFreeUs = nowUs()
        let (submit, delay) = takePendingLocked()
        lock.unlock()
        perform(submit: submit, delay: delay)
    }

    /// Flush timer: claims the pending frame if a slot is free and the gate is open.
    public func flushPending() {
        lock.lock()
        flushScheduled = false
        let (submit, delay) = takePendingLocked()
        lock.unlock()
        perform(submit: submit, delay: delay)
    }

    /// Stops accepting frames and tears the backend down. Idempotent. `completion` runs once the backend is closed.
    public func stop(completion: (@Sendable () -> Void)? = nil) {
        lock.lock()
        if stopped { lock.unlock(); completion?(); return }
        stopped = true
        pacer.clearPending()
        last = nil
        lock.unlock()
        backend.completeAndInvalidate()
        completion?()
    }

    // MARK: - Readers

    public var isStopped: Bool { lock.withLock { stopped } }
    /// The last offered frame (what a re-submission re-encodes); nil once stopped.
    public var lastOffered: Frame? { lock.withLock { stopped ? nil : last } }
    public var currentInFlight: Int { lock.withLock { inFlight } }
    public var currentStats: Stats { lock.withLock { stats } }

    /// A keyframe is requested, a frame to re-encode exists and nothing was submitted for `idleUs`.
    public func keyframeDue(idleUs: UInt64) -> Bool {
        lock.withLock {
            !stopped && forceKeyframe && last != nil && nowUs() &- lastReserveUs >= idleUs
        }
    }

    // MARK: - Internals

    /// Carries out a decision after the lock is released.
    private func perform(submit: Submit?, delay: UInt64?) {
        if let delay { armFlush(delay) }
        if let s = submit {
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
        var f = input
        f.reserved(lastSlotFreeUs: lastSlotFreeUs)
        if let l = lastStamp, f.stamp <= l { f.stamp = Frame.stamp(after: l) }
        lastStamp = f.stamp
        lastReserveUs = nowUs()
        let key = forceKeyframe
        forceKeyframe = false
        return Submit(frame: f, keyframe: key, token: EncoderSubmitToken(id: nextToken))
    }

    /// Must hold `lock`. Claims the pending frame if a slot is free and the gate is open (judged by the current time,
    /// not the frame's capture time); otherwise returns the delay after which a flush should retry.
    private func takePendingLocked() -> (Submit?, UInt64?) {
        guard !stopped else { return (nil, nil) }
        defer { reportPacerLocked() }
        switch pacer.takePending(nowUs: nowUs(), slotFree: inFlight < maxInFlight) {
        case .submit(let f): return (reserveLocked(f), nil)
        case .retry(let wait): return (nil, scheduleFlushLocked(afterUs: wait))
        case .none: return (nil, nil)
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
