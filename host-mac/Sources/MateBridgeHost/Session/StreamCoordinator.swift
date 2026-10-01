import Foundation
import MateBridgeCore

/// Glue between the session (T-010) and the video pipeline (T-011):
/// ACCEPTED -> virtual display + capture + HEVC -> video link, `KEYFRAME_REQUEST` -> encoder, `STATS` -> menu/log,
/// and the 10 s display grace period after a disconnect (`DisplayLease`).
///
/// All events go through one bounded, ordered mailbox and are handled one at a time, so `sessionStarted`,
/// `videoAttached` and `sessionEnded` can never overtake each other even though display creation is asynchronous.
/// STATS, KEYFRAME_REQUEST and ticks are coalesced (latest wins); lifecycle events are capped, and on overflow the
/// sessions are ended via `onOverflow` instead of growing memory.
/// Methods are safe to call from any thread (they only enqueue).
public final class StreamCoordinator: @unchecked Sendable {
    public static let configID: UInt16 = 1

    private enum Event: Sendable {
        case sessionStarted(sessionID: UInt32, configID: UInt16, device: DeviceID?, settings: VideoSettings?,
                          base: VideoSettings?)
        case sessionEnded
        case videoAttached(VideoLink)
        case keyframeRequest(KeyframeReason)
        case streamPrefs(sessionID: UInt32, StreamPrefs)
        case displayRate(sessionID: UInt32, hz: UInt16)
        case stats(Stats)
        case tick
        case pipelineFailed(id: Int, message: String, wake: DisplayWakeReason?)
        case senderEnded(id: Int, VideoSender.EndReason)
        case shutdown(done: @Sendable () -> Void)
    }

    private enum Consumer {
        case none
        case drain(Task<Void, Never>)
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
    }

    /// Menu text for the video/stats line ("" = nothing to show). Called on an arbitrary queue.
    public var onSummary: @Sendable (String) -> Void = { _ in }
    /// The stream settings of a live session changed (`STREAM_PREFS`): the session layer sends this `STREAM_CONFIG`
    /// (new `config_id`) and closes the video connection (PROTOCOL.md 3.7). Called on an arbitrary queue, before the
    /// capture and encoder are rebuilt, so a video connection that reopens early waits in the mailbox.
    public var onReconfigure: @Sendable (_ sessionID: UInt32, _ config: StreamConfig) -> Void = { _, _ in }
    /// The lifecycle mailbox overflowed: end every session (release input, BYE) so the client reconnects cleanly.
    public var onOverflow: @Sendable () -> Void = {}

    private static let tickKey = 1, statsKey = 2, keyframeKey = 3
    private static func prefsKey(_ sessionID: UInt32) -> Int { (1 << 40) + Int(sessionID) }
    private static func displayRateKey(_ sessionID: UInt32) -> Int { (2 << 40) + Int(sessionID) }

    private let logger = SessionLogger(component: "net")
    private let videoLogger = SessionLogger(component: "video")
    private let mailbox = BoundedMailbox<Event>(capacity: 16)
    private let shutdownLock = NSLock()
    private var shuttingDown = false
    private var loop: Task<Void, Never>?
    private var tickTimer: DispatchSourceTimer?

    // Event-loop state (only touched from `handle`).
    private var lease: DisplayLease
    private var pipeline: VideoPipeline?
    private var pipelineID = 0
    private var consumer = Consumer.none
    private var consumerID = 0
    private var session: ActiveSession?
    private var lastSent = VideoSender.Counters()
    private var pipelineRetried = false
    private var lastStatsText = ""
    private var lastCadenceText = ""
    private var prefsGate = StreamPrefsGate()
    /// Tablet panel rate from `DISPLAY_RATE` (T-058), and the last (hz, effective fps) that was logged.
    private var rateState = DisplayRateState()
    private var lastLoggedRate: (hz: Int, fps: Int)?
    /// T-081: wakes the displays when the pipeline loses its display to display sleep during a session.
    private var wakePolicy = DisplayWakePolicy()
    private let waker = DisplayWaker()
    /// Session id of the live session as seen by the entry points (any thread); nil between sessions.
    private let liveSessionLock = NSLock()
    private var liveSessionID: UInt32?

    private let prefsStore: StreamPrefsStoring

    public convenience init(graceUs: UInt64 = DisplayLease.defaultGraceUs) {
        self.init(graceUs: graceUs, prefsStore: UserDefaultsStreamPrefsStore())
    }

    init(graceUs: UInt64, prefsStore: StreamPrefsStoring) {
        self.prefsStore = prefsStore
        lease = DisplayLease(graceUs: graceUs)
    }

    private var isShuttingDown: Bool { shutdownLock.withLock { shuttingDown } }

    /// Coalescing merge: keyframe requests keep the strongest pending requirement (see `KeyframeReason.merged`);
    /// every other coalesced event is latest-wins.
    private static func mergeEvents(pending: Event, incoming: Event) -> Event {
        if case .keyframeRequest(let old) = pending, case .keyframeRequest(let new) = incoming {
            return .keyframeRequest(KeyframeReason.merged(pending: old, incoming: new))
        }
        return incoming
    }

    private func post(_ event: Event, key: Int? = nil, forced: Bool = false) {
        guard mailbox.post(event, coalesceKey: key, forced: forced, merge: Self.mergeEvents) == .overflow else { return }
        logger.log(.error, "event_overflow", sessionID: 0, generation: 0)
        var dropped = mailbox.removeAll()
        dropped.append(event)
        for e in dropped {
            switch e {
            case .videoAttached(let link): link.cancel()
            case .shutdown: mailbox.post(e, forced: true)  // never lose the shutdown request
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
                while let event = mailbox.take() { await handle(event) }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.matebridge.stream.tick"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.post(.tick, key: Self.tickKey) }
        timer.resume()
        tickTimer = timer
    }

    /// Settings of a session from its tablet's HELLO: `base` (HELLO + experiment knobs) and `initial` (`base` with
    /// the device's remembered `STREAM_PREFS` on top, so a reconnect starts in the last chosen mode). Pure apart from
    /// reading the store: nothing is remembered here, so a HELLO that never becomes a session (an unproven reconnect)
    /// cannot change the settings of the live one.
    private func settings(for hello: Hello) -> (base: VideoSettings, initial: VideoSettings) {
        // Experiment knobs (T-017, T-045): MATEBRIDGE_FPS=60|90|120, MATEBRIDGE_BITRATE_KBPS, MATEBRIDGE_REFRESH=60|120,
        // MATEBRIDGE_FRAME_DELAY=0|1; T-086: MATEBRIDGE_CODEC=h264|hevc, and the env bitrate wins over STREAM_PREFS.
        let env = ProcessInfo.processInfo.environment
        let base = VideoSettings.forTablet(hello).applyingExperimentKnobs(env)
        let initial = VideoSettings.initialSettings(
            defaults: base, stored: prefsStore.load(device: hello.deviceID),
            defaultRefreshHz: VideoSettings.parseRefreshHz(env["MATEBRIDGE_REFRESH"]))
        return (base, initial)
    }

    /// `SessionServer` `makeStreamConfig`: the tablet's HELLO decides the display size. Side-effect free (apart from
    /// a log line); the session machine may call it for a connection that never becomes the session.
    public func streamConfig(for hello: Hello) -> StreamConfig {
        let settings = self.settings(for: hello).initial
        if settings.widthPx != Int(hello.screenWidthPx) || settings.heightPx != Int(hello.screenHeightPx) {
            logger.log(.warning, "display_size_differs_from_hello", sessionID: 0, generation: 0,
                       fields: "hello=\(hello.screenWidthPx)x\(hello.screenHeightPx) display=\(settings.widthPx)x\(settings.heightPx)")
        }
        return settings.streamConfig(configID: Self.configID)
    }

    /// The session is active (after proof, for a reconnect): only now are the settings derived from its HELLO.
    public func sessionStarted(sessionID: UInt32, configID: UInt16, hello: Hello) {
        liveSessionLock.withLock { liveSessionID = sessionID }
        let (base, initial) = settings(for: hello)
        post(.sessionStarted(sessionID: sessionID, configID: configID, device: hello.deviceID,
                             settings: initial, base: base))
    }

    public func sessionEnded() {
        liveSessionLock.withLock { liveSessionID = nil }
        post(.sessionEnded)
    }

    public func videoAttached(_ link: VideoLink) { post(.videoAttached(link)) }

    /// Messages from the approved session; only `KEYFRAME_REQUEST` and `STATS` are handled here.
    public func deliver(_ message: Message) {
        switch message {
        case .keyframeRequest(let reason): post(.keyframeRequest(reason), key: Self.keyframeKey)
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
        guard loop != nil else { return }
        let semaphore = DispatchSemaphore(value: 0)
        post(.shutdown(done: { semaphore.signal() }), forced: true)
        _ = semaphore.wait(timeout: .now() + timeout)
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
        case .sessionStarted(let sid, let cid, let device, let settings, let base):
            await onSessionStarted(sessionID: sid, configID: cid, device: device, settings: settings, base: base)
        case .sessionEnded:
            await onSessionEnded()
        case .videoAttached(let link):
            await onVideoAttached(link)
        case .keyframeRequest(let reason):
            log(.info, "keyframe_request", "reason=\(reason.rawValue)")
            if pipeline?.requestKeyframe(reason: reason) == true {
                log(.info, "codec_config_resent", "reason=\(reason.rawValue)")
            }
        case .streamPrefs(let sid, let prefs):
            await onStreamPrefs(prefs, sessionID: sid)
        case .displayRate(let sid, let hz):
            onDisplayRate(hz, sessionID: sid)
        case .stats(let stats):
            onStats(stats)
        case .tick:
            let now = HostClock.nowUs()
            await perform(lease.tick(now: now))
            if let waiting = prefsGate.poll(now: now) { await applyPrefs(waiting) }
            reportCadence()
        case .pipelineFailed(let id, let message, let wake):
            await onPipelineFailed(id: id, message: message, wake: wake)
        case .senderEnded(let id, let reason):
            await onSenderEnded(id: id, reason: reason)
        case .shutdown(let done):
            await onShutdown()
            done()
        }
    }

    private func onSessionStarted(sessionID: UInt32, configID: UInt16, device: DeviceID?,
                                  settings: VideoSettings?, base: VideoSettings?) async {
        guard let device, let settings, let base else {
            log(.error, "session_without_config")
            return
        }
        // Takeover safety: a previous session that never reported its end no longer owns the consumer.
        pipelineRetried = false
        session = ActiveSession(sessionID: sessionID, configID: configID, deviceID: device, settings: settings,
                                base: base)
        prefsGate = StreamPrefsGate()
        resetDisplayRate()
        log(.info, "stream_session", "device=\(device.shortHex) from_stored=\(settings != base) "
            + "width=\(settings.encodedWidthPx) height=\(settings.encodedHeightPx) fps=\(settings.fps) refresh_hz=\(settings.displayRefreshHz) bitrate_kbps=\(settings.bitrateKbps) bitrate_source=\(settings.bitrateSource) codec=\(settings.codec.logName)")
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
        log(.info, "stream_prefs", "fps=\(p.fps) scale=\(p.scalePermille) requested_fps=\(prefs.fps) requested_scale=\(prefs.scalePermille)")
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
    /// refresh rate changes (`VideoPipeline` recreates it then, SCK cannot follow an in-place mode switch).
    private func applyPrefs(_ prefs: StreamPrefs) async {
        guard var live = session else { return }
        let env = ProcessInfo.processInfo.environment
        let wanted = live.base.applying(prefs, defaultRefreshHz: VideoSettings.parseRefreshHz(env["MATEBRIDGE_REFRESH"]))
        prefsStore.save(prefs, device: live.deviceID)  // the next connection of this tablet starts in this mode
        guard wanted != live.settings else { return }
        let old = live.settings
        live.settings = wanted
        live.configID = nextConfigID(after: live.configID)
        session = live
        prefsGate.markApplied(now: HostClock.nowUs())
        log(.info, "stream_reconfigure",
            "config_id=\(live.configID) fps=\(old.fps)->\(wanted.fps) scale=\(old.scalePermille)->\(wanted.scalePermille) "
            + "encoded=\(wanted.encodedWidthPx)x\(wanted.encodedHeightPx) refresh_hz=\(old.displayRefreshHz)->\(wanted.displayRefreshHz) "
            + "bitrate_kbps=\(wanted.bitrateKbps) bitrate_source=\(wanted.bitrateSource)")
        onReconfigure(live.sessionID, wanted.streamConfig(configID: live.configID))
        await perform(lease.reconfigure(settings: wanted))
    }

    private func onSessionEnded() async {
        session = nil
        wakePolicy.sessionEnded()
        resetDisplayRate()
        lastSent = VideoSender.Counters()
        lastStatsText = ""
        lastCadenceText = ""
        await stopConsumer()
        lease.sessionEnded(now: HostClock.nowUs())
        if pipeline != nil {
            startDrain()
            log(.info, "display_grace_started", "seconds=\(lease.graceUs / 1_000_000)")
        }
        onSummary("")
    }

    private func onVideoAttached(_ link: VideoLink) async {
        guard let s = session, link.sessionID == s.sessionID, link.configID == s.configID else {
            log(.warning, "video_without_session")
            link.cancel()
            return
        }
        if pipeline == nil {  // earlier creation failed or the pipeline died: try again
            _ = lease.sessionStarted(device: s.deviceID, settings: s.settings)
            await createPipeline(settings: s.settings)
        }
        guard let pipeline else { link.cancel(); return }
        await stopConsumer()
        pipeline.prepareForNewConsumer()
        consumerID += 1
        let id = consumerID
        let sender = VideoSender(transport: link, frames: pipeline.frames,
                                 requestKeyframe: { [weak pipeline] in pipeline?.requestKeyframe() },
                                 onEnded: { [weak self] reason in self?.post(.senderEnded(id: id, reason)) },
                                 trace: { [weak pipeline] t in pipeline?.recordTrace(t) },
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
        publishSummary()
    }

    private func publishSummary() {
        guard session != nil, case .sender = consumer else { return }
        onSummary([lastStatsText, lastCadenceText].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    private func onPipelineFailed(id: Int, message: String, wake: DisplayWakeReason?) async {
        guard id == pipelineID, pipeline != nil else { return }
        log(.error, "pipeline_failed", "error=\(message)")
        wakeDisplayIfNeeded(wake)  // before the retry backoff, so the displays are up when it runs
        await stopConsumer()
        pipeline = nil  // the pipeline already closed its display and queue
        lease.displayLost()
        onSummary("Video durdu: \(message)")
        // With a live session, rebuild once after a short backoff; the cancelled video link makes the client
        // reconnect its video connection, which then gets a sender.
        guard let live = session, !pipelineRetried, !isShuttingDown else { return }
        pipelineRetried = true
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !isShuttingDown, pipeline == nil else { return }
        log(.info, "pipeline_retry")
        _ = lease.sessionStarted(device: live.deviceID, settings: live.settings)
        await createPipeline(settings: live.settings)
    }

    private func onShutdown() async {
        _ = lease.shutdown()
        session = nil
        wakePolicy.sessionEnded()
        await destroyPipeline()
        onSummary("")
    }

    // MARK: Display and consumers

    private func perform(_ actions: [DisplayLease.Action]) async {
        for action in actions {
            switch action {
            case .teardown:
                log(.info, "display_teardown")
                await destroyPipeline()
            case .create(let s):
                await createPipeline(settings: s)
            case .reuse:
                log(.info, "display_reused")
            case .reconfigure(let s):
                log(.info, "display_reused", "restart=true fps=\(s.fps) refresh_hz=\(s.displayRefreshHz)")
                await restartPipeline(settings: s)
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
        if old.settings.displayRefreshHz != settings.displayRefreshHz {
            log(.info, "display_recreate", "reason=refresh_change refresh_hz=\(old.settings.displayRefreshHz)->\(settings.displayRefreshHz)")
        }
        let display = await old.stopKeepingDisplay()
        await createPipeline(settings: settings, reusing: display)
    }

    private func createPipeline(settings: VideoSettings, reusing display: VirtualDisplay? = nil) async {
        guard !isShuttingDown else { return }
        pipelineID += 1
        let id = pipelineID
        let p = VideoPipeline(settings: settings, reusing: display, onFailure: { [weak self] error in
            self?.post(.pipelineFailed(id: id, message: "\(error)", wake: DisplayWaker.reason(for: error)))
        })
        do {
            try await p.start()
            if isShuttingDown {  // shutdown() ran while the display was being created
                await p.stop()
                return
            }
            pipeline = p
            wakePolicy.recovered()
            if rateState.hz != 0 { applyDisplayRate(streamFps: settings.fps) }
            startDrain()
            log(.info, "display_created", "width=\(settings.widthPx) height=\(settings.heightPx) encoded=\(settings.encodedWidthPx)x\(settings.encodedHeightPx)")
            videoLogger.log(.info, "cadence_setup", sessionID: session?.sessionID ?? 0,
                            generation: session?.configID ?? 0, fields: p.cadenceSetup)
            onSummary("")
        } catch {
            log(.error, "display_create_failed", "error=\(error)")
            lease.displayLost()
            wakeDisplayIfNeeded(DisplayWaker.reason(for: error))
            onSummary("Video başlamadı: \(error)")
        }
    }

    /// T-081: the display went away (or could not be created) for a reason display sleep explains. With an accepted
    /// session, declare user activity (at most once per second) so the next retry finds the displays awake. Retries
    /// themselves are unchanged (`pipeline_retry`, the client's video reconnects).
    private func wakeDisplayIfNeeded(_ reason: DisplayWakeReason?) {
        guard let reason else { return }
        let decision = wakePolicy.displayLost(reason, sessionActive: session != nil, now: HostClock.nowUs())
        guard case .wake(let shouldLog, let wakes) = decision else { return }
        if let failure = waker.declareUserActivity() {
            log(.warning, "wake_display_failed", "reason=\(reason.rawValue) iokit=\(failure)")
        } else if shouldLog {
            log(.info, "wake_display", "reason=\(reason.rawValue) wakes=\(wakes)")
        }
    }

    private func destroyPipeline() async {
        await stopConsumer()
        let p = pipeline
        pipeline = nil
        await p?.stop()
    }

    /// Consumes and discards frames while nobody is connected, so the bounded queue never backs up.
    private func startDrain() {
        guard let frames = pipeline?.frames else { return }
        if case .none = consumer {} else { return }
        consumer = .drain(Task { while await frames.next() != nil {} })
    }

    private func stopConsumer() async {
        let old = consumer
        consumer = .none
        switch old {
        case .none: break
        case .drain(let task):
            task.cancel()
            await task.value
        case .sender(_, let sender, let link):
            await sender.stop()
            link.cancel()
        }
    }

    private func log(_ level: LogLevel, _ event: String, _ fields: String = "") {
        logger.log(level, event, sessionID: session?.sessionID ?? 0, generation: session?.configID ?? 0, fields: fields)
    }
}
