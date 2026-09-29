import Foundation
import MateBridgeCore

/// Thread-safe wrapper around `BoundedFrameQueue`: the sink side of the pipeline.
/// The consumer (T-014 session) awaits `next()`; `finish()` wakes it with nil.
public final class VideoFrameQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var policy: BoundedFrameQueue
    private var waiter: CheckedContinuation<EncodedVideoFrame?, Never>?
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
        if let w = waiter {
            // Consumer is idle, so the queue is empty: hand the frame over directly.
            waiter = nil
            lock.unlock()
            w.resume(returning: frame)
            return
        }
        policy.push(frame)
        let request = policy.takeKeyframeRequest()
        lock.unlock()
        if request { keyframeNeeded() }
    }

    /// Next frame, or nil after `finish()`.
    public func next() async -> EncodedVideoFrame? {
        await withCheckedContinuation { (c: CheckedContinuation<EncodedVideoFrame?, Never>) in
            lock.lock()
            if let f = policy.pop() { lock.unlock(); c.resume(returning: f); return }
            if finished { lock.unlock(); c.resume(returning: nil); return }
            precondition(waiter == nil, "single consumer only")
            waiter = c
            lock.unlock()
        }
    }

    public var droppedCount: Int { lock.lock(); defer { lock.unlock() }; return policy.droppedCount }

    public func finish() {
        lock.lock()
        finished = true
        policy.removeAll()
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: nil)
    }
}
