import CoreGraphics
import Foundation
import MateBridgeCore

public enum VideoPipelineError: Error, CustomStringConvertible {
    case screenRecordingDenied
    case unsupportedCodec
    case alreadyStarted
    /// The 1x game display (decision 0029) was created but its mode could not be made current.
    case gameDisplayUnavailable

    public var description: String {
        switch self {
        case .screenRecordingDenied: return ScreenCaptureError.permissionDenied.description
        case .unsupportedCodec: return "only HEVC and H.264 are implemented"
        case .alreadyStarted: return "video pipeline was already started (create a new one to restart)"
        case .gameDisplayUnavailable: return "1x game display mode could not be selected"
        }
    }
}

/// A ring of the HDR10 path (decision 0032) refused HDR at pipeline start: the owner re-applies the prefs as SDR
/// (`HDRFallback`, `ev=hdr_fallback`). Never a `VirtualDisplayError`, so it does not trigger the game display fallback.
struct HDRSetupError: Error, CustomStringConvertible {
    let reason: HDRFallbackReason
    /// Short cause for the log (`VirtualDisplayTransfer.FallbackReason`, `Name=<OSStatus>`, the SCK error).
    let detail: String

    var description: String { "HDR10 unavailable (\(reason.rawValue): \(detail))" }
}

/// Packed full colour (decision 0034, T-258) could not be set up at pipeline start (Metal, the auxiliary VideoToolbox
/// session): the owner announces `chroma_layout = 0` under a new `config_id` (`ev=chroma_fallback`). Never a
/// `VirtualDisplayError`, so it does not trigger the game display fallback.
struct PackedSetupError: Error, CustomStringConvertible {
    let reason: String
    let detail: String

    var description: String { "packed full colour unavailable (\(reason): \(detail))" }
}

/// Virtual display -> ScreenCaptureKit -> HEVC or H.264 (`settings.codec`, T-086) -> bounded queue (`frames`).
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
    /// Packed full colour (decision 0034): the auxiliary stream's encoder output, same bounds as `frames`. Empty (and
    /// unused) without it.
    public let auxFrames: VideoFrameQueue
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
    private let onPackedFallback: @Sendable (String) -> Void
    private let box: EncoderBox
    /// The auxiliary stream's own T-122 coalescer and queue watcher (T-258): no new auxiliary IDR while one is queued or
    /// in flight.
    private let auxKeyframes: KeyframeGate
    private let auxBox: EncoderBox
    /// T-258: the auxiliary encoder's loss rule, fed once a second (`checkPackedWindow`).
    private let packedMonitor = PackedMonitorBox()
    /// Still-screen refinement settings (T-253); `.disabled` unless the owner passes the session's.
    private let refine: StillRefineConfig
    /// Client keyframe requests are coalesced here (T-122).
    private let keyframes: KeyframeGate
    private var displayInfo = "no display"
    /// A display handed over by the previous pipeline (T-049) or parked by the owner (T-165): kept instead of
    /// creating a new one.
    private var inherited: VirtualDisplay?
    private var reusedDisplay = false

    /// - Parameters:
    ///   - tap: observes every encoder output with its encode time, in encoder order (stats, dump tool).
    ///   - display: the virtual display of a pipeline that was stopped with `stopKeepingDisplay()`. It is kept when its
    ///     pixel size, HiDPI and refresh rate already equal the settings' and it is still online (`DisplayReuse`),
    ///     replaced by a new display otherwise.
    ///   - refine: still-screen refinement (T-253, `StillRefineConfig.resolve`); off by default.
    ///   - onFailure: capture or encoder failed unexpectedly (e.g. permission revoked); the pipeline is already stopped.
    init(settings: VideoSettings = .tabletDefault,
                tap: (@Sendable (EncodedVideoFrame, UInt64) -> Void)? = nil,
                reusing display: VirtualDisplay? = nil,
                refine: StillRefineConfig = .disabled,
                onPackedFallback: @escaping @Sendable (String) -> Void = { _ in },
                onFailure: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.onPackedFallback = onPackedFallback
        self.inherited = display
        self.refine = refine
        self.settings = settings
        self.tap = tap
        self.onFailure = onFailure
        self.meter = CadenceMeter(fps: settings.fps)
        // The queue's keyframe callback needs the encoder, which exists only after start().
        let keyframes = KeyframeGate()
        self.keyframes = keyframes
        let box = EncoderBox(keyframes: keyframes)
        self.box = box
        let frames = VideoFrameQueue(keyframeNeeded: { box.queueDropped() })
        self.frames = frames
        box.frames = frames
        // An auxiliary overflow only breaks the auxiliary chain: an auxiliary keyframe, no coalescing needed (the
        // queue refuses auxiliary deltas until it arrives, so one request per hole).
        let auxGate = KeyframeGate()
        auxKeyframes = auxGate
        let auxBox = EncoderBox(keyframes: auxGate, view: .auxiliary)
        self.auxBox = auxBox
        let auxFrames = VideoFrameQueue(keyframeNeeded: { auxBox.queueDropped() })
        self.auxFrames = auxFrames
        auxBox.frames = auxFrames
    }

    /// Fills `STREAM_CONFIG` (pixel/point size, fps, bitrate, colour tags).
    public func streamConfig(configID: UInt16) -> StreamConfig { settings.streamConfig(configID: configID) }

    public func start() async throws {
        try beginStart()

        do {
            guard settings.codec == .hevc || settings.codec == .h264 else { throw VideoPipelineError.unsupportedCodec }
            // Check before creating the display so a denied permission leaves nothing behind.
            guard ScreenCapture.hasPermission else { throw VideoPipelineError.screenRecordingDenied }

            let frames = self.frames
            let tap = self.tap
            let encoder = try HEVCEncoder(settings: settings, meter: meter, refine: refine,
                                          refineReady: { [auxFrames, packed = settings.packedChroma] in
                                              RefineReadiness.ready(mainReady: frames.isReadyForRefine,
                                                                    auxReady: auxFrames.isReadyForRefine, packed: packed)
                                          }, output: { frame, encodeUs in
                var frame = frame
                frame.trace.enqueuedUs = HostClock.nowUs()
                frames.push(frame)
                tap?(frame, encodeUs)
            }, auxOutput: { [auxFrames, auxKeyframes] frame, _ in
                var frame = frame
                frame.trace.enqueuedUs = HostClock.nowUs()
                // The auxiliary stream has no write trace: a keyframe counts as written when it is queued.
                if frame.isKeyframe {
                    auxKeyframes.update { $0.keyframeWritten(nowUs: HostClock.nowUs(), bytes: frame.data.count) }
                }
                auxFrames.push(frame)
            }, onPackedError: { [onPackedFallback] reason in onPackedFallback(reason) },
               onFailure: { [weak self] error in self?.fail(error) })
            box.encoder = encoder
            auxBox.encoder = encoder
            set { $0.encoder = encoder }

            let display = try await obtainDisplay()
            set { $0.displayInfo = "requested=\(display.requestedRefreshHz)Hz mode=\(display.mode.text) mode_selected=\(display.modeSelected) applied=\(display.appliedModeDescription)" }
            set { $0.display = display }
            // A 1x game display whose mode did not become current would be captured at whatever mode the system
            // picked; the owner falls back to the native display instead (game_display_failed). The catch below
            // removes the display.
            if !display.hidpi && !display.modeSelected { throw VideoPipelineError.gameDisplayUnavailable }
            // HDR10 (decision 0032): the display must really run transfer function 1 (a fresh one fell back to the
            // legacy mode, or a reused one was created with the knob and fell back then). The catch removes it.
            if settings.dynamicRange == .hdr10, display.transferOutcome.applied != 1 {
                throw HDRSetupError(reason: .displayRejected,
                                    detail: display.transferOutcome.fallback?.rawValue ?? "applied_0")
            }
            let cap = ScreenCapture(meter: meter, handler: { [weak encoder] pb, pts, us, displayUs in
                encoder?.encode(pb, presentationTime: pts, captureTimeUs: us, displayTimeUs: displayUs)
            }, onStop: { [weak self] error in self?.fail(error) })
            set { $0.capture = cap }
            // ScreenCaptureKit needs about a second to see a new display.
            var lastError: Error?
            for _ in 0..<20 {
                do {
                    try await cap.start(displayID: display.displayID, settings: settings,
                                        pixelFormat: encoder.capturePixelFormat)
                    lastError = nil
                    break
                }
                catch ScreenCaptureError.displayNotFound(let id) {
                    lastError = ScreenCaptureError.displayNotFound(id)
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    throw Self.captureStartError(error, settings: settings)
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

    /// The inherited display when its pixel size, HiDPI and refresh rate already match and it is still online (capture
    /// and encoder restart only); otherwise a new display (`DisplayReuse`). A display parked for a while may have gone
    /// offline (display sleep, T-165), and capture on an offline display only fails. ScreenCaptureKit keeps delivering
    /// at the old rate after an in-place mode switch (measured, T-049: 60 fps after 60 -> 120 Hz even for a new
    /// SCStream, 126 fps on a display created at 120 Hz), so a refresh change needs a new display; so does a native
    /// <-> game display change (decision 0029). The old one must be gone first: a second display with the same
    /// vendor/product/serial cannot be created while it exists. Every new display waits until `DisplayRecreateGap`
    /// (~700 ms) has passed since the last removal, whichever path removed it (this one, a teardown, a failed start).
    private func obtainDisplay() async throws -> VirtualDisplay {
        if let old = lock.withLock({ () -> VirtualDisplay? in defer { inherited = nil }; return inherited }) {
            if DisplayReuse.decide(current: old.mode, online: Self.isOnline(old), wanted: settings.displayMode) == .reuse {
                set { $0.reusedDisplay = true }
                return old
            }
            old.invalidate()
        }
        let waitUs = VirtualDisplay.recreateWaitUs()
        if waitUs > 0 { try await Task.sleep(nanoseconds: waitUs * 1_000) }
        // Transfer function: 1 for an HDR10 stream, else 0 (the legacy mode).
        return try VirtualDisplay(name: "MateBridge", pixelWidth: settings.widthPx, pixelHeight: settings.heightPx,
                                  physicalPixelWidth: settings.nativeWidthPx, physicalPixelHeight: settings.nativeHeightPx,
                                  hidpi: settings.displayHiDPI, refreshRate: Double(settings.displayRefreshHz),
                                  transfer: settings.displayTransfer)
    }

    /// A capture start error other than `displayNotFound`: for an HDR10 stream a refusal of the HDR capture becomes
    /// `HDRSetupError(.captureFailed)` (SDR fallback). Errors that display sleep explains (`DisplayWaker.reason`) stay
    /// as they are, so a dark display wakes and retries instead of switching HDR off for the process.
    static func captureStartError(_ error: Error, settings: VideoSettings) -> Error {
        guard settings.dynamicRange == .hdr10, DisplayWaker.reason(for: error) == nil else { return error }
        let ns = error as NSError
        return HDRSetupError(reason: .captureFailed, detail: "\(ns.domain)_\(ns.code)")
    }

    /// T-289: what a running pipeline's `onFailure` error is about, carried in the owner's event (`PipelineFailureKind`)
    /// so the decision never depends on the error text. VideoToolbox errors are `.encoder`.
    static func failureKind(_ error: Error) -> PipelineFailureKind {
        error is VideoEncoderError ? .encoder : .other
    }

    /// The HDR ring that failed in a `start()` error, nil for any other failure.
    static func hdrFailure(_ error: Error) -> HDRSetupError? { error as? HDRSetupError }

    /// Whether a `start()` error concerns setting up the virtual display itself (creation, settings, mode selection),
    /// as opposed to permissions, the encoder or capture: only those make a game display fall back to the native one.
    /// Capture not finding the display (`ScreenCaptureError.displayNotFound`) is left out on purpose: it also happens
    /// around display sleep (T-081/T-128) and would switch game displays off for the whole process.
    static func isDisplayFailure(_ error: Error) -> Bool {
        if error is VirtualDisplayError { return true }
        if case VideoPipelineError.gameDisplayUnavailable = error { return true }
        return false
    }

    /// The virtual display is still known to the window server (public CoreGraphics, `CGDisplayIsOnline`).
    static func isOnline(_ display: VirtualDisplay) -> Bool { CGDisplayIsOnline(display.displayID) != 0 }

    /// After `start()`: true when the pipeline kept the display it was handed (`reusing:`), false when it created one.
    var displayWasReused: Bool { lock.withLock { reusedDisplay } }

    /// After `start()`: the display's id and its T-232 transfer function outcome (`ev=vd_transfer`); nil without a
    /// display.
    var displayTransfer: (displayID: CGDirectDisplayID, outcome: VirtualDisplayTransfer.Outcome)? {
        lock.withLock { display.map { ($0.displayID, $0.transferOutcome) } }
    }

    /// Closes the current cadence window (call about once a second). `sentTotal` is the sender's cumulative
    /// frame count.
    public func cadenceWindow(sentTotal: Int) -> CadenceWindow {
        meter.take(nowUs: HostClock.nowUs(), queueDropsTotal: frames.droppedCount, sentTotal: sentTotal)
    }

    /// Closes the current latency window (call with the cadence window, about once a second).
    public func latencyWindow() -> LatencyWindow { latency.take() }

    /// A frame's write completed (called from the sender): feeds the latency window and the optional CSV, and tells
    /// the keyframe request coalescer about written keyframes (T-122).
    public func recordTrace(_ trace: FrameTrace) {
        if trace.isKeyframe {
            keyframes.update { $0.keyframeWritten(nowUs: trace.writeDoneUs, bytes: trace.bytes) }
        }
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

    /// T-187: whether the running encoder is the hardware one (`video ev=encoder_hw`); `unknown(kVTInvalidSessionErr)`
    /// when no encoder runs. Reads the session property on each call: the owner reads it once per pipeline.
    var encoderHardware: EncoderHardwareCheck {
        box.encoder?.hardwareCheck() ?? .unknown(status: HEVCEncoder.noSessionStatus)
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

    /// Host-side keyframe (the sender's transport refused a frame): always forced, and recorded so that the client's
    /// requests caused by the same hiccup coalesce with it.
    public func requestKeyframe() {
        let pushed = frames.keyframesPushed
        keyframes.update { $0.internalForce(nowUs: HostClock.nowUs(), keyframesPushed: pushed) }
        box.encoder?.requestKeyframe(resubmitNow: true, view: .main)
    }

    /// The sender dropped or refused an auxiliary frame (packed full colour): the next auxiliary frame is an IDR.
    public func requestAuxKeyframe() {
        let pushed = auxFrames.keyframesPushed
        auxKeyframes.update { $0.internalForce(nowUs: HostClock.nowUs(), keyframesPushed: pushed) }
        box.encoder?.requestKeyframe(resubmitNow: true, view: .auxiliary)
    }

    /// The sender dropped an auxiliary frame whose main frame never went out and broke the auxiliary chain
    /// (`VideoFrameQueue.breakChain`, which keeps a keyframe already queued behind the hole). Goes through the
    /// auxiliary coalescer's host-drop logic (T-176): nothing is forced when that surviving keyframe, one in the
    /// encoder or one just written covers the hole; otherwise the force is deferred and re-checked, with a hard bound.
    public func auxPairingDropped() {
        auxBox.queueDropped(resubmitNow: true)
    }

    /// Handles a client `KEYFRAME_REQUEST` through the coalescer (T-122, `KeyframeRequestCoalescer`).
    ///
    /// For reasons that imply a rebuilt decoder (`resendsCodecConfig`) the current `CODEC_CONFIG` is always queued and
    /// the queue reset to hold only it; a keyframe is then forced unless the pending one is still inside the encoder,
    /// so the keyframe is always pushed behind the config. `FRAMES_DROPPED` forces a keyframe only when none is on its
    /// way and none was written within the coalescing window.
    public func handleKeyframeRequest(reason: KeyframeReason, view: KeyframeView? = nil) -> KeyframeRequestCoalescer.Decision {
        let encoder = box.encoder
        // Decision 0034: `view` picks the stream (absent / both / unknown: both; main only; auxiliary only); `reason`
        // only decides whether that stream's CODEC_CONFIG is re-sent. Without packed full colour there is one stream.
        let packed = encoder?.isPacked ?? false
        let wanted: KeyframeView = packed ? (view ?? .both) : .main
        if wanted.wantsAuxiliary, let encoder {
            // The same T-122 rules per stream: a resync resets the auxiliary queue to hold only its CODEC_CONFIG; a keyframe
            // is forced only when none is queued, in flight or just written.
            let now = HostClock.nowUs()
            let aux: KeyframeRequestCoalescer.Decision
            if reason.resendsCodecConfig {
                let r = auxFrames.resyncCountingKeyframes(config: { encoder.currentAuxCodecConfig() })
                aux = auxKeyframes.update {
                    $0.request(reason, nowUs: now, keyframesPushed: r.keyframesPushed, configResent: r.configQueued)
                }
            } else {
                let pushed = auxFrames.keyframesPushed
                aux = auxKeyframes.update { $0.request(reason, nowUs: now, keyframesPushed: pushed) }
            }
            if aux.forceKeyframe { encoder.requestKeyframe(resubmitNow: true, view: .auxiliary) }
            if !wanted.wantsMain { return aux }
        }
        guard wanted.wantsMain else { return .auxiliaryOnly }
        let now = HostClock.nowUs()
        let decision: KeyframeRequestCoalescer.Decision
        if reason.resendsCodecConfig {
            // The snapshot is taken under the queue lock, so an encoder-announced config cannot fall between it
            // and the reset (lock order: queue -> encoder; the encoder never calls push while holding its lock).
            // The keyframe push count is read under the same lock: a keyframe pushed later is behind the config.
            let r = frames.resyncCountingKeyframes(config: { encoder?.currentCodecConfig() })
            decision = keyframes.update {
                $0.request(reason, nowUs: now, keyframesPushed: r.keyframesPushed, configResent: r.configQueued)
            }
        } else {
            let pushed = frames.keyframesPushed
            decision = keyframes.update { $0.request(reason, nowUs: now, keyframesPushed: pushed) }
        }
        if decision.forceKeyframe { encoder?.requestKeyframe(resubmitNow: true, view: .main) }
        return decision
    }

    /// Keyframes written since the previous call: `idr=` / `idr_bytes_max=` of the stats line (T-122).
    public func takeKeyframeWindow() -> KeyframeRequestCoalescer.Window { keyframes.update { $0.takeWindow() } }

    /// Call when a new consumer attaches: the queue is reset to hold only [CODEC_CONFIG], stale delta frames are
    /// refused, and a keyframe is forced (also on a static screen, by re-encoding the last captured buffer). The
    /// consumer therefore sees CODEC_CONFIG, then a keyframe, then frames.
    public func prepareForNewConsumer() {
        let encoder = box.encoder
        frames.startNewConsumer(configProvider: { encoder?.currentCodecConfig() })
        auxFrames.startNewConsumer(configProvider: { encoder?.currentAuxCodecConfig() })
        let auxPushed = auxFrames.keyframesPushed
        auxKeyframes.update { $0.reset(nowUs: HostClock.nowUs(), keyframesPushed: auxPushed) }
        let pushed = frames.keyframesPushed
        keyframes.update { $0.reset(nowUs: HostClock.nowUs(), keyframesPushed: pushed) }
        encoder?.requestKeyframe(resubmitNow: true)
    }

    /// Packed full colour (T-258), once a second: closes the auxiliary loss window (encoder-side losses, auxiliary queue
    /// overflows, and `senderAuxDroppedTotal`, the sender's cumulative count of auxiliary frames it dropped) and returns
    /// the fallback decision when the rule is met. Always nil without packed full colour.
    func checkPackedWindow(senderAuxDroppedTotal: Int) -> PackedChromaMonitor.Decision? {
        guard let encoder = box.encoder, encoder.isPacked else { return nil }
        let c = encoder.takeAuxCounters()
        return packedMonitor.close(offered: c.offered, lost: c.lost, queueDroppedTotal: auxFrames.discardedCount,
                                   senderDroppedTotal: senderAuxDroppedTotal)
    }

    /// T-235: `video ev=chroma_stats` fields once the encoder's 10 s window is over (call about once a second); nil
    /// before that, without an encoder, and always unless `MATEBRIDGE_CHROMA` is set or the sharp path runs (T-240).
    func takeChromaStats() -> String? { box.encoder?.takeChromaStats(nowUs: HostClock.nowUs()) }

    /// Colour tags the encoder session reports (VUI source), for diagnostics.
    public var encoderColorReadback: String { box.encoder?.colorReadback() ?? "no encoder" }

    /// `VTSessionSetProperty` failures at encoder creation (empty when all were accepted).
    public var encoderPropertyFailures: [String] { box.encoder?.propertyFailures ?? [] }

    /// Bound of one step of the stop path (T-325).
    private static let stopStepTimeout: TimeInterval = 3
    private static let stopLogger = SessionLogger(component: "video")

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
    /// Capture, encoder, the running display and a handed-over display that `obtainDisplay` never consumed (a start
    /// that failed before it, e.g. an HDR10 encoder refusal; Codex review of T-237).
    private func takeResources() -> (ScreenCapture?, HEVCEncoder?, VirtualDisplay?, VirtualDisplay?) {
        lock.withLock {
            defer { capture = nil; encoder = nil; display = nil; inherited = nil }
            return (capture, encoder, display, inherited)
        }
    }

    /// An unconsumed inherited display is released too (or handed over when keeping and there is no running one):
    /// otherwise it stays alive inside this failed pipeline and the owner's fallback (`hdr_fallback`,
    /// `game_display_failed`) would create a second display with the same vendor/product/serial, which fails.
    @discardableResult
    private func teardown(keepingDisplay: Bool = false) async -> VirtualDisplay? {
        let (cap, enc, disp, inh) = takeResources()
        // T-325: neither wait may be unbounded. A ScreenCaptureKit stop or a VideoToolbox flush that never answers
        // used to hold the stream coordinator's event loop (and with it every later session) forever. Past the bound
        // the step is abandoned (the stuck call stays behind) and the display is released as usual.
        if let cap, await BoundedWait.run(timeout: Self.stopStepTimeout, { await cap.stop() }) == .timedOut {
            Self.stopLogger.log(.error, "pipeline_stop_timeout", sessionID: 0, generation: 0, fields: "step=capture")
        }
        if let enc, await BoundedWait.run(timeout: Self.stopStepTimeout, { await enc.shutdown() }) == .timedOut {
            Self.stopLogger.log(.error, "pipeline_stop_timeout", sessionID: 0, generation: 0, fields: "step=encoder")
        }
        box.encoder = nil
        auxBox.encoder = nil
        frames.finish()
        auxFrames.finish()
        let plan = DisplayTeardown.plan(current: disp, inherited: inh, keeping: keepingDisplay)
        plan.release.forEach { $0.invalidate() }
        return plan.keep
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
    private weak var _frames: VideoFrameQueue?
    private let keyframes: KeyframeGate
    /// The stream this box watches (T-258): its forced keyframes are requested for that stream only.
    private let view: KeyframeView
    init(keyframes: KeyframeGate, view: KeyframeView = .main) {
        self.keyframes = keyframes
        self.view = view
    }
    var encoder: HEVCEncoder? {
        get { lock.lock(); defer { lock.unlock() }; return _encoder }
        set { lock.lock(); _encoder = newValue; lock.unlock() }
    }
    var frames: VideoFrameQueue? {
        get { lock.lock(); defer { lock.unlock() }; return _frames }
        set { lock.lock(); _frames = newValue; lock.unlock() }
    }
    /// Earliest pending re-check of a deferred host-side keyframe (guarded by `lock`).
    private var nextCheckUs: UInt64?

    /// The queue dropped a delta and awaits a keyframe (called outside the queue lock). T-176: forced at once only
    /// when none is on its way and none was written within the coalescing window; otherwise deferred and re-checked
    /// (`KeyframeRequestCoalescer.hostDrop`). Captures keep arriving here (one just overflowed the queue), so the
    /// next one becomes the keyframe.
    func queueDropped(resubmitNow: Bool = false) {
        decide(resubmitNow: resubmitNow) { $0.hostDrop(nowUs: $1, queue: $2) }
    }

    /// Timer: re-checks a deferred host-side keyframe. The screen may have gone static meanwhile, so a keyframe
    /// forced here re-encodes the last captured buffer at once instead of waiting for a capture.
    private func recheck(scheduledAtUs: UInt64) {
        lock.withLock { if nextCheckUs == scheduledAtUs { nextCheckUs = nil } }
        decide(resubmitNow: true) { $0.checkDeferred(nowUs: $1, queue: $2) }
    }

    private func decide(resubmitNow: Bool,
                        _ body: (inout KeyframeRequestCoalescer, UInt64, KeyframeQueueState)
                            -> KeyframeRequestCoalescer.HostDecision) {
        // Nothing to watch once the pipeline has torn its encoder down.
        guard let frames, let encoder else { return }
        let now = HostClock.nowUs()
        // Queue state read under the gate lock (lock order gate -> queue: the queue never calls out while holding
        // its lock, and nothing takes the gate lock while holding the queue lock).
        let d = keyframes.update { body(&$0, now, frames.keyframeState) }
        if d.forceKeyframe { encoder.requestKeyframe(resubmitNow: resubmitNow, view: view) }
        if let at = d.recheckAtUs { schedule(at: at, nowUs: now) }
    }

    /// One-shot re-check at `at` (host clock, µs), unless an earlier one is already scheduled (that one reschedules).
    private func schedule(at: UInt64, nowUs: UInt64) {
        let arm: Bool = lock.withLock {
            if let n = nextCheckUs, n <= at { return false }
            nextCheckUs = at
            return true
        }
        guard arm else { return }
        let delayUs = Int(min(at > nowUs ? at - nowUs : 0, UInt64(Int32.max)))
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .microseconds(delayUs)) {
            [weak self] in self?.recheck(scheduledAtUs: at)
        }
    }
}

/// Serialises the keyframe request coalescer (T-122). Never calls out while holding its lock.
private final class KeyframeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var coalescer = KeyframeRequestCoalescer()
    func update<T>(_ body: (inout KeyframeRequestCoalescer) -> T) -> T { lock.withLock { body(&coalescer) } }
}

/// The auxiliary loss rule's state, with the cumulative drop counters it turns into per-window deltas (T-258).
private final class PackedMonitorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var monitor = PackedChromaMonitor()
    private var lastQueueDropped = 0
    private var lastSenderDropped = 0

    func close(offered: Int, lost: Int, queueDroppedTotal: Int, senderDroppedTotal: Int) -> PackedChromaMonitor.Decision? {
        lock.withLock {
            let extra = max(0, queueDroppedTotal - lastQueueDropped) + max(0, senderDroppedTotal - lastSenderDropped)
            lastQueueDropped = queueDroppedTotal
            lastSenderDropped = senderDroppedTotal
            monitor.recordOffered(offered)
            monitor.recordLost(lost + extra)
            return monitor.closeWindow()
        }
    }
}
