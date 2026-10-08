import Foundation

/// Abandoned stops (T-325 review): a capture or encoder stop that timed out keeps its blocked ScreenCaptureKit or
/// VideoToolbox work alive. One is tolerated (the host keeps working); two at once, or one unresolved for a minute,
/// escalate through the stall restart. Process-wide, because pipelines come and go.
public final class AbandonedStops: @unchecked Sendable {
    public static let shared = AbandonedStops()

    public static let maxOpen = 2
    public static let maxAgeUs: UInt64 = 60_000_000

    private let lock = NSLock()
    private var nextToken = 0
    private var open: [Int: (step: String, sinceUs: UInt64)] = [:]
    private var finishedEarly: Set<Int> = []

    public init() {}

    /// A token for a stop about to start. Its late completion may arrive before `abandon` is recorded.
    public func newToken() -> Int {
        lock.withLock { nextToken += 1; return nextToken }
    }

    /// The stop under `token` timed out. Returns the number of still unresolved abandoned stops (this one included
    /// unless it already finished meanwhile).
    @discardableResult
    public func abandon(_ token: Int, step: String, nowUs: UInt64) -> Int {
        lock.withLock {
            if finishedEarly.remove(token) == nil { open[token] = (step, nowUs) }
            return open.count
        }
    }

    /// The stop under `token` returned after all (or before `abandon` was recorded).
    public func completed(_ token: Int) {
        lock.withLock {
            if open.removeValue(forKey: token) == nil { finishedEarly.insert(token) }
        }
    }

    public var openCount: Int { lock.withLock { open.count } }

    /// Reason to restart now, if any.
    public func escalation(nowUs: UInt64) -> String? {
        lock.withLock {
            if open.count >= Self.maxOpen { return "count=\(open.count)" }
            if let oldest = open.values.map(\.sinceUs).min(), nowUs &- oldest >= Self.maxAgeUs {
                return "age_ms=\((nowUs &- oldest) / 1_000)"
            }
            return nil
        }
    }
}

/// The last resort of the coordinator watchdog (T-325): input is released before anything else, then an orderly
/// terminate is requested and the relaunch is arranged; only when the process is still alive after the terminate bound
/// does it exit by force. The steps are injected so the order is testable.
public enum StallRestart {
    public struct Steps: Sendable {
        /// Synchronous: release everything held and drain the owed releases (`InputController.shutdown`). May hang if
        /// the input queue is wedged, so it is waited for with a bound.
        public var releaseInput: @Sendable () -> Void
        /// Starts the helper that opens a new instance once this process is gone.
        public var scheduleRelaunch: @Sendable () -> Void
        /// Asks the main thread for an orderly terminate (`NSApp.terminate`); returns at once.
        public var requestTerminate: @Sendable () -> Void
        public var forceExit: @Sendable () -> Void
        /// Log fields only (`input=done|pending`, `terminate=...`).
        public var log: @Sendable (String) -> Void

        public init(releaseInput: @escaping @Sendable () -> Void, scheduleRelaunch: @escaping @Sendable () -> Void,
                    requestTerminate: @escaping @Sendable () -> Void, forceExit: @escaping @Sendable () -> Void,
                    log: @escaping @Sendable (String) -> Void) {
            self.releaseInput = releaseInput
            self.scheduleRelaunch = scheduleRelaunch
            self.requestTerminate = requestTerminate
            self.forceExit = forceExit
            self.log = log
        }
    }

    public static let inputTimeout: TimeInterval = 1.5
    public static let terminateTimeout: TimeInterval = 4

    /// Blocks the calling (watchdog) thread: up to `inputTimeout`, then up to `terminateTimeout` for the process to
    /// disappear. Never returns early on a hung input release: the restart goes on with `input=pending`.
    public static func run(_ steps: Steps, inputTimeout: TimeInterval = inputTimeout,
                           terminateTimeout: TimeInterval = terminateTimeout) {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            steps.releaseInput()
            done.signal()
        }
        let released = done.wait(timeout: .now() + inputTimeout) == .success
        steps.log("input=\(released ? "done" : "pending")")
        steps.scheduleRelaunch()
        steps.requestTerminate()
        // A successful terminate ends the process while we wait here.
        Thread.sleep(forTimeInterval: terminateTimeout)
        steps.log("terminate=timeout")
        steps.forceExit()
    }

    /// `/bin/sh` arguments of the relaunch helper: waits until `pid` is gone (at most `waitSeconds`), then opens a new
    /// instance of the bundle. If the old process is still alive after the wait nothing is opened, so a second
    /// instance never runs next to it.
    public static func relaunchArguments(pid: Int32, bundlePath: String, waitSeconds: Int = 25) -> [String] {
        let script = "i=0; while kill -0 \"$1\" 2>/dev/null; do i=$((i+1)); [ \"$i\" -gt \"$3\" ] && exit 1; sleep 1; done; "
            + "/usr/bin/open -n \"$2\""
        return ["-c", script, "sh", String(pid), bundlePath, String(waitSeconds)]
    }
}
