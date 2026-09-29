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
    private let keyframeNeeded: @Sendable () -> Void

    /// - Parameter keyframeNeeded: called (outside the lock) when a dropped delta frame requires a new keyframe.
    public init(capacity: Int = BoundedFrameQueue.defaultCapacity, keyframeNeeded: @escaping @Sendable () -> Void) {
        policy = BoundedFrameQueue(capacity: capacity)
        self.keyframeNeeded = keyframeNeeded
    }

    public func push(_ frame: EncodedVideoFrame) {
        lock.lock()
        if finished { lock.unlock(); return }
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

    public var droppedCount: Int { lock.lock(); defer { lock.unlock() }; return policy.droppedCount }

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
