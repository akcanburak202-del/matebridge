import Foundation

/// A wait that gives up (T-325). Used on the shutdown path of the stream coordinator: a stop that never answers (a
/// stuck ScreenCaptureKit stop, a VideoToolbox flush, a sender task) must not hold the event loop forever.
///
/// The operation runs in its own unstructured task. On a timeout the caller continues at once and the operation is
/// cancelled (cooperatively) but never awaited again; whatever it holds stays leaked until it returns by itself. The
/// timer runs on a dispatch queue, not on the cooperative pool, so it fires even when that pool is busy.
public enum BoundedWait {
    public enum Outcome: Equatable, Sendable { case completed, timedOut }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Never>?
        private var early: Outcome?

        func install(_ c: CheckedContinuation<Outcome, Never>) {
            lock.lock()
            if let early { lock.unlock(); c.resume(returning: early); return }
            continuation = c
            lock.unlock()
        }

        /// First caller wins; returns whether this call decided the outcome.
        @discardableResult
        func resolve(_ outcome: Outcome) -> Bool {
            lock.lock()
            if early != nil { lock.unlock(); return false }
            early = outcome
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: outcome)
            return true
        }
    }

    /// Runs `operation`; returns `.completed` when it finished within `timeout` seconds, `.timedOut` otherwise.
    public static func run(timeout: TimeInterval,
                           _ operation: @escaping @Sendable () async -> Void) async -> Outcome {
        let gate = Gate()
        let task = Task.detached {
            await operation()
            gate.resolve(.completed)
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + max(0, timeout))
        timer.setEventHandler {
            if gate.resolve(.timedOut) { task.cancel() }
        }
        timer.resume()
        let outcome = await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in gate.install(c) }
        timer.cancel()
        return outcome
    }
}
