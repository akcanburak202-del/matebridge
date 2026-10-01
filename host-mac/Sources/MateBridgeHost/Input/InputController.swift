import AppKit
import Foundation
import MateBridgeCore

/// Host shell around `InputPipeline` (T-023): the session's input messages go in, `CGEvent`s come out, and every
/// release-all trigger of PROTOCOL.md section 7 ends in `releaseInput` / `sessionEnded` / `shutdown` here.
///
/// Threading. The state machine is a lock-free value type that must be used from ONE serial context (T-022). That
/// context is this class's own queue: every entry point hops onto it with `queue.sync`. `SessionServer` calls the
/// handlers from its (private) session queue, so the calls arrive in protocol order and the sync hop keeps that order.
/// Blocking the session queue here is deliberate: it is the back-pressure that keeps every queue bounded (a slow poster
/// slows TCP reading, the client's own bounded queue and reconnect logic do the rest). Nothing in here ever calls back
/// into the session queue synchronously, so the hop cannot deadlock. The watchdog timer and the 1 s gate poll run on
/// the same queue.
///
/// Gating. Before every call the shell samples the environment (Accessibility permission, virtual display geometry)
/// and hands it to the pipeline, which decides. No display or no permission means input is ignored; releasing what was
/// already posted is never gated (see `InjectionPlanner`).
///
/// Logging (docs/LOGGING.md): component `input`, counts and state changes only, never coordinates or keys.
public final class InputController: @unchecked Sendable {
    public struct Status: Equatable, Sendable {
        /// Accessibility permission granted.
        public var accessibilityTrusted: Bool
        /// The virtual display exists.
        public var displayPresent: Bool
    }

    private let queue: DispatchQueue
    private let poster: MacEventPoster
    private let permission: AccessibilityChecking
    private let displays: DisplayProviding
    private let capsLock: CapsLockControlling
    private let cursor: CursorLocating
    private let logger = SessionLogger(component: "input")

    // Everything below is touched only on `queue`.
    private var pipeline: InputPipeline
    /// Both timers exist from `init` on, so a message that arrives before `start()` still has its watchdog.
    private let watchdogTimer: DispatchSourceTimer
    private let pollTimer: DispatchSourceTimer
    /// Held while a session is connected so App Nap cannot stretch the 500 ms watchdog timers.
    private var activity: NSObjectProtocol?
    private var onStatusChange: (@Sendable (Status) -> Void)?
    private var lastStatus: Status?
    private var trustedCache: (value: Bool, at: UInt64)?
    private var sessionID: UInt32 = 0
    private var configID: UInt16 = 0
    private var started = false
    private var stopped = false
    private var messages = 0
    private var eventsPosted = 0
    private var loggedDrops = InjectionPlanner.Counters()
    /// Live cursor queries of this session (T-103): count, failures, total and slowest time.
    private var cursorQueries = 0
    private var cursorQueryFailures = 0
    private var cursorQueryTotalNs: UInt64 = 0
    private var cursorQueryMaxNs: UInt64 = 0
    /// The planner's counters at session start (the live cursor counters are reported per session).
    private var sessionStartCounters = InjectionPlanner.Counters()

    /// - Parameters:
    ///   - doubleClickInterval: seconds; the system setting by default.
    public init(poster: MacEventPoster = CGEventPoster(), permission: AccessibilityChecking = SystemAccessibility(),
                displays: DisplayProviding = VirtualDisplayLocator(),
                capsLock: CapsLockControlling = SystemCapsLock(),
                cursor: CursorLocating = SystemCursor(),
                doubleClickInterval: TimeInterval = NSEvent.doubleClickInterval) {
        self.poster = poster
        self.permission = permission
        self.displays = displays
        self.capsLock = capsLock
        self.cursor = cursor
        var planner = InjectionPlanner.Configuration()
        planner.clicks.intervalUs = UInt64(max(0.05, min(doubleClickInterval, 5)) * 1_000_000)
        pipeline = InputPipeline(planner: planner)
        let queue = DispatchQueue(label: "dev.matebridge.input")
        self.queue = queue
        watchdogTimer = DispatchSource.makeTimerSource(queue: queue)
        pollTimer = DispatchSource.makeTimerSource(queue: queue)
        watchdogTimer.setEventHandler { [weak self] in self?.watchdogFired() }
        watchdogTimer.schedule(deadline: .distantFuture)
        watchdogTimer.resume()
        pollTimer.setEventHandler { [weak self] in self?.poll() }
        pollTimer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        pollTimer.resume()
    }

    deinit {
        watchdogTimer.cancel()
        pollTimer.cancel()
    }

    // MARK: Lifecycle

    /// Reports the first status and every change after it. `onStatusChange` runs on the input queue; hop to the main
    /// actor yourself. Call once. The watchdog and the 1 s gate poll do not wait for it: they run from `init`.
    public func start(onStatusChange: @escaping @Sendable (Status) -> Void) {
        queue.sync {
            guard !started, !stopped else { return }
            started = true
            self.onStatusChange = onStatusChange
            lastStatus = nil  // a poll that ran before start() must not swallow the first report
            _ = environment()  // reports the first status
            _ = cursor.location()  // the first query connects to WindowServer (milliseconds): not on the input path
        }
    }

    /// Re-samples the permission and the display now (the app calls it when its menu opens).
    public func refreshStatus() {
        queue.async { [self] in
            guard !stopped else { return }
            trustedCache = nil
            _ = environment()
        }
    }

    /// An approved session begins (`SessionServer` `sessionStarted`). A fresh machine starts latched; nothing of the
    /// previous session is carried over (PROTOCOL.md section 7).
    public func sessionStarted(sessionID: UInt32, configID: UInt16) {
        queue.sync {
            guard !stopped else { return }
            self.sessionID = sessionID
            self.configID = configID
            messages = 0
            eventsPosted = 0
            loggedDrops = pipeline.planner.counters
            cursorQueries = 0
            cursorQueryFailures = 0
            cursorQueryTotalNs = 0
            cursorQueryMaxNs = 0
            sessionStartCounters = pipeline.planner.counters
            beginActivity()
            // The user's key repeat settings as of now (System Settings > Keyboard), for this session's machine.
            var machine = pipeline.nextMachineConfiguration
            let delay = NSEvent.keyRepeatDelay, interval = NSEvent.keyRepeatInterval
            machine.keyRepeatEnabled = Self.repeatEnabled(delay: delay, interval: interval)
            machine.keyRepeatDelayUs = Self.microseconds(delay, fallback: machine.keyRepeatDelayUs)
            machine.keyRepeatIntervalUs = Self.microseconds(interval, fallback: machine.keyRepeatIntervalUs)
            pipeline.setMachineConfiguration(machine)
            let now = HostClock.nowUs()
            flush(pipeline.sessionStarted(now: now, environment: environment()), now: now)
            log(.info, "input_session_start")
            rearmWatchdog()
        }
    }

    /// The session is over (`sessionEnded`). Always releases, even if `releaseInput` was somehow not called.
    public func sessionEnded() {
        queue.sync {
            let now = HostClock.nowUs()
            let keys = pipeline.machine?.keyCounters ?? KeyCounters()  // the machine goes away with the session
            let pinchMessages = pipeline.machine?.pinchMessages ?? 0
            let events = pipeline.sessionEnded(now: now, environment: environment())
            flush(events, now: now)
            let d = pipeline.planner.counters
            log(.info, "input_session_end",
                "messages=\(messages) events=\(eventsPosted) released=\(events.count) "
                    + "key_msgs=\(keys.messages) unknown_keys=\(keys.unknown) repeats=\(keys.repeats) "
                    + "pinch_msgs=\(pinchMessages) "
                    + "cursor_queries=\(cursorQueries) cursor_query_failed=\(cursorQueryFailures) "
                    + "cursor_query_avg_us=\(cursorQueryAverageUs) cursor_query_max_us=\(cursorQueryMaxNs / 1_000) "
                    + "cursor_adopted=\(d.liveCursorAdopted - sessionStartCounters.liveCursorAdopted) "
                    + "cursor_current=\(d.liveCursorCurrent - sessionStartCounters.liveCursorCurrent) "
                    + "cursor_lag_ignored=\(d.liveCursorLagIgnored - sessionStartCounters.liveCursorLagIgnored) "
                    + "dropped_no_permission=\(d.droppedNoPermission - loggedDrops.droppedNoPermission) "
                    + "dropped_no_display=\(d.droppedNoDisplay - loggedDrops.droppedNoDisplay)")
            loggedDrops = d
            sessionID = 0
            configID = 0
            endActivity()
            rearmWatchdog()
        }
    }

    /// One message from the approved session (`SessionServer` `deliver`). Non-input messages are ignored here.
    public func deliver(_ message: Message) {
        switch message {
        case .pen, .pointerRel, .pointerAbs, .scroll, .pinch, .penGesture, .releaseAll, .bye, .key: break
        default: return
        }
        queue.sync {
            guard !stopped else { return }
            let now = HostClock.nowUs()
            var env = environment()
            messages += 1
            var unknownBefore = 0
            if case .key = message {
                env.capsLockOn = capsLock.isOn()  // sampled for keyboard messages only
                unknownBefore = pipeline.machine?.keyCounters.unknown ?? 0
            }
            if case .pointerRel = message { env.cursor = liveCursor() }  // relative moves start where the cursor is
            flush(pipeline.handle(message, now: now, environment: env), now: now)
            // Debug only, and only the numeric identity: never a character (docs/LOGGING.md).
            if let keys = pipeline.machine?.keyCounters, keys.unknown > unknownBefore {
                log(.debug, "key_unknown", "identity=\(keys.lastUnknownIdentity.map(String.init) ?? "none")")
            }
            rearmWatchdog()
        }
    }

    /// Release everything (`SessionServer` `releaseInput`): a RELEASE_ALL message, BYE, connection loss, protocol
    /// error, heartbeat silence, takeover or shutdown. Idempotent. Runs even after `shutdown`.
    public func releaseInput(_ cause: ReleaseCause) {
        queue.sync {
            let now = HostClock.nowUs()
            flush(pipeline.release(cause, now: now, environment: environment()), now: now)
            rearmWatchdog()
        }
    }

    /// Attempts and pause of the shutdown drain: a handful of retries over a few hundred milliseconds at most.
    static let shutdownDrainAttempts = 5
    static let shutdownDrainPause: TimeInterval = 0.06

    /// The host app is quitting: release, then retry whatever is still owed a few times right now (a transient
    /// failure during a normal Quit must not leave input held after the process exits), stop the timers, ignore
    /// everything after. Idempotent. When the permission is missing nothing can be posted: it does not spin, it logs.
    public func shutdown() {
        queue.sync {
            guard !stopped else { return }
            let now = HostClock.nowUs()
            let events = pipeline.shutdown(now: now, environment: environment())
            flush(events, now: now)
            let owedBeforeDrain = pipeline.owed.count
            let remaining = pipeline.drainOwed(
                attempts: Self.shutdownDrainAttempts,
                now: { HostClock.nowUs() },
                environment: { [self] in environment() },
                post: { [self] batch in
                    let result = post(batch)
                    eventsPosted += batch.count - result.failed.count
                    return result
                },
                pause: { Thread.sleep(forTimeInterval: Self.shutdownDrainPause) })
            logRecords()
            log(remaining == 0 ? .info : .warning, "input_shutdown",
                "released=\(events.count) owed_before_drain=\(owedBeforeDrain) owed=\(remaining) "
                    + "permission=\(lastStatus?.accessibilityTrusted == true ? 1 : 0)")
            stopped = true
            endActivity()
            watchdogTimer.cancel()
            pollTimer.cancel()
        }
    }

    // MARK: Queue-confined work

    /// The live cursor for a relative move (T-103), timed. nil when the query fails: the planner then goes on from the
    /// last known position. Never logged: only counts and times are.
    private func liveCursor() -> DisplayPoint? {
        let start = DispatchTime.now().uptimeNanoseconds
        let location = cursor.location()
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start
        cursorQueries += 1
        cursorQueryTotalNs &+= elapsed
        cursorQueryMaxNs = max(cursorQueryMaxNs, elapsed)
        if location == nil { cursorQueryFailures += 1 }
        return location
    }

    /// Mean time of this session's live cursor queries, in microseconds with two decimals.
    private var cursorQueryAverageUs: String {
        guard cursorQueries > 0 else { return "0" }
        return String(format: "%.2f", Double(cursorQueryTotalNs) / Double(cursorQueries) / 1_000)
    }

    /// macOS has no explicit "off" value that could be confirmed here; the UI slider's far end and the `KeyRepeat` /
    /// `InitialKeyRepeat` defaults can be set to huge values that mean "off", which `NSEvent.keyRepeatDelay/Interval`
    /// report as seconds in the thousands. Anything of 10 s or more (or not a finite number) is treated as off, and
    /// repeat is then never armed. To confirm on the real Mac (T-032 handoff).
    static func repeatEnabled(delay: TimeInterval, interval: TimeInterval) -> Bool {
        delay.isFinite && interval.isFinite && delay < 10 && interval < 10
    }

    /// Seconds to microseconds for a repeat setting; the fallback when the system reports nonsense.
    private static func microseconds(_ seconds: TimeInterval, fallback: UInt64) -> UInt64 {
        guard seconds.isFinite, seconds > 0.01, seconds < 10 else { return fallback }
        return UInt64(seconds * 1_000_000)
    }

    /// Posts one batch through the poster seam. A batch that releases something gets a fresh permission check first:
    /// the 200 ms cache must not let a release go out after the permission is gone and be forgotten, and nothing can be
    /// posted without it. Returns what could not be posted and whether the reason was anything but the permission.
    private func post(_ events: [MacEvent]) -> (failed: [MacEvent], permitted: Bool) {
        guard !events.isEmpty else { return ([], true) }
        if events.contains(where: \.isClosing), !permission.isTrusted() {
            trustedCache = (false, HostClock.nowUs())
            return (events, false)
        }
        return (poster.post(events), true)
    }

    /// Posts what the pipeline produced, tells the pipeline what could not be posted (closing events among those are
    /// owed and retried until they are posted), and logs the releases the pipeline did.
    private func flush(_ events: [MacEvent], now: UInt64) {
        let result = post(events)
        eventsPosted += events.count - result.failed.count
        if !result.failed.isEmpty {
            pipeline.postFailed(result.failed, now: now, permitted: result.permitted)
            let closing = result.failed.filter(\.isClosing).count
            log(.warning, "input_post_failed",
                "events=\(result.failed.count) closing=\(closing) permitted=\(result.permitted ? 1 : 0) owed=\(pipeline.owed.count)")
        }
        logRecords()
    }

    /// One `input_release` line per release the pipeline recorded: cause and counts, never coordinates.
    private func logRecords() {
        // State changes only (a pinch the host had to end itself), never coordinates.
        for cause in pipeline.takePinchForcedEnds() { log(.info, "pinch_forced_end", "cause=\(cause.rawValue)") }
        for record in pipeline.takeReleaseRecords() {
            let level: LogLevel = record.cause == .gateLost || record.slowed > 0 || record.reason == "owed_replay" ? .warning
                : (record.events > 0 ? .info : .debug)
            log(level, "input_release", record.logFields)
        }
    }

    /// The gate right now; reports a change of permission or display (once per change).
    private func environment() -> InjectionEnvironment {
        let trusted = isTrusted()
        let geometry = displays.geometry()
        let status = Status(accessibilityTrusted: trusted, displayPresent: geometry != nil)
        if status != lastStatus {
            lastStatus = status
            log(.info, "input_gate", "accessibility=\(trusted ? 1 : 0) display=\(geometry != nil ? 1 : 0)")
            // What is online, with active and mirror state, at every change: live evidence for the display lookup.
            if geometry == nil, sessionID != 0 {
                // The video pipeline makes the display right after ACCEPTED, so this is normal for a moment. If it
                // stays, the vendor/product lookup may be wrong: this line says what is online instead.
                log(.warning, "input_display_missing", displays.describeOnlineDisplays())
            } else {
                log(.info, "input_displays", displays.describeOnlineDisplays())
            }
            onStatusChange?(status)
        }
        return InjectionEnvironment(canInject: trusted, geometry: geometry)
    }

    /// The permission with a 200 ms cache, so a burst of messages costs one system call.
    private func isTrusted() -> Bool {
        let now = HostClock.nowUs()
        if let c = trustedCache, now >= c.at, now - c.at < 200_000 { return c.value }
        let value = permission.isTrusted()
        trustedCache = (value, now)
        return value
    }

    /// Re-arms the one-shot watchdog timer for `nextDeadline(now:)`. Called after every entry point that can change
    /// the machine, so an armed watchdog always has a timer.
    private func rearmWatchdog() {
        guard !stopped else { return }
        let now = HostClock.nowUs()
        var next = pipeline.nextDeadline(now: now)
        // An owed release is retried when it is due, not only at the next poll, while the permission is there.
        if lastStatus?.accessibilityTrusted == true, let retry = pipeline.nextOwedRetry {
            next = Swift.min(next ?? retry, retry)
        }
        guard let due = next else {
            watchdogTimer.schedule(deadline: .distantFuture)
            return
        }
        let delayUs = due > now ? min(due - now, 3_600_000_000) : 0
        watchdogTimer.schedule(deadline: .now() + .microseconds(Int(delayUs)), leeway: .milliseconds(1))
    }

    /// Keeps App Nap from stretching the watchdog timers while a session is connected. The reason string is shown in
    /// Activity Monitor's energy tab; it contains nothing about the session.
    private func beginActivity() {
        endActivity()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "MateBridge input session")
    }

    private func endActivity() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
    }

    private func watchdogFired() {
        guard !stopped else { return }
        let now = HostClock.nowUs()
        let events = pipeline.tick(now: now, environment: environment())
        flush(events, now: now)
        // A watchdog close (pen or scroll silent for 500 ms) is not a release-all and is not recorded as one.
        if !events.isEmpty { log(.info, "input_watchdog", "events=\(events.count)") }
        rearmWatchdog()
    }

    /// Once a second: refresh the gate (so a lost display or permission releases held input within a second even when
    /// the tablet is silent) and log any input that was dropped for lack of one.
    private func poll() {
        guard !stopped else { return }
        let now = HostClock.nowUs()
        flush(pipeline.tick(now: now, environment: environment()), now: now)
        rearmWatchdog()
        let d = pipeline.planner.counters
        let noPermission = d.droppedNoPermission - loggedDrops.droppedNoPermission
        let noDisplay = d.droppedNoDisplay - loggedDrops.droppedNoDisplay
        let owed = d.droppedOwed - loggedDrops.droppedOwed
        if noPermission > 0 || noDisplay > 0 || owed > 0 {
            log(.warning, "input_dropped", "no_permission=\(noPermission) no_display=\(noDisplay) owed=\(owed)")
            loggedDrops = d
        }
    }

    private func log(_ level: LogLevel, _ event: String, _ fields: String = "") {
        logger.log(level, event, sessionID: sessionID, generation: configID, fields: fields)
    }
}
