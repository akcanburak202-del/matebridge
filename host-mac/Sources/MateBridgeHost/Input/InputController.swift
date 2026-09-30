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

    private let queue = DispatchQueue(label: "dev.matebridge.input")
    private let poster: MacEventPoster
    private let permission: AccessibilityChecking
    private let displays: DisplayProviding
    private let logger = SessionLogger(component: "input")

    // Everything below is touched only on `queue`.
    private var pipeline: InputPipeline
    private var watchdogTimer: DispatchSourceTimer?
    private var pollTimer: DispatchSourceTimer?
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

    /// - Parameters:
    ///   - doubleClickInterval: seconds; the system setting by default.
    public init(poster: MacEventPoster = CGEventPoster(), permission: AccessibilityChecking = SystemAccessibility(),
                displays: DisplayProviding = VirtualDisplayLocator(),
                doubleClickInterval: TimeInterval = NSEvent.doubleClickInterval) {
        self.poster = poster
        self.permission = permission
        self.displays = displays
        var planner = InjectionPlanner.Configuration()
        planner.clicks.intervalUs = UInt64(max(0.05, min(doubleClickInterval, 5)) * 1_000_000)
        pipeline = InputPipeline(planner: planner)
    }

    // MARK: Lifecycle

    /// Starts the 1 s gate poll and reports the first status. `onStatusChange` runs on the input queue; hop to the main
    /// actor yourself. Call once, before the first session.
    public func start(onStatusChange: @escaping @Sendable (Status) -> Void) {
        queue.sync {
            guard !started, !stopped else { return }
            started = true
            self.onStatusChange = onStatusChange
            let watchdog = DispatchSource.makeTimerSource(queue: queue)
            watchdog.setEventHandler { [weak self] in self?.watchdogFired() }
            watchdog.schedule(deadline: .distantFuture)
            watchdog.resume()
            watchdogTimer = watchdog
            let poll = DispatchSource.makeTimerSource(queue: queue)
            poll.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            poll.setEventHandler { [weak self] in self?.poll() }
            poll.resume()
            pollTimer = poll
            _ = environment()  // reports the first status
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
            let events = pipeline.sessionEnded(now: now, environment: environment())
            flush(events, now: now)
            let d = pipeline.planner.counters
            log(.info, "input_session_end",
                "messages=\(messages) events=\(eventsPosted) released=\(events.count) "
                    + "dropped_no_permission=\(d.droppedNoPermission - loggedDrops.droppedNoPermission) "
                    + "dropped_no_display=\(d.droppedNoDisplay - loggedDrops.droppedNoDisplay)")
            loggedDrops = d
            sessionID = 0
            configID = 0
            rearmWatchdog()
        }
    }

    /// One message from the approved session (`SessionServer` `deliver`). Non-input messages are ignored here.
    public func deliver(_ message: Message) {
        switch message {
        case .pen, .pointerRel, .pointerAbs, .scroll, .penGesture, .releaseAll, .bye, .key: break
        default: return
        }
        queue.sync {
            guard !stopped else { return }
            let now = HostClock.nowUs()
            let env = environment()
            messages += 1
            flush(pipeline.handle(message, now: now, environment: env), now: now)
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

    /// The host app is quitting: release, stop the timers, ignore everything after. Idempotent.
    public func shutdown() {
        queue.sync {
            guard !stopped else { return }
            let now = HostClock.nowUs()
            let events = pipeline.shutdown(now: now, environment: environment())
            flush(events, now: now)
            log(.info, "input_shutdown", "released=\(events.count) owed=\(pipeline.owed.count)")
            stopped = true
            watchdogTimer?.cancel()
            pollTimer?.cancel()
            watchdogTimer = nil
            pollTimer = nil
        }
    }

    // MARK: Queue-confined work

    /// Posts what the pipeline produced, tells the pipeline what could not be posted (closing events among those are
    /// kept and retried), and logs the releases the pipeline did.
    private func flush(_ events: [MacEvent], now: UInt64) {
        if !events.isEmpty {
            var failed: [MacEvent] = []
            var permitted = true
            // A batch that releases something is worth a fresh permission check: the 200 ms cache must not let a
            // release go out after the permission is gone and be forgotten. Nothing can be posted without it.
            if events.contains(where: \.isClosing), !permission.isTrusted() {
                trustedCache = (false, HostClock.nowUs())
                failed = events
                permitted = false
            } else {
                failed = poster.post(events)
            }
            eventsPosted += events.count - failed.count
            if !failed.isEmpty {
                pipeline.postFailed(failed, now: now, permitted: permitted)
                let closing = failed.filter(\.isClosing).count
                log(.warning, "input_post_failed", "events=\(failed.count) closing=\(closing) permitted=\(permitted ? 1 : 0)")
            }
        }
        for record in pipeline.takeReleaseRecords() {
            let level: LogLevel = record.cause == .gateLost || record.gaveUp > 0 || record.reason == "owed_replay" ? .warning
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
        guard !stopped, let timer = watchdogTimer else { return }
        let now = HostClock.nowUs()
        guard let due = pipeline.nextDeadline(now: now) else {
            timer.schedule(deadline: .distantFuture)
            return
        }
        let delayUs = due > now ? min(due - now, 3_600_000_000) : 0
        timer.schedule(deadline: .now() + .microseconds(Int(delayUs)), leeway: .milliseconds(1))
    }

    private func watchdogFired() {
        guard !stopped else { return }
        let now = HostClock.nowUs()
        flush(pipeline.tick(now: now, environment: environment()), now: now)
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
        if noPermission > 0 || noDisplay > 0 {
            log(.warning, "input_dropped", "no_permission=\(noPermission) no_display=\(noDisplay)")
            loggedDrops = d
        }
    }

    private func log(_ level: LogLevel, _ event: String, _ fields: String = "") {
        logger.log(level, event, sessionID: sessionID, generation: configID, fields: fields)
    }
}
