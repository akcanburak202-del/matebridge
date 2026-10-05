import Foundation

/// Thread-safe async wrapper around `BoundedFrameQueue`: the sink side of the video pipeline.
/// One consumer awaits `next()`. It returns nil after `finish()`, `detachConsumer()` or task cancellation,
/// and never leaves a stale waiter behind, so a later consumer can attach.
public final class VideoFrameQueue: @unchecked Sendable {
    private final class Token: @unchecked Sendable { var cancelled = false }

    private let lock = NSLock()
    private var policy: BoundedFrameQueue
    private var waiter: (token: Token, cont: CheckedContinuation<EncodedVideoFrame?, Never>)?
    private var finished = false
    private var pushedKeyframes: UInt64 = 0
    private let keyframeNeeded: @Sendable () -> Void

    /// - Parameter keyframeNeeded: called (outside the lock) when a dropped delta frame requires a new keyframe. It
    ///   only says that one is needed; when to force it is the caller's decision (T-176: `KeyframeRequestCoalescer.hostDrop`
    ///   with `keyframeState`), and deltas stay refused until a keyframe is pushed.
    public init(capacity: Int = BoundedFrameQueue.defaultCapacity, keyframeNeeded: @escaping @Sendable () -> Void) {
        policy = BoundedFrameQueue(capacity: capacity)
        self.keyframeNeeded = keyframeNeeded
    }

    /// T-258: called (outside the lock) after every push and after `finish()`, so a consumer that polls two queues
    /// (`tryPop`, the packed full colour sender) can wake. Not used by the awaiting consumer.
    public func setActivityHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { activity = handler }
    }
    private var activity: (@Sendable () -> Void)?

    /// Next frame without waiting (nil when empty).
    public func tryPop() -> EncodedVideoFrame? { lock.withLock { policy.pop() } }

    /// The head frame without removing it.
    public func peek() -> EncodedVideoFrame? { lock.withLock { policy.first } }

    /// Removes and returns the head frame only when `accept` says so (decided under the queue lock, so the frame
    /// judged is the frame removed). `accept` must be quick and must not call back into this queue.
    public func tryPop(where accept: (EncodedVideoFrame) -> Bool) -> EncodedVideoFrame? {
        lock.withLock {
            guard let head = policy.first, accept(head) else { return nil }
            return policy.pop()
        }
    }

    public var hasFrames: Bool { lock.withLock { !policy.isEmpty } }

    public var isFinished: Bool { lock.withLock { finished } }

    /// `BoundedFrameQueue.breakChain`: the caller dropped a frame the queue had handed out.
    public func breakChain() { lock.withLock { policy.breakChain() } }

    public func push(_ frame: EncodedVideoFrame) {
        lock.lock()
        if finished { lock.unlock(); return }
        if frame.isKeyframe { pushedKeyframes &+= 1 }
        policy.push(frame)
        let request = policy.takeKeyframeRequest()
        var handoff: (CheckedContinuation<EncodedVideoFrame?, Never>, EncodedVideoFrame)?
        if let w = waiter, let f = policy.pop() {
            waiter = nil
            handoff = (w.cont, f)
        }
        let notify = activity
        lock.unlock()
        handoff.map { $0.0.resume(returning: $0.1) }
        notify?()
        if request { keyframeNeeded() }
    }

    /// Next frame, or nil after `finish()`, `detachConsumer()` or cancellation.
    public func next() async -> EncodedVideoFrame? {
        let token = Token()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<EncodedVideoFrame?, Never>) in
                lock.lock()
                if token.cancelled || finished { lock.unlock(); c.resume(returning: nil); return }
                if let f = policy.pop() { lock.unlock(); c.resume(returning: f); return }
                // A newer consumer replaces an older one instead of trapping.
                let old = waiter
                waiter = (token, c)
                lock.unlock()
                old?.cont.resume(returning: nil)
            }
        } onCancel: {
            lock.lock()
            token.cancelled = true
            var cont: CheckedContinuation<EncodedVideoFrame?, Never>?
            if let w = waiter, w.token === token { cont = w.cont; waiter = nil }
            lock.unlock()
            cont?.resume(returning: nil)
        }
    }

    /// Releases a waiting consumer (its `next()` returns nil) without ending the queue.
    public func detachConsumer() {
        lock.lock()
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.cont.resume(returning: nil)
    }

    /// Prepares for a newly attached consumer: holds only [config], deltas refused until a keyframe arrives.
    /// The caller then forces a keyframe from the encoder.
    public func startNewConsumer(config: EncodedVideoFrame?) {
        lock.lock()
        policy.startNewConsumer(config: config)
        lock.unlock()
    }

    /// Resyncs the attached consumer (see `BoundedFrameQueue.resync`). A waiting consumer receives `config` at once.
    /// The caller must force a keyframe from the encoder **after** this returns, which is what guarantees the
    /// consumer sees the config before that keyframe.
    public func resync(config: EncodedVideoFrame) {
        _ = resync(config: { config })
    }

    /// Same, but the config is read by `provider` **while the queue lock is held**. Encoder output goes through
    /// `push`, which takes the same lock, so a config the encoder announces cannot slip in between the snapshot and
    /// the reset: it is either already queued (and visible to the provider) or queued after the reset. `provider`
    /// must be quick and must not call back into this queue. Returns false, and leaves the queue untouched, when it
    /// returns nil (no parameter sets exist yet).
    @discardableResult
    public func resync(config provider: () -> EncodedVideoFrame?) -> Bool {
        resyncCountingKeyframes(config: provider).configQueued
    }

    /// Outcome of `resyncCountingKeyframes`.
    public struct ResyncResult: Equatable, Sendable {
        /// A config was queued (false: no parameter sets yet, queue untouched).
        public var configQueued: Bool
        /// `keyframesPushed` read under the same lock as the reset: every keyframe pushed later is queued behind the
        /// config (T-122).
        public var keyframesPushed: UInt64
    }

    /// `resync(config:)` that also returns the keyframe push count seen atomically with the reset.
    @discardableResult
    public func resyncCountingKeyframes(config provider: () -> EncodedVideoFrame?) -> ResyncResult {
        lock.lock()
        let pushed = pushedKeyframes
        guard let config = provider() else { lock.unlock(); return ResyncResult(configQueued: false, keyframesPushed: pushed) }
        policy.resync(config: config)
        var handoff: (CheckedContinuation<EncodedVideoFrame?, Never>, EncodedVideoFrame)?
        if !finished, let w = waiter, let f = policy.pop() {
            waiter = nil
            handoff = (w.cont, f)
        }
        lock.unlock()
        handoff.map { $0.0.resume(returning: $0.1) }
        return ResyncResult(configQueued: true, keyframesPushed: pushed)
    }

    /// Keyframes pushed so far (including ones the policy later dropped). A keyframe forced after reading this value
    /// has reached the queue once the count grows (T-122).
    public var keyframesPushed: UInt64 { lock.lock(); defer { lock.unlock() }; return pushedKeyframes }

    /// `startNewConsumer` with the config snapshot taken under the queue lock (see `resync(config:)`). Unlike
    /// `resync`, the queue is reset even when there is no config yet.
    public func startNewConsumer(configProvider: () -> EncodedVideoFrame?) {
        lock.lock()
        policy.startNewConsumer(config: configProvider())
        lock.unlock()
    }

    public var droppedCount: Int { lock.lock(); defer { lock.unlock() }; return policy.droppedCount }

    /// Every discarded frame: overflow, purge, refusal while awaiting a keyframe, `breakChain` (T-258 fallback rule).
    public var discardedCount: Int { lock.lock(); defer { lock.unlock() }; return policy.discardedCount }

    /// Keyframe-related queue state, read under one lock (T-176: input to `KeyframeRequestCoalescer.hostDrop`).
    public var keyframeState: KeyframeQueueState {
        lock.lock(); defer { lock.unlock() }
        return KeyframeQueueState(awaitingKeyframe: policy.isAwaitingKeyframe, keyframeQueued: policy.hasQueuedKeyframe,
                                  keyframesPushed: pushedKeyframes)
    }

    /// T-253: the queue holds nothing and is not waiting for a keyframe, so a still-screen refinement frame cannot
    /// overflow it (an overflow drops a delta and forces a keyframe). One lock for both facts.
    public var isReadyForRefine: Bool {
        lock.lock(); defer { lock.unlock() }
        return !finished && policy.isEmpty && !policy.isAwaitingKeyframe
    }

    public func finish() {
        lock.lock()
        finished = true
        policy.removeAll()
        let w = waiter
        waiter = nil
        let notify = activity
        lock.unlock()
        w?.cont.resume(returning: nil)
        notify?()
    }
}

/// Snapshot of the queue's keyframe state (`VideoFrameQueue.keyframeState`, T-176).
public struct KeyframeQueueState: Equatable, Sendable {
    /// Deltas are refused until a keyframe is pushed.
    public var awaitingKeyframe: Bool
    /// A keyframe waits in the queue.
    public var keyframeQueued: Bool
    /// Keyframes pushed so far (`VideoFrameQueue.keyframesPushed`).
    public var keyframesPushed: UInt64

    public init(awaitingKeyframe: Bool, keyframeQueued: Bool, keyframesPushed: UInt64) {
        self.awaitingKeyframe = awaitingKeyframe
        self.keyframeQueued = keyframeQueued
        self.keyframesPushed = keyframesPushed
    }
}
