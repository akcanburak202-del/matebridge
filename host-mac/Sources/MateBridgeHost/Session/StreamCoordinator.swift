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
        case sessionStarted(sessionID: UInt32, configID: UInt16, device: DeviceID?, settings: VideoSettings?)
        case sessionEnded
        case videoAttached(VideoLink)
        case keyframeRequest(KeyframeReason)
        case stats(Stats)
        case tick
        case pipelineFailed(id: Int, message: String)
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
        var settings: VideoSettings
    }

    /// Menu text for the video/stats line ("" = nothing to show). Called on an arbitrary queue.
    public var onSummary: @Sendable (String) -> Void = { _ in }
    /// The lifecycle mailbox overflowed: end every session (release input, BYE) so the client reconnects cleanly.
    public var onOverflow: @Sendable () -> Void = {}

    private static let tickKey = 1, statsKey = 2, keyframeKey = 3

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

    public init(graceUs: UInt64 = DisplayLease.defaultGraceUs) {
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

    /// Settings of a session from its tablet's HELLO. Pure: nothing is remembered, so a HELLO that never becomes
    /// a session (an unproven reconnect) cannot change the settings of the live one.
    private static func settings(for hello: Hello) -> VideoSettings {
        var settings = VideoSettings.forTablet(hello)
        // Experiment knobs (T-017): MATEBRIDGE_REFRESH=60|120 (virtual display Hz), MATEBRIDGE_FRAME_DELAY=0|1.
        let env = ProcessInfo.processInfo.environment
        settings.displayRefreshHz = VideoSettings.parseRefreshHz(env["MATEBRIDGE_REFRESH"])
        settings.maxFrameDelayCount = VideoSettings.parseFrameDelay(env["MATEBRIDGE_FRAME_DELAY"])
        return settings
    }

    /// `SessionServer` `makeStreamConfig`: the tablet's HELLO decides the display size. Side-effect free (apart from
    /// a log line); the session machine may call it for a connection that never becomes the session.
    public func streamConfig(for hello: Hello) -> StreamConfig {
        let settings = Self.settings(for: hello)
        if settings.widthPx != Int(hello.screenWidthPx) || settings.heightPx != Int(hello.screenHeightPx) {
            logger.log(.warning, "display_size_differs_from_hello", sessionID: 0, generation: 0,
                       fields: "hello=\(hello.screenWidthPx)x\(hello.screenHeightPx) display=\(settings.widthPx)x\(settings.heightPx)")
        }
        return settings.streamConfig(configID: Self.configID)
    }

    /// The session is active (after proof, for a reconnect): only now are the settings derived from its HELLO.
    public func sessionStarted(sessionID: UInt32, configID: UInt16, hello: Hello) {
        post(.sessionStarted(sessionID: sessionID, configID: configID, device: hello.deviceID,
                             settings: Self.settings(for: hello)))
    }

    public func sessionEnded() { post(.sessionEnded) }

    public func videoAttached(_ link: VideoLink) { post(.videoAttached(link)) }

    /// Messages from the approved session; only `KEYFRAME_REQUEST` and `STATS` are handled here.
    public func deliver(_ message: Message) {
        switch message {
        case .keyframeRequest(let reason): post(.keyframeRequest(reason), key: Self.keyframeKey)
        case .stats(let stats): post(.stats(stats), key: Self.statsKey)
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
        case .sessionStarted(let sid, let cid, let device, let settings):
            await onSessionStarted(sessionID: sid, configID: cid, device: device, settings: settings)
        case .sessionEnded:
            await onSessionEnded()
        case .videoAttached(let link):
            await onVideoAttached(link)
        case .keyframeRequest(let reason):
            log(.info, "keyframe_request", "reason=\(reason.rawValue)")
            if pipeline?.requestKeyframe(reason: reason) == true {
                log(.info, "codec_config_resent", "reason=\(reason.rawValue)")
            }
        case .stats(let stats):
            onStats(stats)
        case .tick:
            await perform(lease.tick(now: HostClock.nowUs()))
            reportCadence()
        case .pipelineFailed(let id, let message):
            await onPipelineFailed(id: id, message: message)
        case .senderEnded(let id, let reason):
            await onSenderEnded(id: id, reason: reason)
        case .shutdown(let done):
            await onShutdown()
            done()
        }
    }

    private func onSessionStarted(sessionID: UInt32, configID: UInt16, device: DeviceID?,
                                  settings: VideoSettings?) async {
        guard let device, let settings else {
            log(.error, "session_without_config")
            return
        }
        // Takeover safety: a previous session that never reported its end no longer owns the consumer.
        pipelineRetried = false
        session = ActiveSession(sessionID: sessionID, configID: configID, deviceID: device, settings: settings)
        log(.info, "stream_session", "width=\(settings.widthPx) height=\(settings.heightPx) fps=\(settings.fps) codec=hevc")
        await perform(lease.sessionStarted(device: device, settings: settings))
    }

    private func onSessionEnded() async {
        session = nil
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
                                 onEnded: { [weak self] reason in self?.post(.senderEnded(id: id, reason)) })
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
        publishSummary()
    }

    private func publishSummary() {
        guard session != nil, case .sender = consumer else { return }
        onSummary([lastStatsText, lastCadenceText].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    private func onPipelineFailed(id: Int, message: String) async {
        guard id == pipelineID, pipeline != nil else { return }
        log(.error, "pipeline_failed", "error=\(message)")
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
            }
        }
    }

    private func createPipeline(settings: VideoSettings) async {
        guard !isShuttingDown else { return }
        pipelineID += 1
        let id = pipelineID
        let p = VideoPipeline(settings: settings, onFailure: { [weak self] error in
            self?.post(.pipelineFailed(id: id, message: "\(error)"))
        })
        do {
            try await p.start()
            if isShuttingDown {  // shutdown() ran while the display was being created
                await p.stop()
                return
            }
            pipeline = p
            startDrain()
            log(.info, "display_created", "width=\(settings.widthPx) height=\(settings.heightPx)")
            videoLogger.log(.info, "cadence_setup", sessionID: session?.sessionID ?? 0,
                            generation: session?.configID ?? 0, fields: p.cadenceSetup)
            onSummary("")
        } catch {
            log(.error, "display_create_failed", "error=\(error)")
            lease.displayLost()
            onSummary("Video başlamadı: \(error)")
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
