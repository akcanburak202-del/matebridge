import CoreGraphics
import Foundation
import MateBridgeCore

public enum VideoPipelineError: Error, CustomStringConvertible {
    case screenRecordingDenied
    case unsupportedCodec
    case alreadyStarted

    public var description: String {
        switch self {
        case .screenRecordingDenied: return ScreenCaptureError.permissionDenied.description
        case .unsupportedCodec: return "only HEVC is implemented"
        case .alreadyStarted: return "video pipeline was already started (create a new one to restart)"
        }
    }
}

/// Virtual display -> ScreenCaptureKit -> HEVC -> bounded queue (`frames`).
/// Does not touch the network: the session (T-014) consumes `frames` and wraps each frame in a `VIDEO_FRAME`.
///
/// Lifecycle: one `start()` per instance (a second call throws `alreadyStarted`); `stop()` is idempotent. If capture
/// or the encoder fails on its own, the pipeline stops itself (closing the virtual display and `frames`) and then
/// calls `onFailure` once, so the owner only needs to react, not clean up.
///
/// `captureTimeUs` of every frame is the host time clock (`CMClockGetHostTimeClock`, i.e. mach absolute time) in
/// microseconds. Session PING/PONG timestamps must use the same clock (PROTOCOL.md section 6).
public final class VideoPipeline: @unchecked Sendable {
    private enum State { case idle, starting, running, stopped }

    public let settings: VideoSettings
    /// Encoder output: CODEC_CONFIG first, then keyframe, then frames. At most 2 wait here.
    public let frames: VideoFrameQueue
    /// Cadence measurements (T-017): SCK arrival, encoder in/out, overwritten pending frames.
    public let meter: CadenceMeter
    /// Per-stage capture-to-sent latency (T-070); fed by the sender through `recordTrace`.
    public let latency = LatencyMeter()
    private let latencyCsv = LatencyCsv()

    private let lock = NSLock()
    private var state = State.idle
    private var display: VirtualDisplay?
    private var capture: ScreenCapture?
    private var encoder: HEVCEncoder?
    private var failureNotified = false
    private let tap: (@Sendable (EncodedVideoFrame, _ encodeTimeUs: UInt64) -> Void)?
    private let onFailure: @Sendable (Error) -> Void
    private let box: EncoderBox
    private var displayInfo = "no display"
    /// A display handed over by the previous pipeline (T-049): kept instead of creating a new one.
    private var inherited: VirtualDisplay?

    /// - Parameters:
    ///   - tap: observes every encoder output with its encode time, in encoder order (stats, dump tool).
    ///   - display: the virtual display of a pipeline that was stopped with `stopKeepingDisplay()`. It is kept when its refresh rate
    ///     already equals `settings.displayRefreshHz`, replaced by a new display otherwise.
    ///   - onFailure: capture or encoder failed unexpectedly (e.g. permission revoked); the pipeline is already stopped.
    init(settings: VideoSettings = .tabletDefault,
                tap: (@Sendable (EncodedVideoFrame, UInt64) -> Void)? = nil,
                reusing display: VirtualDisplay? = nil,
                onFailure: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.inherited = display
        self.settings = settings
        self.tap = tap
        self.onFailure = onFailure
        self.meter = CadenceMeter(fps: settings.fps)
        // The queue's keyframe callback needs the encoder, which exists only after start().
        let box = EncoderBox()
        self.box = box
        self.frames = VideoFrameQueue(keyframeNeeded: { box.requestKeyframe() })
    }

    /// Fills `STREAM_CONFIG` (pixel/point size, fps, bitrate, colour tags).
    public func streamConfig(configID: UInt16) -> StreamConfig { settings.streamConfig(configID: configID) }

    public func start() async throws {
        try beginStart()

        do {
            guard settings.codec == .hevc else { throw VideoPipelineError.unsupportedCodec }
            // Check before creating the display so a denied permission leaves nothing behind.
            guard ScreenCapture.hasPermission else { throw VideoPipelineError.screenRecordingDenied }

            let frames = self.frames
            let tap = self.tap
            let encoder = try HEVCEncoder(settings: settings, meter: meter, output: { frame, encodeUs in
                var frame = frame
                frame.trace.enqueuedUs = HostClock.nowUs()
                frames.push(frame)
                tap?(frame, encodeUs)
            }, onFailure: { [weak self] error in self?.fail(error) })
            box.encoder = encoder
            set { $0.encoder = encoder }

            let display = try await obtainDisplay()
            set { $0.displayInfo = "requested=\(display.requestedRefreshHz)Hz mode_selected=\(display.modeSelected) applied=\(display.appliedModeDescription)" }
            set { $0.display = display }
            let cap = ScreenCapture(meter: meter, handler: { [weak encoder] pb, pts, us, displayUs in
                encoder?.encode(pb, presentationTime: pts, captureTimeUs: us, displayTimeUs: displayUs)
            }, onStop: { [weak self] error in self?.fail(error) })
            set { $0.capture = cap }
            // ScreenCaptureKit needs about a second to see a new display.
            var lastError: Error?
            for _ in 0..<20 {
                do { try await cap.start(displayID: display.displayID, settings: settings); lastError = nil; break }
                catch ScreenCaptureError.displayNotFound(let id) {
                    lastError = ScreenCaptureError.displayNotFound(id)
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            if let lastError { throw lastError }

            meter.start(nowUs: HostClock.nowUs())
            let stoppedMeanwhile = markRunning()
            if stoppedMeanwhile { await teardown() }  // stop() raced with start(): release what start() created
        } catch {
            await stop()
            await teardown()
            throw error
        }
    }

    /// The inherited display when it already runs at the wanted refresh rate (capture and encoder restart only);
    /// otherwise a new display. ScreenCaptureKit keeps delivering at the old rate after an in-place mode switch
    /// (measured, T-049: 60 fps after 60 -> 120 Hz even for a new SCStream, 126 fps on a display created at 120 Hz),
    /// so a refresh change needs a new display. The old one must be gone first: a second display with the same
    /// vendor/product/serial cannot be created while it exists. The short wait lets the system finish removing it.
    private func obtainDisplay() async throws -> VirtualDisplay {
        let rate = Double(settings.displayRefreshHz)
        if let old = lock.withLock({ () -> VirtualDisplay? in defer { inherited = nil }; return inherited }) {
            if old.requestedRefreshHz == rate { return old }
            old.invalidate()
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        return try VirtualDisplay(name: "MateBridge", pixelWidth: settings.widthPx, pixelHeight: settings.heightPx,
                                  hidpi: true, refreshRate: rate)
    }

    /// Closes the current cadence window (call about once a second). `sentTotal` is the sender's cumulative
    /// frame count.
    public func cadenceWindow(sentTotal: Int) -> CadenceWindow {
        meter.take(nowUs: HostClock.nowUs(), queueDropsTotal: frames.droppedCount, sentTotal: sentTotal)
    }

    /// Closes the current latency window (call with the cadence window, about once a second).
    public func latencyWindow() -> LatencyWindow { latency.take() }

    /// A frame's write completed (called from the sender): feeds the latency window and the optional CSV.
    public func recordTrace(_ trace: FrameTrace) {
        latency.record(trace)
        latencyCsv?.append(trace)
    }

    /// Virtual display mode requested vs. applied, and the encoder's cadence-related properties, for the log.
    public var cadenceSetup: String {
        let props = box.encoder?.propertyReport.joined(separator: ",") ?? "none"
        return "display[\(lock.withLock { displayInfo })] stream_fps=\(settings.fps) "
            + "encoder_set[\(props)] encoder_read[\(box.encoder?.cadenceReadback() ?? "none")] "
            + "keyframe_interval_s=\(HEVCEncoder.keyframeIntervalSeconds) sck_min_interval_ms=\(String(format: "%.2f", 500 / Double(max(1, settings.fps)))) sck_queue_depth=\(ScreenCapture.queueDepth)"
    }

    /// Applies the tablet panel rate (`DISPLAY_RATE`): the encoder feed is decimated to `min(stream fps, hz)` without
    /// restarting anything. Remembered, so an encoder created later starts at the same rate. Returns the effective fps.
    @discardableResult
    public func setDisplayRate(hz: Int) -> Int {
        let fps = DisplayRateState.effectiveFps(streamFps: settings.fps, hz: hz)
        box.encoder?.setTargetFps(fps)
        meter.setTargetFps(fps)
        return fps
    }

    public func requestKeyframe() { box.encoder?.requestKeyframe(resubmitNow: true) }

    /// Handles a client `KEYFRAME_REQUEST`. For reasons that imply a rebuilt decoder (`resendsCodecConfig`) the
    /// current `CODEC_CONFIG` is queued first and the queue is reset to hold only it, and only then is the keyframe
    /// forced; the keyframe is therefore always pushed behind the config. Returns true if a config was re-sent
    /// (false when the reason does not need it or no parameter sets exist yet: keyframe only, as before).
    @discardableResult
    public func requestKeyframe(reason: KeyframeReason) -> Bool {
        let encoder = box.encoder
        var resent = false
        if reason.resendsCodecConfig {
            // The snapshot is taken under the queue lock, so an encoder-announced config cannot fall between it
            // and the reset (lock order: queue -> encoder; the encoder never calls push while holding its lock).
            resent = frames.resync(config: { encoder?.currentCodecConfig() })
        }
        encoder?.requestKeyframe(resubmitNow: true)
        return resent
    }

    /// Call when a new consumer attaches: the queue is reset to hold only [CODEC_CONFIG], stale delta frames are
    /// refused, and a keyframe is forced (also on a static screen, by re-encoding the last captured buffer). The
    /// consumer therefore sees CODEC_CONFIG, then a keyframe, then frames.
    public func prepareForNewConsumer() {
        let encoder = box.encoder
        frames.startNewConsumer(configProvider: { encoder?.currentCodecConfig() })
        encoder?.requestKeyframe(resubmitNow: true)
    }

    /// Colour tags the encoder session reports (VUI source), for diagnostics.
    public var encoderColorReadback: String { box.encoder?.colorReadback() ?? "no encoder" }

    /// `VTSessionSetProperty` failures at encoder creation (empty when all were accepted).
    public var encoderPropertyFailures: [String] { box.encoder?.propertyFailures ?? [] }

    /// Stops capture, flushes and closes the encoder, removes the virtual display, ends the queue. Idempotent.
    public func stop() async {
        guard markStopped() else { return }
        await teardown()
    }

    /// Stops capture, the encoder and the queue like `stop()`, but hands the virtual display over (still alive) for the
    /// next pipeline. nil when the pipeline was stopped already or never had a display.
    func stopKeepingDisplay() async -> VirtualDisplay? {
        guard markStopped() else { return nil }
        return await teardown(keepingDisplay: true)
    }

    // Synchronous lock helpers (NSLock cannot be used directly in async functions).
    private func beginStart() throws {
        try lock.withLock {
            guard state == .idle else { throw VideoPipelineError.alreadyStarted }
            state = .starting
        }
    }
    private func set(_ f: (VideoPipeline) -> Void) { lock.withLock { f(self) } }
    /// Returns true if stop() already ran.
    private func markRunning() -> Bool {
        lock.withLock { if state == .stopped { return true }; state = .running; return false }
    }
    /// Returns false if already stopped.
    private func markStopped() -> Bool {
        lock.withLock { if state == .stopped { return false }; state = .stopped; return true }
    }
    private func takeResources() -> (ScreenCapture?, HEVCEncoder?, VirtualDisplay?) {
        lock.withLock {
            defer { capture = nil; encoder = nil; display = nil }
            return (capture, encoder, display)
        }
    }

    @discardableResult
    private func teardown(keepingDisplay: Bool = false) async -> VirtualDisplay? {
        let (cap, enc, disp) = takeResources()
        await cap?.stop()
        enc?.stop()
        box.encoder = nil
        frames.finish()
        if keepingDisplay { return disp }
        disp?.invalidate()
        return nil
    }

    /// Unexpected failure: tear down, then tell the owner once.
    private func fail(_ error: Error) {
        lock.lock()
        let first = !failureNotified && state != .stopped
        failureNotified = true
        lock.unlock()
        guard first else { return }
        Task { [self] in
            await stop()
            onFailure(error)
        }
    }
}

private final class EncoderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _encoder: HEVCEncoder?
    var encoder: HEVCEncoder? {
        get { lock.lock(); defer { lock.unlock() }; return _encoder }
        set { lock.lock(); _encoder = newValue; lock.unlock() }
    }
    func requestKeyframe() { encoder?.requestKeyframe() }
}
