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
            // A stop recorded after `nowUs` was sampled is newer than `nowUs`: age 0, never a wrapped huge value.
            if let oldest = open.values.map(\.sinceUs).min() {
                let age = nowUs > oldest ? nowUs - oldest : 0
                if age >= Self.maxAgeUs { return "age_ms=\(age / 1_000)" }
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
        /// Independent of the input queue: posts the closing events of everything the held-input mirror lists. Returns
        /// how many events it posted, or nil when posting failed. Only called when `releaseInput` did not finish.
        public var emergencyRelease: @Sendable () -> Int?
        public var forceExit: @Sendable () -> Void
        /// Log fields only (`input=done|pending`, `terminate=...`).
        public var log: @Sendable (String) -> Void

        public init(releaseInput: @escaping @Sendable () -> Void, scheduleRelaunch: @escaping @Sendable () -> Void,
                    requestTerminate: @escaping @Sendable () -> Void,
                    emergencyRelease: @escaping @Sendable () -> Int? = { 0 },
                    forceExit: @escaping @Sendable () -> Void,
                    log: @escaping @Sendable (String) -> Void) {
            self.emergencyRelease = emergencyRelease
            self.releaseInput = releaseInput
            self.scheduleRelaunch = scheduleRelaunch
            self.requestTerminate = requestTerminate
            self.forceExit = forceExit
            self.log = log
        }
    }

    public static let inputTimeout: TimeInterval = 1.5
    public static let terminateTimeout: TimeInterval = 4

    public static let emergencyTimeout: TimeInterval = 1

    public enum Outcome: Equatable, Sendable {
        /// The process was asked to terminate (and force-exited if it did not).
        case restarted
        /// Input could not be released by any path: nothing was terminated or exited, the host stays up (and, with
        /// sessions refused, stays harmless). A stuck input on the only display is worse than a stalled host.
        case inputUnreleased
    }

    /// Blocks the calling (watchdog) thread: up to `inputTimeout` for the normal release, then (only if that did not
    /// finish) the emergency release from its own thread, then up to `terminateTimeout` for the process to disappear.
    /// Without a confirmed release the process neither terminates nor exits.
    @discardableResult
    public static func run(_ steps: Steps, inputTimeout: TimeInterval = inputTimeout,
                           emergencyTimeout: TimeInterval = emergencyTimeout,
                           terminateTimeout: TimeInterval = terminateTimeout) -> Outcome {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            steps.releaseInput()
            done.signal()
        }
        if done.wait(timeout: .now() + inputTimeout) == .success {
            steps.log("input=done")
        } else {
            // The input queue may be wedged: release from here, on a thread of our own.
            let box = EmergencyBox()
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                box.set(steps.emergencyRelease())
                finished.signal()
            }
            let completed = finished.wait(timeout: .now() + emergencyTimeout) == .success
            if completed, let n = box.value {
                steps.log("input=emergency released=\(n)")
            } else {
                steps.log("input=unreleased")
                return .inputUnreleased
            }
        }
        steps.scheduleRelaunch()
        steps.requestTerminate()
        // A successful terminate ends the process while we wait here.
        Thread.sleep(forTimeInterval: terminateTimeout)
        steps.log("terminate=timeout")
        steps.forceExit()
        return .restarted
    }

    private final class EmergencyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Int?
        func set(_ v: Int?) { lock.withLock { result = v } }
        var value: Int? { lock.withLock { result } }
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
