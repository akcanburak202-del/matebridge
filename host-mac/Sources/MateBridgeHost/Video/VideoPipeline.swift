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

    /// - Parameters:
    ///   - tap: observes every encoder output with its encode time, in encoder order (stats, dump tool).
    ///   - onFailure: capture or encoder failed unexpectedly (e.g. permission revoked); the pipeline is already stopped.
    public init(settings: VideoSettings = .tabletDefault,
                tap: (@Sendable (EncodedVideoFrame, UInt64) -> Void)? = nil,
                onFailure: @escaping @Sendable (Error) -> Void = { _ in }) {
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
                frames.push(frame)
                tap?(frame, encodeUs)
            }, onFailure: { [weak self] error in self?.fail(error) })
            box.encoder = encoder
            set { $0.encoder = encoder }

            let display = try VirtualDisplay(name: "MateBridge", pixelWidth: settings.widthPx,
                                             pixelHeight: settings.heightPx, hidpi: true,
                                             refreshRate: Double(settings.displayRefreshHz))
            set { $0.displayInfo = "requested=\(display.requestedRefreshHz)Hz mode_selected=\(display.modeSelected) applied=\(display.appliedModeDescription)" }
            set { $0.display = display }
            let cap = ScreenCapture(meter: meter, handler: { [weak encoder] pb, pts, us in
                encoder?.encode(pb, presentationTime: pts, captureTimeUs: us)
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

    /// Closes the current cadence window (call about once a second). `sentTotal` is the sender's cumulative
    /// frame count.
    public func cadenceWindow(sentTotal: Int) -> CadenceWindow {
        meter.take(nowUs: HostClock.nowUs(), queueDropsTotal: frames.droppedCount, sentTotal: sentTotal)
    }

    /// Virtual display mode requested vs. applied, and the encoder's cadence-related properties, for the log.
    public var cadenceSetup: String {
        let props = box.encoder?.propertyReport.joined(separator: ",") ?? "none"
        return "display[\(lock.withLock { displayInfo })] stream_fps=\(settings.fps) "
            + "encoder_set[\(props)] encoder_read[\(box.encoder?.cadenceReadback() ?? "none")] "
            + "sck_min_interval_ms=\(String(format: "%.2f", 500 / Double(max(1, settings.fps)))) sck_queue_depth=\(ScreenCapture.queueDepth)"
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

    private func teardown() async {
        let (cap, enc, disp) = takeResources()
        await cap?.stop()
        enc?.stop()
        box.encoder = nil
        frames.finish()
        disp?.invalidate()
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
