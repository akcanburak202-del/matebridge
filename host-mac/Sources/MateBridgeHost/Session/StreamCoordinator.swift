import Foundation
import MateBridgeCore

/// Glue between the session (T-010) and the video pipeline (T-011):
/// ACCEPTED -> virtual display + capture + HEVC -> video link, `KEYFRAME_REQUEST` -> encoder, `STATS` -> menu/log,
/// and the parked virtual display after a disconnect (`DisplayLease`, T-165): when a session ends, capture and encoder
/// stop at once and only the display is kept for the keep time (default 10 s, `MATEBRIDGE_DISPLAY_KEEP_S`); the same
/// tablet coming back gets a new pipeline on the parked display.
///
/// All events go through one bounded, ordered mailbox and are handled one at a time, so `sessionStarted`,
/// `videoAttached` and `sessionEnded` can never overtake each other even though display creation is asynchronous.
/// STATS, KEYFRAME_REQUEST and ticks are coalesced (latest wins); lifecycle events are capped, and on overflow the
/// sessions are ended via `onOverflow` instead of growing memory.
/// Methods are safe to call from any thread (they only enqueue).
public final class StreamCoordinator: @unchecked Sendable {
    public static let configID: UInt16 = 1

    private enum Event: Sendable {
        case sessionStarted(sessionID: UInt32, configID: UInt16, device: DeviceID, settings: VideoSettings,
                          base: VideoSettings, prefs: StreamPrefs?, reannounce: Bool, transport: SessionTransport)
        case sessionEnded
        case videoAttached(VideoLink)
        case keyframeRequest(KeyframeReason, KeyframeView?)
        case streamPrefs(sessionID: UInt32, StreamPrefs)
        case displayRate(sessionID: UInt32, hz: UInt16)
        case stats(Stats)
        case tick
        case pipelineFailed(id: Int, message: String, kind: PipelineFailureKind, wake: DisplayWakeReason?)
        /// T-128: the deadline of a deferred display wake passed (coalesced).
        case deferredWakeDue
        /// T-293: the Mac woke up (`did_wake`, coalesced): the pipeline breaker starts over.
        case macWoke
        case senderEnded(id: Int, VideoSender.EndReason)
        /// T-258: the auxiliary encoder failed for good (id = pipeline id).
        case packedFallback(id: Int, reason: String)
        case shutdown(done: @Sendable () -> Void)

        /// Event type for `ev=coordinator_stall` (T-325): never any content.
        var kind: String {
            switch self {
            case .sessionStarted: "sessionStarted"
            case .sessionEnded: "sessionEnded"
            case .videoAttached: "videoAttached"
            case .keyframeRequest: "keyframeRequest"
            case .streamPrefs: "streamPrefs"
            case .displayRate: "displayRate"
            case .stats: "stats"
            case .tick: "tick"
            case .pipelineFailed: "pipelineFailed"
            case .deferredWakeDue: "deferredWakeDue"
            case .macWoke: "macWoke"
            case .senderEnded: "senderEnded"
            case .packedFallback: "packedFallback"
            case .shutdown: "shutdown"
            }
        }
    }

    private enum Consumer {
        case none
        case drain(Task<Void, Never>, Task<Void, Never>)
        case sender(id: Int, VideoSender, VideoLink)
    }

    private struct ActiveSession {
        var sessionID: UInt32
        var configID: UInt16
        var deviceID: DeviceID
        /// Settings in effect (base + the tablet's latest `STREAM_PREFS`).
        var settings: VideoSettings
        /// Settings derived from the HELLO and the experiment knobs, before any `STREAM_PREFS`.
        var base: VideoSettings
        /// The `STREAM_PREFS` `settings` were derived from (remembered at start, then the latest applied); nil =
        /// none (`settings == base`). Re-applied without the game display by `game_display_failed`.
        var prefs: StreamPrefs?
        /// USB or Wi-Fi (T-088), from the session's control connection.
        var transport: SessionTransport
        /// Decision 0034: the latest applied `STREAM_PREFS` arrived in this session (false: the remembered ones).
        var prefsFromSession = false
        /// Packed full colour fell back at runtime (`ev=chroma_fallback`); retried at the next stream mode change.
        var packedFallback = false

        var fullChroma: FullChromaSession {
            FullChromaSession(prefsFromThisSession: prefsFromSession, allowed: !packedFallback)
        }

        /// `prefs` applied to `base`. The permissions default to what the host allows now; the game display fallback
        /// and the HDR fallback override one of them, a fresh `STREAM_PREFS` overrides `fullChroma`.
        func derived(from prefs: StreamPrefs, allowGameDisplay: Bool, allowHDR: Bool,
                     fullChroma override: FullChromaSession? = nil) -> VideoSettings {
            base.applying(prefs, allowGameDisplay: allowGameDisplay, allowHDR: allowHDR,
                          fullChroma: override ?? fullChroma)
        }
    }

    /// `ActiveSession.derived` with the permissions as they are now, except where a fallback turns one off.
    private func derive(_ live: ActiveSession, from prefs: StreamPrefs, allowGameDisplay: Bool? = nil,
                        allowHDR: Bool? = nil, fullChroma: FullChromaSession? = nil) -> VideoSettings {
        live.derived(from: prefs, allowGameDisplay: allowGameDisplay ?? allowsGameDisplay,
                     allowHDR: allowHDR ?? allowsHDR, fullChroma: fullChroma)
    }

    /// Menu text for the video/stats line ("" = nothing to show). Called on an arbitrary queue.
    public var onSummary: @Sendable (String) -> Void = { _ in }
    /// The stream settings of a live session changed (`STREAM_PREFS`): the session layer sends this `STREAM_CONFIG`
    /// (new `config_id`) and closes the video connection (PROTOCOL.md 3.7). Called on an arbitrary queue, before the
    /// capture and encoder are rebuilt, so a video connection that reopens early waits in the mailbox.
    public var onReconfigure: @Sendable (_ sessionID: UInt32, _ config: StreamConfig) -> Void = { _, _ in }
    /// The lifecycle mailbox overflowed: end every session (release input, BYE) so the client reconnects cleanly.
    public var onOverflow: @Sendable () -> Void = {}

    private static let tickKey = 1, statsKey = 2, keyframeKey = 3, deferredWakeKey = 4, macWokeKey = 5
    /// After a deferred display wake (T-128), how long the rebuild waits for the displays to power on.
    private static let retryAfterDeferredWakeUs: UInt64 = 500_000

    private static func wallMs() -> UInt64 { UInt64(max(0, Date().timeIntervalSince1970) * 1_000) }

    /// Clock of the display lease (T-165): continuous, so it keeps counting while the Mac sleeps and the keep time is
    /// wall time (`HostClock` is mach absolute time and stops in sleep). `CLOCK_MONOTONIC_RAW` is
    /// `mach_continuous_time` on Darwin.
    private static func leaseNowUs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000 }

    /// Sleeps until `deadlineUs` on the host clock (no-op if it has passed).
    private func sleep(until deadlineUs: UInt64) async {
        let now = HostClock.nowUs()
        guard deadlineUs > now else { return }
        // An intentional back-off, not a stall (T-325): the watchdog does not count it.
        watchdogLock.withLock { watchdog.pause(nowUs: HostClock.nowUs()) }
        try? await Task.sleep(nanoseconds: (deadlineUs - now) * 1_000)
        watchdogLock.withLock { watchdog.resume(nowUs: HostClock.nowUs()) }
    }
    private static func prefsKey(_ sessionID: UInt32) -> Int { (1 << 40) + Int(sessionID) }
    private static func displayRateKey(_ sessionID: UInt32) -> Int { (2 << 40) + Int(sessionID) }

    private let logger = SessionLogger(component: "net")
    private let videoLogger = SessionLogger(component: "video")
    private let mailbox = BoundedMailbox<Event>(capacity: 16)
    private let shutdownLock = NSLock()
    private var shuttingDown = false
    private var loop: Task<Void, Never>?
    private var tickTimer: DispatchSourceTimer?

    /// T-325: stall detector of the event loop. Touched from the loop (begin/end/pause) and from `watchdogTimer` (poll),
    /// which runs on its own queue so it still fires when the loop is stuck.
    private let watchdogLock = NSLock()
    private var watchdog = CoordinatorWatchdog()
    private var watchdogTimer: DispatchSourceTimer?
    /// Last resort of the watchdog (stall of `CoordinatorWatchdog.restartUs`): the app should end its sessions and
    /// relaunch or quit cleanly. Default: `defaultStallRestart`. Called on the watchdog queue.
    public var onStallRestart: (@Sendable () -> Void)?
    /// Bound of every wait in the stop path (T-325); past it `ev=consumer_stop_timeout` / `ev=pipeline_stop_timeout`.
    static let stopTimeout: TimeInterval = 2

    // Event-loop state (only touched from `handle`).
    private var lease: DisplayLease
    private var pipeline: VideoPipeline?
    private var pipelineID = 0
    /// T-165: the virtual display kept after a session end, with no capture or encoder; `sinceUs` on the lease clock.
    /// Never set together with `pipeline`. Set and used by `perform` (park, unpark, teardown); `onVideoAttached` and
    /// `onShutdown` only clear a leftover one (rebuild on it, or invalidate).
    private var parked: (display: VirtualDisplay, sinceUs: UInt64)?
    private var consumer = Consumer.none
    private var consumerID = 0
    private var session: ActiveSession?
    private var lastSent = VideoSender.Counters()
    /// T-289: bounded rebuilds after a running pipeline died, and the HDR10 to SDR fallback after repeated encoder failures.
    private var retryPolicy = PipelineRetryPolicy()
    private var lastStatsText = ""
    private var lastCadenceText = ""
    /// T-187: the hardware-encoder read-back of pipeline `pipelineID`, read once when it started.
    private var encoderHardware: (pipelineID: Int, check: EncoderHardwareCheck)?
    private var prefsGate = StreamPrefsGate()
    /// Tablet panel rate from `DISPLAY_RATE` (T-058), and the last (hz, effective fps) that was logged.
    private var rateState = DisplayRateState()
    private var lastLoggedRate: (hz: Int, fps: Int)?
    /// T-081: wakes the displays when the pipeline loses its display to display sleep during a session.
    private var wakePolicy = DisplayWakePolicy()
    private let waker = DisplayWaker()
    /// T-128: no display wake while the system goes to sleep. Shared by the power observer's queue and the event loop.
    private let gateLock = NSLock()
    private var sleepGate = SleepWakeGate()
    private var powerObserver: SystemPowerObserver?
    /// T-128: no idle display sleep while a session is accepted.
    private let displaySleep = DisplaySleepAssertion()
    /// Session id of the live session as seen by the entry points (any thread); nil between sessions.
    private let liveSessionLock = NSLock()
    private var liveSessionID: UInt32?

    private let prefsStore: StreamPrefsStoring
    /// T-214: after a 1x game display failed to come up, no game display for the rest of the process (PROTOCOL.md
    /// 0x05, `game_display_failed`). Read by the entry points (any thread) and the event loop.
    private let gameDisplayLock = NSLock()
    private var gameDisplay = GameDisplayFallback()
    private var allowsGameDisplay: Bool { gameDisplayLock.withLock { gameDisplay.allowsGameDisplay } }
    /// T-237: after an HDR10 ring failed at pipeline start, no HDR for the rest of the process (decision 0032,
    /// `ev=hdr_fallback`). Read by the entry points (any thread) and the event loop.
    private let hdrLock = NSLock()
    private var hdrFallback = HDRFallback()
    private var allowsHDR: Bool { hdrLock.withLock { hdrFallback.allowsHDR } }
    /// T-214 review: the config each tablet was told at HELLO, checked at activation (`AnnouncedStreamConfigs`).
    private let announcedLock = NSLock()
    private var announced = AnnouncedStreamConfigs()

    /// - Parameter graceUs: keep time of a parked display; nil reads `MATEBRIDGE_DISPLAY_KEEP_S` (default 10 s).
    public convenience init(graceUs: UInt64? = nil) {
        self.init(graceUs: graceUs ?? DisplayLease.keepUs(env: ProcessInfo.processInfo.environment),
                  prefsStore: UserDefaultsStreamPrefsStore())
    }

    init(graceUs: UInt64, prefsStore: StreamPrefsStoring) {
        self.prefsStore = prefsStore
        lease = DisplayLease(graceUs: graceUs)
    }

    private var isShuttingDown: Bool { shutdownLock.withLock { shuttingDown } }

    /// Coalescing merge: keyframe requests keep the strongest pending requirement (see `KeyframeReason.merged`);
    /// every other coalesced event is latest-wins.
    private static func mergeEvents(pending: Event, incoming: Event) -> Event {
        if case .keyframeRequest(let old, let oldView) = pending, case .keyframeRequest(let new, let newView) = incoming {
            // A missing view means both streams; the union of the two requests is kept (decision 0034).
            return .keyframeRequest(KeyframeReason.merged(pending: old, incoming: new),
                                    (oldView ?? .both).merged(with: newView ?? .both))
        }
        return incoming
    }

    private func post(_ event: Event, key: Int? = nil, forced: Bool = false) {
        guard mailbox.post(event, coalesceKey: key, forced: forced, merge: Self.mergeEvents) == .overflow else { return }
        logger.log(.error, "event_overflow", sessionID: 0, generation: 0)
        var dropped = mailbox.removeAll()
        dropped.append(event)
        // T-325: forced events are kept, but once each. A stuck loop used to collect one forced `sessionEnded` per
        // session until nothing else fitted, so every later session overflowed again. One pending end covers any
        // number of dropped ones (it is idempotent), and the dropped starts are ended by `onOverflow` below.
        var keptEnd = false, keptShutdown = false
        for e in dropped {
            switch e {
            case .videoAttached(let link): link.cancel()
            case .shutdown:
                if !keptShutdown { keptShutdown = true; mailbox.post(e, forced: true) }  // never lose the shutdown
            // Never lose a session end either (T-128): it releases the display-sleep assertion and ends the episode.
            // A dropped start needs nothing: `onOverflow` ends that session, which posts its end.
            case .sessionEnded:
                if !keptEnd { keptEnd = true; mailbox.post(e, forced: true) }
            default: break
            }
        }
        onOverflow()
    }

    // MARK: Entry points (any thread)

    public func start() {
        guard loop == nil else { return }
        loop = Task { [self] in
            for await _ in mailbox.wake {
                while let event = mailbox.take() { await handleWatched(event) }
            }
        }
        startWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.matebridge.stream.tick"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.post(.tick, key: Self.tickKey) }
        timer.resume()
        tickTimer = timer
        let observer = SystemPowerObserver { [weak self] event in self?.onPower(event) }
        if observer.start() {
            powerObserver = observer
        } else {
            logger.log(.warning, "power_observer_failed", sessionID: 0, generation: 0)
        }
    }

    /// Settings of a session from its tablet's HELLO: `base` (HELLO + experiment knobs) and `initial` (`base` with
    /// the device's remembered `STREAM_PREFS` on top, so a reconnect starts in the last chosen mode). Pure apart from
    /// reading the store: nothing is remembered here, so a HELLO that never becomes a session (an unproven reconnect)
    /// cannot change the settings of the live one.
    private func settings(for hello: Hello)
        -> (base: VideoSettings, initial: VideoSettings, stored: StreamPrefs?) {
        // Experiment knobs (T-017, T-045): MATEBRIDGE_FPS=60|90|120, MATEBRIDGE_BITRATE_KBPS,
        // T-086: MATEBRIDGE_CODEC=h264|hevc, and the env bitrate wins over STREAM_PREFS.
        let env = ProcessInfo.processInfo.environment
        let base = VideoSettings.forTablet(hello).applyingExperimentKnobs(env)
        let stored = prefsStore.load(device: hello.deviceID)
        let initial = VideoSettings.initialSettings(
            defaults: base, stored: stored,
            allowGameDisplay: allowsGameDisplay, allowHDR: allowsHDR)
        return (base, initial, stored)
    }

    /// `SessionServer` `makeStreamConfig`: the tablet's HELLO decides the native display size (a remembered game
    /// display, decision 0029, replaces the display but not the native size). Side-effect free (apart from a log
    /// line); the session machine may call it for a connection that never becomes the session.
    public func streamConfig(for hello: Hello) -> StreamConfig {
        let settings = self.settings(for: hello).initial
        if settings.nativeWidthPx != Int(hello.screenWidthPx) || settings.nativeHeightPx != Int(hello.screenHeightPx) {
            logger.log(.warning, "display_size_differs_from_hello", sessionID: 0, generation: 0,
                       fields: "hello=\(hello.screenWidthPx)x\(hello.screenHeightPx) display=\(settings.nativeWidthPx)x\(settings.nativeHeightPx)")
        }
        let config = settings.streamConfig(configID: Self.configID)
        announcedLock.withLock { announced.record(config, for: hello) }
        return config
    }

    /// The session is active (after proof, for a reconnect): only now are the settings derived from its HELLO. If
    /// they no longer match the config this connection was told at HELLO (game displays switched off by
    /// `game_display_failed`, or other stored prefs, in between), the event loop announces a new `config_id` before
    /// starting the pipeline.
    public func sessionStarted(sessionID: UInt32, configID: UInt16, hello: Hello, transport: SessionTransport) {
        liveSessionLock.withLock { liveSessionID = sessionID }
        let (base, initial, stored) = settings(for: hello)
        let reannounce = announcedLock.withLock {
            announced.activationDiffers(hello: hello, activation: initial.streamConfig(configID: configID))
        }
        post(.sessionStarted(sessionID: sessionID, configID: configID, device: hello.deviceID,
                             settings: initial, base: base, prefs: stored, reannounce: reannounce, transport: transport))
    }

    public func sessionEnded() {
        liveSessionLock.withLock { liveSessionID = nil }
        // Forced (beyond the lifecycle cap, at most one per session): the display-sleep assertion is released here,
        // so this event must never be dropped by an overflow (T-128).
        post(.sessionEnded, forced: true)
    }

    public func videoAttached(_ link: VideoLink) { post(.videoAttached(link)) }

    /// Messages from the approved session; only `KEYFRAME_REQUEST` and `STATS` are handled here.
    public func deliver(_ message: Message) {
        switch message {
        case .keyframeRequest(let reason, let view): post(.keyframeRequest(reason, view), key: Self.keyframeKey)
        case .stats(let stats): post(.stats(stats), key: Self.statsKey)
        case .streamPrefs(let prefs):
            // Stamped with the session that is live now (sessionStarted/sessionEnded arrive on the same queue, in
            // order). The key includes the session id, so prefs of two sessions are never merged.
            guard let sid = liveSessionLock.withLock({ liveSessionID }) else { return }
            post(.streamPrefs(sessionID: sid, prefs), key: Self.prefsKey(sid))
        case .displayRate(let rate):
            guard let sid = liveSessionLock.withLock({ liveSessionID }) else { return }
            post(.displayRate(sessionID: sid, hz: rate.hz), key: Self.displayRateKey(sid))
        default: break
        }
    }

    /// Stops sending, capture, the encoder and removes the virtual display. Waits up to `timeout` seconds.
    /// Do not call from the coordinator's own callbacks.
    public func shutdown(timeout: TimeInterval = 2) {
        shutdownLock.withLock { shuttingDown = true }
        tickTimer?.cancel()
        tickTimer = nil
        watchdogTimer?.cancel()
        watchdogTimer = nil
        guard loop != nil else { return }
        let semaphore = DispatchSemaphore(value: 0)
        post(.shutdown(done: { semaphore.signal() }), forced: true)
        _ = semaphore.wait(timeout: .now() + timeout)
        powerObserver?.stop()
        powerObserver = nil
        // Normally released by `onShutdown`; again here in case the event loop did not get to it in time (logged
        // without the event loop's session state, which this thread must not read).
        if displaySleep.release() == .released {
            logger.log(.info, "display_sleep_assertion", sessionID: 0, generation: 0, fields: "state=released")
        }
    }

    // MARK: Watchdog (T-325)

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.matebridge.stream.watchdog"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.pollWatchdog() }
        timer.resume()
        watchdogTimer = timer
    }

    /// Brackets one event for the watchdog.
    private func handleWatched(_ event: Event) async {
        watchdogLock.withLock { watchdog.begin(kind: event.kind, nowUs: HostClock.nowUs()) }
        await handle(event)
        let over = watchdogLock.withLock { watchdog.end(nowUs: HostClock.nowUs()) }
        if let over {
            logger.log(.warning, "coordinator_stall_over", sessionID: 0, generation: 0,
                       fields: "event=\(over.kind) ms=\(over.ms)")
        }
    }

    /// Watchdog queue, once a second. The loop may be stuck, so this touches no loop state: it logs, ends the sessions
    /// (input released, BYE, through `onOverflow`) and as the last resort restarts the process.
    private func pollWatchdog() {
        let actions = watchdogLock.withLock { watchdog.poll(nowUs: HostClock.nowUs()) }
        for action in actions {
            switch action {
            case .warn(let kind, let ms):
                logger.log(.error, "coordinator_stall", sessionID: 0, generation: 0, fields: "event=\(kind) ms=\(ms)")
            case .endSessions(let kind, let ms):
                logger.log(.error, "coordinator_stall_recover", sessionID: 0, generation: 0,
                           fields: "action=end_sessions event=\(kind) ms=\(ms)")
                onOverflow()
            case .restart(let kind, let ms):
                logger.log(.error, "coordinator_stall_recover", sessionID: 0, generation: 0,
                           fields: "action=restart event=\(kind) ms=\(ms)")
                onOverflow()  // again: a session that started meanwhile must not outlive the process
                if let onStallRestart { onStallRestart() } else { Self.defaultStallRestart() }
            }
        }
    }

    /// No app hook: relaunch the bundle shortly after this process is gone, then exit. Without a LaunchAgent (T-202)
    /// this is the only way back; outside a `.app` bundle (swift run, tests) the process only exits. The virtual
    /// display belongs to the process and disappears with it, so macOS shows its placeholder display again.
    private static func defaultStallRestart() {
        let path = Bundle.main.bundlePath
        if path.hasSuffix(".app") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 3; /usr/bin/open -n \"$1\"", "sh", path]
            p.standardInput = nil
            p.standardOutput = nil
            p.standardError = nil
            try? p.run()
        }
        exit(75)
    }

    // MARK: Event loop

    private func handle(_ event: Event) async {
        if isShuttingDown {
            // After shutdown() nothing new may start (no display, no sender): only the shutdown itself runs.
            switch event {
            case .shutdown(let done): await onShutdown(); done()
            case .videoAttached(let link): link.cancel()
            default: break
            }
            return
        }
        switch event {
        case .sessionStarted(let sid, let cid, let device, let settings, let base, let prefs, let reannounce,
                             let transport):
            await onSessionStarted(sessionID: sid, configID: cid, device: device, settings: settings, base: base,
                                   prefs: prefs, reannounce: reannounce, transport: transport)
        case .sessionEnded:
            await onSessionEnded()
        case .videoAttached(let link):
            await onVideoAttached(link)
        case .keyframeRequest(let reason, let view):
            if let decision = pipeline?.handleKeyframeRequest(reason: reason, view: view) {
                log(.info, "keyframe_request", "reason=\(reason.rawValue) view=\(view?.logName ?? "both") \(decision.logFields)")
            } else {
                log(.info, "keyframe_request", "reason=\(reason.rawValue) action=no_pipeline")
            }
        case .streamPrefs(let sid, let prefs):
            await onStreamPrefs(prefs, sessionID: sid)
        case .displayRate(let sid, let hz):
            onDisplayRate(hz, sessionID: sid)
        case .stats(let stats):
            onStats(stats)
        case .tick:
            let now = HostClock.nowUs()
            await perform(lease.tick(now: Self.leaseNowUs()))
            if let waiting = prefsGate.poll(now: now) { await applyPrefs(waiting) }
            reportCadence()
        case .pipelineFailed(let id, let message, let kind, let wake):
            await onPipelineFailed(id: id, message: message, kind: kind, wake: wake)
        case .deferredWakeDue:
            onDeferredWakeDue()
        case .macWoke:
            resetRetryPolicy(reason: "mac_wake")
        case .senderEnded(let id, let reason):
            await onSenderEnded(id: id, reason: reason)
        case .packedFallback(let id, let reason):
            guard id == pipelineID else { break }
            await fallBackFromPackedChroma(reason: reason, startFailed: false)
        case .shutdown(let done):
            await onShutdown()
            done()
        }
    }

    private func onSessionStarted(sessionID: UInt32, configID: UInt16, device: DeviceID,
                                  settings initial: VideoSettings, base: VideoSettings, prefs: StreamPrefs?,
                                  reannounce: Bool, transport: SessionTransport) async {
        var settings = initial
        // T-293: the same device keeps its failure history and breaker (the tablet renews its session every ~6 s while
        // video is dead); another device (takeover) starts fresh.
        let breakerBefore = retryPolicy.breaker
        retryPolicy.sessionStarted(device: device)
        logBreaker(from: breakerBefore)
        // T-214 review: the settings were derived before this event waited in the mailbox; a game display that failed
        // meanwhile (game_display_failed) must not be tried again. The tablet holds the HELLO config (equal to the
        // derived settings unless `reannounce` is already set), so a changed result is announced too.
        var reasons: [String] = reannounce ? ["hello_mismatch"] : []
        let allowHDR = allowsHDR, allowGame = allowsGameDisplay
        if let fixed = gameDisplayLock.withLock({
            gameDisplay.revalidated(settings, base: base, prefs: prefs, allowHDR: allowHDR)
        }) {
            if AnnouncedStreamConfigs.differs(settings.streamConfig(configID: configID),
                                              fixed.streamConfig(configID: configID)) {
                reasons.append("game_display_off")
            }
            settings = fixed
        }
        // T-237: the same for HDR10 switched off by an `hdr_fallback` while this start waited.
        if let fixed = hdrLock.withLock({
            hdrFallback.revalidated(settings, base: base, prefs: prefs,
                                    allowGameDisplay: allowGame)
        }) {
            if AnnouncedStreamConfigs.differs(settings.streamConfig(configID: configID),
                                              fixed.streamConfig(configID: configID)) {
                reasons.append("hdr_off")
            }
            settings = fixed
        }
        // The config the tablet was told no longer matches these settings; announce them under a new config_id
        // (STREAM_CONFIG + video close) before any pipeline starts, so the tablet never decodes a stream whose size
        // or point size it was not told.
        let activeConfigID = reasons.isEmpty ? configID : nextConfigID(after: configID)
        session = ActiveSession(sessionID: sessionID, configID: activeConfigID, deviceID: device, settings: settings,
                                base: base, prefs: prefs, transport: transport)
        if !reasons.isEmpty {
            log(.info, "stream_config_reannounced", "config_id=\(configID)->\(activeConfigID) "
                + "reason=\(reasons.joined(separator: ",")) display=\(settings.displayModeText) "
                + "encoded=\(settings.encodedWidthPx)x\(settings.encodedHeightPx) fps=\(settings.fps)")
            onReconfigure(sessionID, settings.streamConfig(configID: activeConfigID))
        }
        prefsGate = StreamPrefsGate()
        resetDisplayRate()
        // T-128: an accepted session means the Mac is running, also after a dark wake (Wake-on-LAN), which never
        // sends `did_wake`: open the gate so the T-081 wake can bring the displays (and the full wake) back.
        if gateLock.withLock({ sleepGate.sessionStarted() }) {
            log(.info, "power", "state=awake reason=session_started wall_ms=\(Self.wallMs())")
        }
        logDisplaySleep(displaySleep.hold())
        log(.info, "stream_session", "device=\(device.shortHex) from_stored=\(settings != base) "
            + "width=\(settings.encodedWidthPx) height=\(settings.encodedHeightPx) fps=\(settings.fps) refresh_hz=\(settings.displayRefreshHz) bitrate_kbps=\(settings.bitrateKbps) bitrate_source=\(settings.bitrateSource) codec=\(settings.codec.logName) "
            + "transport=\(transport.logName) display=\(settings.displayModeText)")
        await perform(lease.sessionStarted(device: device, settings: settings))
    }

    /// `STREAM_PREFS`: the gate allows one reconfiguration per second; a request that arrives earlier waits for the tick.
    private func onStreamPrefs(_ prefs: StreamPrefs, sessionID: UInt32) async {
        // Prefs of a session that is not the current one (ended, or replaced) are dropped.
        guard let live = session, live.sessionID == sessionID else {
            log(.info, "stream_prefs_dropped", "reason=not_current_session")
            return
        }
        let p = prefs.normalized
        let userKbps = VideoSettings.clampedUserBitrateKbps(p.bitrateKbps).map(String.init) ?? "default"
        let allowed = allowsGameDisplay
        let allowHDR = allowsHDR
        let derived = derive(live, from: p, allowGameDisplay: allowed, allowHDR: allowHDR,
                             fullChroma: FullChromaSession(prefsFromThisSession: true, allowed: !live.packedFallback))
        let game = GameDisplayPolicy.outcome(of: p, nativeW: live.base.nativeWidthPx, nativeH: live.base.nativeHeightPx,
                                             allowed: allowed)
        log(.info, "stream_prefs", "fps=\(p.fps) scale=\(p.scalePermille) bitrate_kbps=\(userKbps) "
            + "requested_fps=\(prefs.fps) requested_scale=\(prefs.scalePermille) requested_bitrate_kbps=\(prefs.bitrateKbps) "
            + "display=\(derived.displayModeText) requested_display=\(prefs.displayWidthPx)x\(prefs.displayHeightPx) "
            + "game_display=\(game.logName) dynamic_range=\(derived.dynamicRange.logName) "
            + "requested_dynamic_range=\(prefs.dynamicRange) chroma=\(derived.chromaPreference.logName) "
            + "requested_chroma=\(prefs.chroma)")
        if let now = prefsGate.offer(p, now: HostClock.nowUs()) { await applyPrefs(now) }
    }

    /// `DISPLAY_RATE`: the encoder feed is decimated to `min(stream fps, hz)`. Nothing restarts, no `STREAM_CONFIG`.
    private func onDisplayRate(_ hz: UInt16, sessionID: UInt32) {
        guard let live = session, live.sessionID == sessionID else { return }
        rateState.update(hz: hz)
        applyDisplayRate(streamFps: live.settings.fps)
    }

    /// Pushes the remembered panel rate to the current pipeline (also right after one was created, because a
    /// reconfiguration builds a new encoder). Logs `ev=display_rate` only when hz or the effective fps changed.
    private func applyDisplayRate(streamFps: Int) {
        let effective = rateState.effectiveFps(streamFps: streamFps)
        pipeline?.setDisplayRate(hz: rateState.hz)
        guard lastLoggedRate?.hz != rateState.hz || lastLoggedRate?.fps != effective else { return }
        lastLoggedRate = (rateState.hz, effective)
        log(.info, "display_rate", "hz=\(rateState.hz) effective_fps=\(effective)")
    }

    /// No report yet (new session, or none any more): the pipeline runs at the stream fps again.
    private func resetDisplayRate() {
        rateState.reset()
        lastLoggedRate = nil
        pipeline?.setDisplayRate(hz: 0)
    }

    /// Derives the settings, and if they differ from the running ones: new `config_id`, session layer notified
    /// (`STREAM_CONFIG` + video close), capture and encoder rebuilt; the virtual display is kept unless the
    /// refresh rate or the display mode changes (native HiDPI <-> 1x game display, decision 0029): `VideoPipeline`
    /// recreates it then, SCK cannot follow an in-place mode switch. A change of the bitrate alone (T-106) keeps the
    /// refresh rate and mode, so only capture and encoder restart.
    private func applyPrefs(_ prefs: StreamPrefs) async {
        guard var live = session else { return }
        live.prefsFromSession = true
        var wanted = derive(live, from: prefs)
        // Decision 0034: a runtime fallback is retried at the next stream mode change.
        if live.packedFallback, !wanted.sameStreamMode(as: live.settings) {
            live.packedFallback = false
            wanted = derive(live, from: prefs)
        }
        // T-293: only a real user change of the prefs (not a replay on accept) starts the breaker over.
        let breakerBefore = retryPolicy.breaker
        if retryPolicy.prefsApplied(prefs, settingsChanged: wanted != live.settings) {
            if breakerBefore.state != .closed { log(.info, "pipeline_breaker_reset", "reason=prefs_change") }
            logBreaker(from: breakerBefore)
        }
        prefsStore.save(prefs, device: live.deviceID)  // the next connection of this tablet starts in this mode
        live.prefs = prefs
        session = live
        guard wanted != live.settings else { return }
        let old = live.settings
        live.settings = wanted
        live.configID = nextConfigID(after: live.configID)
        session = live
        prefsGate.markApplied(now: HostClock.nowUs())
        log(.info, "stream_reconfigure",
            "config_id=\(live.configID) fps=\(old.fps)->\(wanted.fps) scale=\(old.scalePermille)->\(wanted.scalePermille) "
            + "encoded=\(wanted.encodedWidthPx)x\(wanted.encodedHeightPx) refresh_hz=\(old.displayRefreshHz)->\(wanted.displayRefreshHz) "
            + "bitrate_kbps=\(old.bitrateKbps)->\(wanted.bitrateKbps) bitrate_source=\(wanted.bitrateSource) "
            + "display=\(old.displayModeText)->\(wanted.displayModeText) "
            + "dynamic_range=\(old.dynamicRange.logName)->\(wanted.dynamicRange.logName) "
            + "chroma=\(old.chromaPreference.logName)->\(wanted.chromaPreference.logName) "
            + "chroma_layout=\(old.chromaLayout)->\(wanted.chromaLayout)")
        onReconfigure(live.sessionID, wanted.streamConfig(configID: live.configID))
        await perform(lease.reconfigure(settings: wanted))
    }

    private func onSessionEnded() async {
        session = nil
        wakePolicy.sessionEnded()
        gateLock.withLock { sleepGate.cancelPending() }
        logDisplaySleep(displaySleep.release())
        resetDisplayRate()
        lastSent = VideoSender.Counters()
        lastStatsText = ""
        lastCadenceText = ""
        await stopConsumer()
        // T-165: park, no drain. Capture and encoder stop now; only the display waits for this tablet.
        await perform(lease.sessionEnded(now: Self.leaseNowUs()))
        onSummary("")
    }

    private func onVideoAttached(_ link: VideoLink) async {
        guard let s = session, link.sessionID == s.sessionID, link.configID == s.configID else {
            log(.warning, "video_without_session")
            link.cancel()
            return
        }
        if pipeline == nil {  // earlier creation failed or the pipeline died: try again, unless the breaker is open
            // T-293: no display, capture or encoder while the breaker is open; the video connection closes at once.
            guard admitBuild() else {
                link.cancel()
                return
            }
            _ = lease.sessionStarted(device: s.deviceID, settings: s.settings)
            // Normally nothing is parked during a session (unparked at session start); never strand one.
            let leftover = parked?.display
            parked = nil
            await createPipeline(settings: s.settings, reusing: leftover)
        }
        // T-214: a failed game display falls back with a new config_id; this link belongs to the old one (the client
        // reopens the video connection for the new STREAM_CONFIG).
        guard let pipeline, session?.configID == link.configID else { link.cancel(); return }
        await stopConsumer()
        pipeline.prepareForNewConsumer()
        consumerID += 1
        let id = consumerID
        let sender = VideoSender(transport: link, frames: pipeline.frames,
                                 auxFrames: s.settings.packedChroma ? pipeline.auxFrames : nil,
                                 requestKeyframe: { [weak pipeline] in pipeline?.requestKeyframe() },
                                 requestAuxKeyframe: { [weak pipeline] in pipeline?.requestAuxKeyframe() },
                                 auxPairingDropped: { [weak pipeline] in pipeline?.auxPairingDropped() },
                                 onEnded: { [weak self] reason in self?.post(.senderEnded(id: id, reason)) },
                                 // T-170: join keys from the link, not the pipeline (it outlives sessions).
                                 trace: { [weak pipeline, sid = link.sessionID, cid = link.configID] t in
                                     var t = t
                                     t.sessionID = sid
                                     t.configID = cid
                                     pipeline?.recordTrace(t)
                                 },
                                 clock: { HostClock.nowUs() })
        consumer = .sender(id: id, sender, link)
        lastSent = VideoSender.Counters()
        sender.start()
        log(.info, "video_streaming")
    }

    private func onSenderEnded(id: Int, reason: VideoSender.EndReason) async {
        guard case .sender(let current, _, let link) = consumer, current == id else { return }
        consumer = .none
        link.cancel()  // the client sees EOF and reopens the video connection
        log(.info, "video_sender_ended", "reason=\(reason)")
        if pipeline != nil { startDrain() }
    }

    private func onStats(_ stats: Stats) {
        let summary = StatsSummary(stats)
        var fields = summary.logFields
        if case .sender(_, let sender, _) = consumer {
            let now = sender.currentCounters
            let frames = now.framesSent - lastSent.framesSent
            let kbps = Double(now.bytesSent - lastSent.bytesSent) * 8 / 1000 * 1000 / Double(max(1, stats.intervalMs))
            fields += String(format: " sent_frames=%d sent_kbps=%.0f rejected=%d send_failures=%d",
                             frames, kbps, now.framesRejected, now.sendFailures)
            lastSent = now
        }
        if let pipeline { fields += " " + pipeline.takeKeyframeWindow().logFields }
        log(.info, "stats", fields)
        lastStatsText = summary.menuText
        publishSummary()
    }

    /// Once a second: closes the pipeline's cadence window, logs `component=video ev=cadence`, updates the menu.
    private func reportCadence() {
        guard let pipeline else { return }
        var sentTotal = 0
        if case .sender(_, let sender, _) = consumer { sentTotal = sender.currentCounters.framesSent }
        let w = pipeline.cadenceWindow(sentTotal: sentTotal)
        guard w.durationUs > 0 else { return }
        if !w.isEmpty {
            videoLogger.log(.info, "cadence", sessionID: session?.sessionID ?? 0, generation: session?.configID ?? 0,
                            fields: w.logFields)
        }
        lastCadenceText = w.menuText
        let lat = pipeline.latencyWindow()
        if !lat.isEmpty {
            videoLogger.log(.info, "latency", sessionID: session?.sessionID ?? 0, generation: session?.configID ?? 0,
                            fields: lat.logFields)
        }
        // T-235: every 10 s while `MATEBRIDGE_CHROMA` is set or the sharp path runs (T-240).
        if let chroma = pipeline.takeChromaStats() {
            videoLogger.log(.info, "chroma_stats", sessionID: session?.sessionID ?? 0,
                            generation: session?.configID ?? 0, fields: chroma)
        }
        // T-258: the auxiliary loss rule, once a second (`PackedChromaMonitor`).
        if settingsArePacked {
            var senderAuxDropped = 0
            if case .sender(_, let sender, _) = consumer { senderAuxDropped = sender.currentCounters.auxDropped }
            if let decision = pipeline.checkPackedWindow(senderAuxDroppedTotal: senderAuxDropped),
               case .fallback(let reason) = decision {
                post(.packedFallback(id: pipelineID, reason: reason))
            }
        }
        reportSendQueue()
        publishSummary()
    }

    private var settingsArePacked: Bool { session?.settings.packedChroma ?? false }

    /// T-088: the video connection's kernel send queue, RTT and retransmits of the last second (`ev=sendq`), only
    /// while `MATEBRIDGE_SENDQ_LOG=1` or `MATEBRIDGE_LAT_TRACE=1`.
    private func reportSendQueue() {
        guard case .sender(_, _, let link) = consumer, let report = link.sendQueueReport() else { return }
        let sid = session?.sessionID ?? 0, gen = session?.configID ?? 0
        switch report {
        case .window(let w):
            videoLogger.log(.info, "sendq", sessionID: sid, generation: gen,
                            fields: w.logFields + " transport=\(session?.transport.logName ?? "unknown")")
        case .unavailable(let reason):
            videoLogger.log(.warning, "sendq_unavailable", sessionID: sid, generation: gen, fields: "reason=\(reason)")
        }
    }

    private func publishSummary() {
        guard session != nil, case .sender = consumer else { return }
        onSummary([lastStatsText, lastCadenceText, encoderWarningText ?? ""].filter { !$0.isEmpty }
            .joined(separator: " · "))
    }

    /// T-187: menu warning while the current pipeline's encoder is software or unknown; nil otherwise (also with no
    /// pipeline, so a stopped, parked or replaced pipeline leaves nothing behind).
    private var encoderWarningText: String? {
        guard pipeline != nil, let hw = encoderHardware, hw.pipelineID == pipelineID else { return nil }
        return hw.check.menuText
    }

    private func onPipelineFailed(id: Int, message: String, kind: PipelineFailureKind,
                                  wake: DisplayWakeReason?) async {
        guard id == pipelineID, pipeline != nil else { return }
        log(.error, "pipeline_failed", "kind=\(kind.rawValue) error=\(message)")
        let failedAt = HostClock.nowUs()
        // Wakes at once, or (capture_source_lost, T-128) defers the wake by `SleepWakeGate.captureLossDeferUs`.
        wakeDisplayIfNeeded(wake)
        await stopConsumer()
        pipeline = nil  // the pipeline already closed its display and queue
        lease.displayLost()
        onSummary("Video durdu: \(message)")
        // With a live session, rebuild after a backoff (T-289: `PipelineRetryPolicy`, a bounded budget per window
        // instead of one rebuild per session); the cancelled video link makes the client reconnect its video
        // connection, which then gets a sender. An HDR10 pipeline whose encoder failed twice in the window is rebuilt
        // as SDR instead (`ev=hdr_fallback`, new `config_id`).
        guard let live = session, !isShuttingDown else { return }
        var settings = live.settings
        var delayUs = PipelineRetryPolicy.baseDelayUs
        let breakerBefore = retryPolicy.breaker
        let decision = retryPolicy.failed(kind: kind, hdr10: live.settings.dynamicRange == .hdr10, nowUs: failedAt)
        logBreaker(from: breakerBefore)
        switch decision {
        case .giveUp:
            log(.warning, "pipeline_retry_exhausted",
                "kind=\(kind.rawValue) max=\(PipelineRetryPolicy.maxRetries) "
                + "window_s=\(PipelineRetryPolicy.windowUs / 1_000_000)")
            return
        case .retry(let delay, let attempt):
            delayUs = delay
            log(.info, "pipeline_retry_scheduled", "attempt=\(attempt) delay_ms=\(delay / 1_000)")
        case .fallBackToSDR:
            let fallBack = hdrLock.withLock {
                hdrFallback.startFailed(settings: live.settings, reason: .encoderRejected)
            }
            if fallBack, let sdr = announceHDRFallback(reason: .encoderRejected, detail: "runtime_\(kind.rawValue)") {
                settings = sdr
            }
        }
        // The retry comes at least `delayUs` after the failure. With a deferred wake pending (T-128) it waits
        // for that wake's deadline, runs the wake itself (this loop is busy until the retry, so `.deferredWakeDue`
        // would only be handled after it) and then gives the displays `retryAfterDeferredWakeUs` to come up;
        // otherwise the retry would always land inside the deferral window and find the displays still dark.
        var retryAt = failedAt + delayUs
        if let deadline = gateLock.withLock({ sleepGate.pendingDeadlineUs }) {
            await sleep(until: deadline)
            guard !isShuttingDown else { return }
            onDeferredWakeDue()
            retryAt = max(retryAt, deadline + Self.retryAfterDeferredWakeUs)
        }
        await sleep(until: retryAt)
        guard !isShuttingDown, pipeline == nil else { return }
        log(.info, "pipeline_retry")
        _ = lease.sessionStarted(device: live.deviceID, settings: settings)
        await createPipeline(settings: settings)
    }

    private func onShutdown() async {
        session = nil
        wakePolicy.sessionEnded()
        gateLock.withLock { sleepGate.cancelPending() }
        logDisplaySleep(displaySleep.release())
        await perform(lease.shutdown())  // display_teardown reason=shutdown, also for a parked display
        await destroyPipeline()
        dropParked()
        onSummary("")
    }

    // MARK: Display and consumers

    private func perform(_ actions: [DisplayLease.Action]) async {
        for action in actions {
            switch action {
            case .teardown(let reason):
                log(.info, "display_teardown", "reason=\(reason.logName)")
                await destroyPipeline()
                dropParked()
            case .create(let s):
                // T-293 review: a session start (the tablet renews its session every few seconds) must not build
                // while the breaker is open. Nothing to cancel here; the lease forgets the display so that the
                // video attach path (`onVideoAttached`) can start it again once `admit` allows.
                guard admitBuild() else {
                    lease.displayLost()
                    break
                }
                await createPipeline(settings: s)
            case .reuse:
                if parked != nil, let s = session?.settings {
                    await unpark(settings: s)
                } else {
                    log(.info, "display_reused")
                }
            case .reconfigure(let s):
                if parked != nil {
                    await unpark(settings: s)
                } else {
                    log(.info, "display_reused", "restart=true fps=\(s.fps) refresh_hz=\(s.displayRefreshHz)")
                    await restartPipeline(settings: s)
                }
            case .park:
                await park()
            }
        }
    }

    /// Capture and encoder with new settings on the same virtual display. Without a running pipeline nothing is
    /// started here: the next video connection builds one from the session's settings.
    private func restartPipeline(settings: VideoSettings) async {
        guard !isShuttingDown else { return }
        await stopConsumer()
        guard let old = pipeline else { return }
        pipeline = nil
        noteStopped()
        let display = await old.stopKeepingDisplay()
        logRecreate(display, for: settings)
        await createPipeline(settings: settings, reusing: display)
    }

    /// `ev=display_recreate` when the pipeline about to be built for `settings` will not keep `display`
    /// (`DisplayReuse`, the same decision `VideoPipeline.obtainDisplay` makes).
    private func logRecreate(_ display: VirtualDisplay?, for settings: VideoSettings) {
        guard let display else { return }
        let current = display.mode
        switch DisplayReuse.decide(current: current, online: VideoPipeline.isOnline(display), wanted: settings.displayMode) {
        case .reuse:
            break
        case .recreate(.modeChange):
            log(.info, "display_recreate", "reason=mode_change mode=\(current.text)->\(settings.displayModeText) "
                + "refresh_hz=\(current.refreshHz)->\(settings.displayRefreshHz)")
        case .recreate(.refreshChange):
            log(.info, "display_recreate", "reason=refresh_change refresh_hz=\(current.refreshHz)->\(settings.displayRefreshHz)")
        case .recreate(.transferChange):
            log(.info, "display_recreate", "reason=transfer_change transfer=\(current.transfer)->\(settings.displayMode.transfer)")
        case .recreate(.offline):
            log(.info, "display_recreate", "reason=offline")
        }
    }

    /// T-165: the session ended. Capture and encoder stop (the encoder's VT session is shut down, T-162); the display
    /// stays, without a drain. With no pipeline or no display there is nothing to keep.
    private func park() async {
        await stopConsumer()
        guard let p = pipeline else { lease.displayLost(); return }
        pipeline = nil
        noteStopped()
        guard let display = await p.stopKeepingDisplay() else {
            lease.displayLost()
            log(.info, "display_park_skipped", "reason=no_display")
            return
        }
        dropParked()  // never two displays
        parked = (display, Self.leaseNowUs())
        log(.info, "display_parked", "keep_s=\(lease.graceUs / 1_000_000) refresh_hz=\(Int(display.requestedRefreshHz)) "
            + "mode=\(display.mode.text)")
    }

    /// T-165: the same tablet is back; a new pipeline on the parked display. `VideoPipeline` replaces the display when
    /// the refresh rate (T-049) or the display mode (T-214) changed, or it went offline while parked.
    private func unpark(settings: VideoSettings) async {
        guard let p = parked else { return }
        parked = nil
        let parkedUs = Self.leaseNowUs() &- p.sinceUs
        log(.info, "display_unparked", "parked_ms=\(parkedUs / 1_000) refresh_hz=\(settings.displayRefreshHz)")
        logRecreate(p.display, for: settings)
        await createPipeline(settings: settings, reusing: p.display)
    }

    /// T-232: `ev=vd_transfer` for a newly created display (native or game, decision 0029): the transfer function
    /// requested (from the stream) and applied, and the screen's EDR headroom. AppKit is read on the main
    /// actor in a separate task, so pipeline start does not wait for it; ids are taken now.
    private func logDisplayTransfer(_ p: VideoPipeline) {
        guard let (displayID, outcome) = p.displayTransfer else { return }
        let sid = session?.sessionID ?? 0
        let gen = session?.configID ?? 0
        let logger = self.logger
        Task {
            let edr = await DisplayEDR.read(displayID: displayID)
            let wideGamut = await VirtualDisplay.readWideGamut(displayID: displayID)  // T-281, after a short delay
            logger.log(outcome.logLevel, "vd_transfer", sessionID: sid, generation: gen,
                       fields: VirtualDisplayTransfer.logFields(outcome, edr: edr, wideGamut: wideGamut))
        }
    }

    /// Removes the parked display, if any (keep time over, other device or size, shutdown).
    private func dropParked() {
        guard let p = parked else { return }
        parked = nil
        p.display.invalidate()
    }

    private func createPipeline(settings: VideoSettings, reusing display: VirtualDisplay? = nil) async {
        guard !isShuttingDown else { return }
        pipelineID += 1
        let id = pipelineID
        // T-253: the byte ceiling of a refinement train depends on the link (USB or network).
        let refine = StillRefineConfig.resolve(env: ProcessInfo.processInfo.environment,
                                               transport: session?.transport ?? .usb)
        let p = VideoPipeline(settings: settings, reusing: display, refine: refine,
                              onPackedFallback: { [weak self] reason in self?.post(.packedFallback(id: id, reason: reason)) },
                              onFailure: { [weak self] error in
            self?.post(.pipelineFailed(id: id, message: "\(error)", kind: VideoPipeline.failureKind(error),
                                       wake: DisplayWaker.reason(for: error)))
        })
        do {
            try await p.start()
            if isShuttingDown {  // shutdown() ran while the display was being created
                await p.stop()
                return
            }
            pipeline = p
            retryPolicy.built(nowUs: HostClock.nowUs())
            wakePolicy.recovered()
            gateLock.withLock { sleepGate.cancelPending() }
            if rateState.hz != 0 { applyDisplayRate(streamFps: settings.fps) }
            startDrain()
            let sizes = "width=\(settings.widthPx) height=\(settings.heightPx) encoded=\(settings.encodedWidthPx)x\(settings.encodedHeightPx) "
                + "mode=\(settings.displayModeText)"
            if p.displayWasReused {
                log(.info, "pipeline_started", "display=reused \(sizes)")
            } else {
                log(.info, "display_created", sizes)
                logDisplayTransfer(p)
            }
            logHDRConfig(settings)
            videoLogger.log(.info, "cadence_setup", sessionID: session?.sessionID ?? 0,
                            generation: session?.configID ?? 0, fields: p.cadenceSetup)
            // T-187: once per pipeline; the menu keeps a software/unknown warning while this pipeline runs.
            let hw = p.encoderHardware
            encoderHardware = (id, hw)
            videoLogger.log(hw.logLevel, EncoderHardwareCheck.event, sessionID: session?.sessionID ?? 0,
                            generation: session?.configID ?? 0, fields: hw.logFields)
            onSummary(encoderWarningText ?? "")
        } catch {
            log(.error, "display_create_failed", "error=\(error)")
            lease.displayLost()
            wakeDisplayIfNeeded(DisplayWaker.reason(for: error))
            onSummary("Video başlamadı: \(error)")
            if await fallBackFromHDR(failed: settings, error: error) { return }
            if await fallBackFromPackedSetup(failed: settings, error: error) { return }
            if await fallBackFromGameDisplay(failed: settings, error: error) { return }
            // T-293: no fallback applies; the start failure counts toward the breaker. The client's next video
            // connection asks `admit` (no timer here).
            let breakerBefore = retryPolicy.breaker
            _ = retryPolicy.failed(kind: .start, hdr10: false, nowUs: HostClock.nowUs())
            logBreaker(from: breakerBefore)
        }
    }

    /// T-293: the pipeline was stopped on purpose; a long enough run settles the breaker (logged).
    private func noteStopped() {
        let before = retryPolicy.breaker
        retryPolicy.stopped(nowUs: HostClock.nowUs())
        logBreaker(from: before)
    }

    /// T-293: asks the breaker before a pipeline is built for a session start or a video attach. false = refused
    /// (logged); the caller builds nothing. A probe is consumed by the first `admit` that returns true, later builds
    /// of the same pipeline are not gated again (the pipeline exists).
    private func admitBuild() -> Bool {
        let before = retryPolicy.breaker
        let admission = retryPolicy.admit(nowUs: HostClock.nowUs())
        logBreaker(from: before)
        guard case .refuse(let remainingUs) = admission else { return true }
        let n = retryPolicy.refusals
        if PipelineRetryPolicy.logsRefusal(n) {
            log(.warning, "pipeline_rebuild_refused", "remaining_ms=\(remainingUs / 1_000) "
                + "level=\(retryPolicy.breaker.level) n=\(n)")
        }
        return false
    }

    /// T-293: `ev=pipeline_breaker` whenever the breaker's state or ladder step changed since `before`.
    private func logBreaker(from before: PipelineRetryPolicy.BreakerSnapshot) {
        let now = retryPolicy.breaker
        guard now.state != before.state || now.level != before.level else { return }
        log(now.state == .open ? .warning : .info, "pipeline_breaker",
            "state=\(now.state.rawValue) wait_ms=\(now.waitUs / 1_000) level=\(now.level)")
    }

    /// Another reason to forget the failure history: a Mac wake or a pipeline-changing prefs/mode change.
    private func resetRetryPolicy(reason: String) {
        let before = retryPolicy.breaker
        retryPolicy.reset()
        if before.state != .closed { log(.info, "pipeline_breaker_reset", "reason=\(reason)") }
        logBreaker(from: before)
    }

    /// T-237: `video ev=hdr_config` for every configured pipeline: what the tablet asked for, what runs (= what
    /// `STREAM_CONFIG` reported), and why a request runs as SDR.
    private func logHDRConfig(_ settings: VideoSettings) {
        let requested = session?.prefs?.requestedDynamicRange ?? .sdr
        let reason = HDRPolicy.decide(requested: requested, codec: settings.codec, allowed: allowsHDR).reason
        videoLogger.log(.info, "hdr_config", sessionID: session?.sessionID ?? 0, generation: session?.configID ?? 0,
                        fields: HDRLog.configFields(requested: requested, settings: settings, reason: reason))
    }

    /// T-237 (decision 0032, PROTOCOL.md 0x05): an HDR10 pipeline whose display, capture or encoder refused HDR falls
    /// back to SDR once. HDR stays off for the rest of the process (`HDRFallback`); the session's prefs are re-applied
    /// without it, announced with a new `config_id` (`STREAM_CONFIG` with SDR codes + video close), and the SDR
    /// pipeline is created (after `DisplayRecreateGap`, since the failed start removed the HDR display). Returns true
    /// when it handled the failure.
    private func fallBackFromHDR(failed: VideoSettings, error: Error) async -> Bool {
        guard let hdr = VideoPipeline.hdrFailure(error) else { return false }
        let fallBack = hdrLock.withLock { hdrFallback.startFailed(settings: failed, reason: hdr.reason) }
        guard fallBack, !isShuttingDown, let live = session, live.settings.dynamicRange == .hdr10,
              let sdr = announceHDRFallback(reason: hdr.reason, detail: hdr.detail) else { return fallBack }
        await perform(lease.sessionStarted(device: live.deviceID, settings: sdr))
        return true
    }

    /// The announcing half of the HDR fallback, shared by the start failure (`fallBackFromHDR`) and the runtime encoder
    /// failure (T-289, `onPipelineFailed`): re-applies the session's prefs without HDR10 (`HDRFallback` has already
    /// switched it off), gives them a new `config_id`, logs `ev=hdr_fallback` and sends `STREAM_CONFIG` (the session
    /// layer closes the video connection). Returns the SDR settings; the caller creates the pipeline. nil = nothing to
    /// switch (no session, not HDR10, no prefs).
    private func announceHDRFallback(reason: HDRFallbackReason, detail: String) -> VideoSettings? {
        guard !isShuttingDown, var live = session, live.settings.dynamicRange == .hdr10, let prefs = live.prefs else {
            return nil
        }
        let sdr = derive(live, from: prefs, allowHDR: false)
        live.settings = sdr
        live.configID = nextConfigID(after: live.configID)
        session = live
        log(.warning, "hdr_fallback", HDRLog.fallbackFields(reason: reason, detail: detail,
                                                            configID: live.configID, settings: sdr))
        onReconfigure(live.sessionID, sdr.streamConfig(configID: live.configID))
        return sdr
    }

    /// T-258: packed full colour whose Metal packer or auxiliary session could not be set up at pipeline start falls
    /// back like HDR does: announced with a new `config_id`, then the normal pipeline starts. true = handled.
    private func fallBackFromPackedSetup(failed: VideoSettings, error: Error) async -> Bool {
        guard failed.packedChroma, let setup = error as? PackedSetupError else { return false }
        await fallBackFromPackedChroma(reason: setup.reason, startFailed: true)
        return true
    }

    /// T-258 (decision 0034 section 7, PROTOCOL.md 0x05): the auxiliary encoder cannot keep up or failed. A new
    /// `config_id` with `chroma_layout = 0` (the main stream alone, normal 4:2:0, not sharp), `ev=chroma_fallback`.
    /// The user's choice is kept (`prefs`); the next stream mode change tries again.
    private func fallBackFromPackedChroma(reason: String, startFailed: Bool) async {
        guard !isShuttingDown, var live = session, live.settings.packedChroma, let prefs = live.prefs else { return }
        live.packedFallback = true
        let wanted = derive(live, from: prefs)
        live.settings = wanted
        live.configID = nextConfigID(after: live.configID)
        session = live
        videoLogger.log(.warning, PackedChromaFallbackLog.event, sessionID: live.sessionID, generation: live.configID,
                        fields: PackedChromaFallbackLog.fields(reason: reason, configID: live.configID))
        onReconfigure(live.sessionID, wanted.streamConfig(configID: live.configID))
        if startFailed {
            await perform(lease.sessionStarted(device: live.deviceID, settings: wanted))
        } else {
            await perform(lease.reconfigure(settings: wanted))
        }
    }

    /// T-214 (PROTOCOL.md 0x05): a 1x game display that cannot be set up falls back to the native display once. Game
    /// displays stay off for the rest of the process (`GameDisplayFallback`); the session's prefs are re-applied
    /// without the display, announced with a new `config_id` (`STREAM_CONFIG` + video close), and the native display
    /// is created (after `DisplayRecreateGap`, since the failed start just removed the game display). A failure of the
    /// native display does not fall back again.
    private func fallBackFromGameDisplay(failed: VideoSettings, error: Error) async -> Bool {
        let displayFailure = VideoPipeline.isDisplayFailure(error)
        let fallBack = gameDisplayLock.withLock { gameDisplay.startFailed(settings: failed, displayFailure: displayFailure) }
        guard fallBack, !isShuttingDown, var live = session, !live.settings.displayHiDPI, let prefs = live.prefs else {
            return false
        }
        let native = derive(live, from: prefs, allowGameDisplay: false)
        let old = live.settings
        live.settings = native
        live.configID = nextConfigID(after: live.configID)
        session = live
        log(.warning, "game_display_failed", "applied=\(native.displayModeText) requested=\(old.displayModeText) "
            + "config_id=\(live.configID) encoded=\(native.encodedWidthPx)x\(native.encodedHeightPx) "
            + "bitrate_kbps=\(native.bitrateKbps)")
        onReconfigure(live.sessionID, native.streamConfig(configID: live.configID))
        await perform(lease.sessionStarted(device: live.deviceID, settings: native))
        return true
    }

    /// T-081: the display went away (or could not be created) for a reason display sleep explains. With an accepted
    /// session, declare user activity (at most once per second) so the next retry finds the displays awake. Retries
    /// themselves are unchanged (`pipeline_retry`, the client's video reconnects).
    /// T-128: never while the system is going to sleep (that would cancel the sleep); `capture_source_lost` first
    /// waits `SleepWakeGate.captureLossDeferUs` for a sleep notification, since the displays go dark before it.
    private func wakeDisplayIfNeeded(_ reason: DisplayWakeReason?) {
        guard let reason, session != nil else { return }
        let now = HostClock.nowUs()
        let (request, attempt): (SleepWakeGate.Request, WakeAttempt) = gateLock.withLock {
            let request = sleepGate.request(reason, now: now)
            return (request, request == .wakeNow ? wakeDisplayLocked(reason, now: now) : .none)
        }
        switch request {
        case .wakeNow:
            logWake(attempt, reason: reason)
        case .deferred(let deadline):
            log(.info, "wake_display_deferred",
                "reason=\(reason.rawValue) defer_ms=\(SleepWakeGate.captureLossDeferUs / 1_000)")
            scheduleDeferredWake(at: deadline)
        case .pending:
            break
        case .suppressed(let shouldLog):
            if shouldLog { log(.info, "wake_display_suppressed", "reason=system_sleep lost=\(reason.rawValue)") }
        }
    }

    /// The deferral of a `capture_source_lost` is over: wake unless a sleep notification (or a recovered display, or
    /// the end of the session) came first. Woken early (clock skew): wait for the rest.
    private func onDeferredWakeDue() {
        let now = HostClock.nowUs()
        let sessionActive = session != nil
        let (reason, stillPending, attempt) = gateLock.withLock {
            () -> (DisplayWakeReason?, UInt64?, WakeAttempt) in
            guard let reason = sleepGate.due(now: now) else { return (nil, sleepGate.pendingDeadlineUs, .none) }
            return (reason, nil, sessionActive ? wakeDisplayLocked(reason, now: now) : .none)
        }
        if let reason {
            logWake(attempt, reason: reason)
        } else if let stillPending {
            scheduleDeferredWake(at: stillPending)
        }
    }

    private func scheduleDeferredWake(at deadlineUs: UInt64) {
        let now = HostClock.nowUs()
        let delayNs = deadlineUs > now ? (deadlineUs - now) * 1_000 : 0
        Task { [weak self] in
            if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
            self?.post(.deferredWakeDue, key: Self.deferredWakeKey)
        }
    }

    private enum WakeAttempt {
        case none
        case woke(log: Bool, wakes: Int)
        case failed(String)
    }

    /// T-081 rate limit, then the user-activity declaration. The caller holds `gateLock` and the gate has just
    /// approved the wake: the power handler takes the same lock before a sleep is acknowledged
    /// (`IOAllowPowerChange`), so a `will_sleep` cannot slip in between the decision and the declaration and have its
    /// sleep cancelled by it (T-128 review). Logging happens after the lock is released (`logWake`).
    private func wakeDisplayLocked(_ reason: DisplayWakeReason, now: UInt64) -> WakeAttempt {
        guard !sleepGate.sleeping else { return .none }
        let decision = wakePolicy.displayLost(reason, sessionActive: session != nil, now: now)
        guard case .wake(let shouldLog, let wakes) = decision else { return .none }
        if let failure = waker.declareUserActivity() { return .failed(failure) }
        return .woke(log: shouldLog, wakes: wakes)
    }

    private func logWake(_ attempt: WakeAttempt, reason: DisplayWakeReason) {
        switch attempt {
        case .none: break
        case .failed(let failure): log(.warning, "wake_display_failed", "reason=\(reason.rawValue) iokit=\(failure)")
        case .woke(let shouldLog, let wakes):
            if shouldLog { log(.info, "wake_display", "reason=\(reason.rawValue) wakes=\(wakes)") }
        }
    }

    // MARK: System power (T-128)

    /// Power observer queue, before the sleep is acknowledged. Updates the gate under `gateLock` (waiting for a wake
    /// declaration in progress, see `wakeDisplayLocked`; a pending deferred wake is dropped) and logs the state on
    /// change, with the wall clock to line it up with `pmset -g log`.
    private func onPower(_ event: PowerEvent) {
        let outcome = gateLock.withLock { sleepGate.power(event, now: HostClock.nowUs()) }
        let sid = liveSessionLock.withLock { liveSessionID } ?? 0
        if event == .didWake { post(.macWoke, key: Self.macWokeKey) }
        if outcome.logState {
            logger.log(.info, "power", sessionID: sid, generation: 0,
                       fields: "state=\(event.rawValue) wall_ms=\(Self.wallMs())")
        }
        if let lost = outcome.suppressedPending {
            logger.log(.info, "wake_display_suppressed", sessionID: sid, generation: 0,
                       fields: "reason=system_sleep lost=\(lost.rawValue)")
        }
    }

    private func logDisplaySleep(_ change: DisplaySleepAssertion.Change) {
        switch change {
        case .none: break
        case .held: log(.info, "display_sleep_assertion", "state=held")
        case .released: log(.info, "display_sleep_assertion", "state=released")
        case .failed(let code): log(.warning, "display_sleep_assertion_failed", "iokit=\(code)")
        }
    }

    private func destroyPipeline() async {
        await stopConsumer()
        let p = pipeline
        pipeline = nil
        noteStopped()
        await p?.stop()
    }

    /// Consumes and discards frames while nobody is connected, so the bounded queue never backs up.
    private func startDrain() {
        guard let frames = pipeline?.frames, let aux = pipeline?.auxFrames else { return }
        if case .none = consumer {} else { return }
        consumer = .drain(Task { while await frames.next() != nil {} }, Task { while await aux.next() != nil {} })
    }

    /// Every wait is bounded (T-325): the connection is closed first (that unblocks a pending write), then the sender or
    /// the drain tasks are awaited for at most `stopTimeout`. Past it `ev=consumer_stop_timeout` is logged and the
    /// shutdown goes on; the stuck task is cancelled and left behind.
    private func stopConsumer() async {
        let old = consumer
        consumer = .none
        switch old {
        case .none: break
        case .drain(let task, let auxTask):
            task.cancel()
            auxTask.cancel()
            let outcome = await BoundedWait.run(timeout: Self.stopTimeout) {
                await task.value
                await auxTask.value
            }
            if outcome == .timedOut { log(.error, "consumer_stop_timeout", "consumer=drain ms=\(Int(Self.stopTimeout * 1_000))") }
        case .sender(_, let sender, let link):
            link.cancel()
            let outcome = await BoundedWait.run(timeout: Self.stopTimeout) { await sender.stop() }
            if outcome == .timedOut { log(.error, "consumer_stop_timeout", "consumer=sender ms=\(Int(Self.stopTimeout * 1_000))") }
        }
    }

    private func log(_ level: LogLevel, _ event: String, _ fields: String = "") {
        logger.log(level, event, sessionID: session?.sessionID ?? 0, generation: session?.configID ?? 0, fields: fields)
    }
}
