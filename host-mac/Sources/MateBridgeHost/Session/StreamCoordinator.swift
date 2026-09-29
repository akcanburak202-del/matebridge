import Foundation
import MateBridgeCore

/// Glue between the session (T-010) and the video pipeline (T-011):
/// ACCEPTED -> virtual display + capture + HEVC -> video link, `KEYFRAME_REQUEST` -> encoder, `STATS` -> menu/log,
/// and the 10 s display grace period after a disconnect (`DisplayLease`).
///
/// All events go through one ordered stream and are handled one at a time, so `sessionStarted`, `videoAttached`
/// and `sessionEnded` can never overtake each other even though display creation is asynchronous.
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
        case sender(id: Int, VideoSender)
    }

    private struct ActiveSession {
        var sessionID: UInt32
        var configID: UInt16
        var deviceID: DeviceID
        var settings: VideoSettings
    }

    /// Menu text for the video/stats line ("" = nothing to show). Called on an arbitrary queue.
    public var onSummary: @Sendable (String) -> Void = { _ in }

    private let logger = SessionLogger(component: "net")
    private let continuation: AsyncStream<Event>.Continuation
    private let events: AsyncStream<Event>
    private var loop: Task<Void, Never>?
    private var tickTimer: DispatchSourceTimer?

    // Written by the session queue (makeStreamConfig), read by the event loop.
    private let pendingLock = NSLock()
    private var pendingHello: (device: DeviceID, settings: VideoSettings)?

    // Event-loop state (only touched from `handle`).
    private var lease: DisplayLease
    private var pipeline: VideoPipeline?
    private var pipelineID = 0
    private var consumer = Consumer.none
    private var consumerID = 0
    private var session: ActiveSession?
    private var lastSent = VideoSender.Counters()

    public init(graceUs: UInt64 = DisplayLease.defaultGraceUs) {
        lease = DisplayLease(graceUs: graceUs)
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
    }

    // MARK: Entry points (any thread)

    public func start() {
        guard loop == nil else { return }
        loop = Task { [self] in
            for await event in events { await handle(event) }
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.matebridge.stream.tick"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [continuation] in continuation.yield(.tick) }
        timer.resume()
        tickTimer = timer
    }

    /// `SessionServer` `makeStreamConfig`: the tablet's HELLO decides the display size. Called by the session
    /// machine right before it reports `sessionStarted`, so the pair (device, settings) stays consistent.
    public func streamConfig(for hello: Hello) -> StreamConfig {
        let settings = VideoSettings.forTablet(hello)
        pendingLock.lock()
        pendingHello = (hello.deviceID, settings)
        pendingLock.unlock()
        return settings.streamConfig(configID: Self.configID)
    }

    public func sessionStarted(sessionID: UInt32, configID: UInt16) {
        // Read now, on the session queue: makeStreamConfig ran just before this call for the same session.
        let hello = pendingLock.withLock { pendingHello }
        continuation.yield(.sessionStarted(sessionID: sessionID, configID: configID,
                                           device: hello?.device, settings: hello?.settings))
    }

    public func sessionEnded() { continuation.yield(.sessionEnded) }

    public func videoAttached(_ link: VideoLink) { continuation.yield(.videoAttached(link)) }

    /// Messages from the approved session; only `KEYFRAME_REQUEST` and `STATS` are handled here.
    public func deliver(_ message: Message) {
        switch message {
        case .keyframeRequest(let reason): continuation.yield(.keyframeRequest(reason))
        case .stats(let stats): continuation.yield(.stats(stats))
        default: break
        }
    }

    /// Stops sending, capture, the encoder and removes the virtual display. Waits up to `timeout` seconds.
    /// Do not call from the coordinator's own callbacks.
    public func shutdown(timeout: TimeInterval = 2) {
        tickTimer?.cancel()
        tickTimer = nil
        guard loop != nil else { return }
        let semaphore = DispatchSemaphore(value: 0)
        continuation.yield(.shutdown(done: { semaphore.signal() }))
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    // MARK: Event loop

    private func handle(_ event: Event) async {
        switch event {
        case .sessionStarted(let sid, let cid, let device, let settings):
            await onSessionStarted(sessionID: sid, configID: cid, device: device, settings: settings)
        case .sessionEnded:
            await onSessionEnded()
        case .videoAttached(let link):
            await onVideoAttached(link)
        case .keyframeRequest(let reason):
            log(.info, "keyframe_request", "reason=\(reason.rawValue)")
            pipeline?.requestKeyframe()
        case .stats(let stats):
            onStats(stats)
        case .tick:
            await perform(lease.tick(now: HostClock.nowUs()))
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
        session = ActiveSession(sessionID: sessionID, configID: configID, deviceID: device, settings: settings)
        log(.info, "stream_session", "width=\(settings.widthPx) height=\(settings.heightPx) fps=\(settings.fps) codec=hevc")
        await perform(lease.sessionStarted(device: device, settings: settings))
    }

    private func onSessionEnded() async {
        session = nil
        lastSent = VideoSender.Counters()
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
                                 onEnded: { [continuation] reason in continuation.yield(.senderEnded(id: id, reason)) })
        consumer = .sender(id: id, sender)
        lastSent = VideoSender.Counters()
        sender.start()
        log(.info, "video_streaming")
    }

    private func onSenderEnded(id: Int, reason: VideoSender.EndReason) async {
        guard case .sender(let current, _) = consumer, current == id else { return }
        consumer = .none
        log(.info, "video_sender_ended", "reason=\(reason)")
        if pipeline != nil { startDrain() }
    }

    private func onStats(_ stats: Stats) {
        let summary = StatsSummary(stats)
        var fields = summary.logFields
        if case .sender(_, let sender) = consumer {
            let now = sender.currentCounters
            let frames = now.framesSent - lastSent.framesSent
            let kbps = Double(now.bytesSent - lastSent.bytesSent) * 8 / 1000 * 1000 / Double(max(1, stats.intervalMs))
            fields += String(format: " sent_frames=%d sent_kbps=%.0f rejected=%d send_failures=%d",
                             frames, kbps, now.framesRejected, now.sendFailures)
            lastSent = now
        }
        log(.info, "stats", fields)
        onSummary(summary.menuText)
    }

    private func onPipelineFailed(id: Int, message: String) async {
        guard id == pipelineID, pipeline != nil else { return }
        log(.error, "pipeline_failed", "error=\(message)")
        await stopConsumer()
        pipeline = nil  // the pipeline already closed its display and queue
        lease.displayLost()
        onSummary("Video durdu: \(message)")
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
        pipelineID += 1
        let id = pipelineID
        let p = VideoPipeline(settings: settings, onFailure: { [continuation] error in
            continuation.yield(.pipelineFailed(id: id, message: "\(error)"))
        })
        do {
            try await p.start()
            pipeline = p
            startDrain()
            log(.info, "display_created", "width=\(settings.widthPx) height=\(settings.heightPx)")
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
        case .sender(_, let sender):
            await sender.stop()
        }
    }

    private func log(_ level: LogLevel, _ event: String, _ fields: String = "") {
        logger.log(level, event, sessionID: session?.sessionID ?? 0, generation: session?.configID ?? 0, fields: fields)
    }
}
