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

/// What a completed input release left behind (T-325 review round 3).
public struct InputReleaseReport: Equatable, Sendable {
    /// Closing events still owed (posting kept failing).
    public var owed: Int
    /// The held-input mirror lists nothing.
    public var mirrorEmpty: Bool

    public init(owed: Int, mirrorEmpty: Bool) {
        self.owed = owed
        self.mirrorEmpty = mirrorEmpty
    }
}

/// The restart rule (round 3): the process may only leave when nothing is held, confirmed. Anything else keeps the host
/// alive in refuse-sessions mode and is rechecked, because a stuck key on the user's only display is worse than a
/// stalled host.
public enum StallRestartDecision: Equatable, Sendable {
    case restart
    case skip(reason: String)

    /// `report` is nil when the release did not complete within its bound.
    public static func decide(report: InputReleaseReport?) -> StallRestartDecision {
        guard let report else { return .skip(reason: "input_wedged") }
        if report.owed > 0 { return .skip(reason: "owed") }
        if !report.mirrorEmpty { return .skip(reason: "input_held") }
        return .restart
    }
}

/// At most one outstanding run of a blocking body. A call while an earlier one still hangs waits for that one instead of
/// starting another, so retries never pile up blocked threads.
public final class SingleFlight<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false
    private var done = DispatchSemaphore(value: 0)
    private var result: T?

    public init() {}

    /// Runs `body` (or joins the one still running) and waits up to `timeout`; nil on a timeout.
    public func run(timeout: TimeInterval, _ body: @escaping @Sendable () -> T) -> T? {
        let (sem, start): (DispatchSemaphore, Bool) = lock.withLock {
            if inFlight { return (done, false) }
            inFlight = true
            result = nil
            done = DispatchSemaphore(value: 0)
            return (done, true)
        }
        if start {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let r = body()
                lock.withLock { result = r; inFlight = false }
                sem.signal()
            }
        }
        guard sem.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { result }
    }
}

/// One input release at a time (see `SingleFlight`).
public final class ReleaseAttempt: @unchecked Sendable {
    public static let shared = ReleaseAttempt()
    private let flight = SingleFlight<InputReleaseReport>()
    public init() {}

    public func run(timeout: TimeInterval, _ body: @escaping @Sendable () -> InputReleaseReport) -> InputReleaseReport? {
        flight.run(timeout: timeout, body)
    }
}

/// One best-effort emergency release at a time (round 4): a hung one is joined by later retries. The inner value is the
/// number of posted events, nil when posting was not possible.
public final class EmergencyAttempt: @unchecked Sendable {
    public static let shared = EmergencyAttempt()
    private let flight = SingleFlight<Int?>()
    public init() {}

    /// nil: still running after `timeout`. `.some(nil)`: it finished but could not post.
    public func run(timeout: TimeInterval, _ body: @escaping @Sendable () -> Int?) -> Int?? {
        flight.run(timeout: timeout, body)
    }
}

/// The last resort of the coordinator watchdog (T-325): input is released and verified before anything else; only a
/// confirmed release (completed, nothing owed, mirror empty) permits an orderly terminate and the relaunch, with a
/// forced exit if the process is still alive after the terminate bound. Otherwise nothing is terminated (outcome
/// `skipped`) and the caller rechecks later. The steps are injected so the order is testable.
public enum StallRestart {
    public struct Steps: Sendable {
        /// Synchronous: release everything held, drain the owed releases, report what is left
        /// (`InputController.stallRelease`). May hang if the input queue is wedged, so it is waited for with a bound.
        public var releaseInput: @Sendable () -> InputReleaseReport
        /// Starts the helper that opens a new instance once this process is gone.
        public var scheduleRelaunch: @Sendable () -> Void
        /// Asks the main thread for an orderly terminate (`NSApp.terminate`); returns at once.
        public var requestTerminate: @Sendable () -> Void
        /// Best effort only, tried when the release did not complete: posts closing events from the held-input mirror
        /// from its own thread. Its result is logged and never counts as confirmation.
        public var emergencyRelease: @Sendable () -> Int?
        public var forceExit: @Sendable () -> Void
        /// Log fields only.
        public var log: @Sendable (String) -> Void

        public init(releaseInput: @escaping @Sendable () -> InputReleaseReport,
                    scheduleRelaunch: @escaping @Sendable () -> Void,
                    requestTerminate: @escaping @Sendable () -> Void,
                    emergencyRelease: @escaping @Sendable () -> Int? = { nil },
                    forceExit: @escaping @Sendable () -> Void,
                    log: @escaping @Sendable (String) -> Void) {
            self.releaseInput = releaseInput
            self.scheduleRelaunch = scheduleRelaunch
            self.requestTerminate = requestTerminate
            self.emergencyRelease = emergencyRelease
            self.forceExit = forceExit
            self.log = log
        }
    }

    public static let inputTimeout: TimeInterval = 1.5
    public static let emergencyTimeout: TimeInterval = 1
    public static let terminateTimeout: TimeInterval = 4
    /// How often a skipped restart is tried again.
    public static let retryIntervalUs: UInt64 = 5_000_000

    public enum Outcome: Equatable, Sendable {
        /// The process was asked to terminate (and force-exited if it did not).
        case restarted
        /// Input could not be confirmed released: nothing was terminated or exited, the host stays up.
        case skipped(reason: String)
    }

    /// Blocks the calling (watchdog) thread: up to `inputTimeout` for the release; if it did not complete, a best-effort
    /// emergency release (bounded). Then the decision: only a confirmed release restarts, up to `terminateTimeout` for
    /// the process to disappear.
    @discardableResult
    public static func run(_ steps: Steps, attempt: ReleaseAttempt = .shared,
                           emergencyAttempt: EmergencyAttempt = .shared,
                           inputTimeout: TimeInterval = inputTimeout,
                           emergencyTimeout: TimeInterval = emergencyTimeout,
                           terminateTimeout: TimeInterval = terminateTimeout) -> Outcome {
        let report = attempt.run(timeout: inputTimeout, steps.releaseInput)
        if report == nil {
            switch emergencyAttempt.run(timeout: emergencyTimeout, steps.emergencyRelease) {
            case .some(.some(let n)): steps.log("input=emergency released=\(n) confirmed=0")
            default: steps.log("input=emergency failed=1 confirmed=0")
            }
        }
        switch StallRestartDecision.decide(report: report) {
        case .skip(let reason):
            steps.log("outcome=skipped reason=\(reason)")
            return .skipped(reason: reason)
        case .restart:
            steps.log("input=done outcome=restart")
        }
        steps.scheduleRelaunch()
        steps.requestTerminate()
        // A successful terminate ends the process while we wait here.
        Thread.sleep(forTimeInterval: terminateTimeout)
        steps.log("terminate=timeout")
        steps.forceExit()
        return .restarted
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
