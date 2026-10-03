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
        lock.unlock()
        handoff.map { $0.0.resume(returning: $0.1) }
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

    /// Keyframe-related queue state, read under one lock (T-176: input to `KeyframeRequestCoalescer.hostDrop`).
    public var keyframeState: KeyframeQueueState {
        lock.lock(); defer { lock.unlock() }
        return KeyframeQueueState(awaitingKeyframe: policy.isAwaitingKeyframe, keyframeQueued: policy.hasQueuedKeyframe,
                                  keyframesPushed: pushedKeyframes)
    }

    public func finish() {
        lock.lock()
        finished = true
        policy.removeAll()
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.cont.resume(returning: nil)
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
