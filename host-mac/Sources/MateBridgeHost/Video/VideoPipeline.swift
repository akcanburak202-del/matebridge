import CoreGraphics
import Foundation
import MateBridgeCore

public enum VideoPipelineError: Error, CustomStringConvertible {
    case screenRecordingDenied
    case unsupportedCodec

    public var description: String {
        switch self {
        case .screenRecordingDenied: return ScreenCaptureError.permissionDenied.description
        case .unsupportedCodec: return "only HEVC is implemented"
        }
    }
}

/// Virtual display -> ScreenCaptureKit -> HEVC -> bounded queue (`frames`).
/// Does not touch the network: the session (T-014) consumes `frames` and wraps each frame in a `VIDEO_FRAME`.
public final class VideoPipeline: @unchecked Sendable {
    public let settings: VideoSettings
    /// Encoder output: CODEC_CONFIG first, then keyframe, then frames. At most 2 wait here.
    public let frames: VideoFrameQueue

    private var display: VirtualDisplay?
    private var capture: ScreenCapture?
    private var encoder: HEVCEncoder?
    private let tap: (@Sendable (EncodedVideoFrame, _ encodeTimeUs: UInt64) -> Void)?
    private let onFailure: @Sendable (Error) -> Void
    private var running = false

    /// - Parameters:
    ///   - tap: observes every encoder output with its encode time (stats, dump tool).
    ///   - onFailure: capture stopped unexpectedly (e.g. permission revoked).
    public init(settings: VideoSettings = .tabletDefault,
                tap: (@Sendable (EncodedVideoFrame, UInt64) -> Void)? = nil,
                onFailure: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.settings = settings
        self.tap = tap
        self.onFailure = onFailure
        // The queue's keyframe callback needs the encoder, which exists only after start().
        let box = EncoderBox()
        self.box = box
        self.frames = VideoFrameQueue(keyframeNeeded: { box.requestKeyframe() })
    }

    private let box: EncoderBox

    /// Fills `STREAM_CONFIG` (pixel/point size, fps, bitrate, colour tags).
    public func streamConfig(configID: UInt16) -> StreamConfig { settings.streamConfig(configID: configID) }

    public func start() async throws {
        guard settings.codec == .hevc else { throw VideoPipelineError.unsupportedCodec }
        // Check before creating the display so a denied permission leaves nothing behind.
        guard ScreenCapture.hasPermission else { throw VideoPipelineError.screenRecordingDenied }

        let frames = self.frames
        let tap = self.tap
        let encoder = try HEVCEncoder(settings: settings) { frame, encodeUs in
            frames.push(frame)
            tap?(frame, encodeUs)
        }
        box.encoder = encoder
        self.encoder = encoder

        do {
            let display = try VirtualDisplay(name: "MateBridge", pixelWidth: settings.widthPx,
                                             pixelHeight: settings.heightPx, hidpi: true,
                                             refreshRate: Double(settings.fps))
            self.display = display
            let cap = ScreenCapture(handler: { [weak encoder] pb, pts, us in
                _ = try? encoder?.encode(pb, presentationTime: pts, captureTimeUs: us)
            }, onStop: onFailure)
            self.capture = cap
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
            running = true
        } catch {
            await stop()
            throw error
        }
    }

    public func requestKeyframe() { encoder?.requestKeyframe() }

    /// Call when a new consumer attaches: re-queues CODEC_CONFIG and forces a keyframe.
    public func prepareForNewConsumer() {
        if let cfg = encoder?.currentCodecConfig() { frames.push(cfg) }
        encoder?.requestKeyframe()
    }

    /// Stops capture, flushes and closes the encoder, removes the virtual display, ends the queue.
    public func stop() async {
        running = false
        await capture?.stop()
        capture = nil
        encoder?.stop()
        box.encoder = nil
        encoder = nil
        frames.finish()
        display?.invalidate()
        display = nil
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
