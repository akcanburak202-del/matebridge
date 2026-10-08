import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import MateBridgeCore
import ScreenCaptureKit

public enum ScreenCaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case displayNotFound(CGDirectDisplayID)
    /// `setShowsCursor` with no running stream.
    case notRunning

    public var description: String {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is not granted. Enable MateBridge in System Settings > Privacy & Security > Screen & System Audio Recording, then restart it."
        case .displayNotFound(let id):
            return "display \(id) is not visible to ScreenCaptureKit"
        case .notRunning:
            return "the capture stream is not running"
        }
    }
}

/// Captures one display as full-range BT.709 4:2:0 frames (what the encoder wants, no conversion), as sRGB `BGRA`
/// when T-235's `MATEBRIDGE_CHROMA` asks for it, or for an HDR10 stream (decision 0032) as 10-bit video-range
/// BT.2100 PQ 4:2:0 frames (the chroma knob does not apply then).
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// pixel buffer, presentation time, host monotonic microseconds of the frame, and the frame's display time
    /// (`SCStreamFrameInfo.displayTime`, host clock microseconds; 0 when SCK gave none) used as the latency-trace origin
    typealias Handler = @Sendable (CVPixelBuffer, CMTime, UInt64, UInt64) -> Void

    static let queueDepth = 5
    private let handler: Handler
    private let onStop: @Sendable (Error) -> Void
    private let meter: CadenceMeter?
    private var stream: SCStream?
    /// The configuration the running stream has now (decision 0036: `setShowsCursor` changes only `showsCursor`).
    /// Guarded by `liveLock`, together with `stream`'s use there.
    private let liveLock = NSLock()
    private var liveConfig: SCStreamConfiguration?
    private let sampleQueue = DispatchQueue(label: "matebridge.capture", qos: .userInteractive)

    init(meter: CadenceMeter? = nil, handler: @escaping Handler, onStop: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.meter = meter
        self.handler = handler
        self.onStop = onStop
    }

    /// Does not prompt; false means capture would fail.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// - Parameter pixelFormat: `420f` (default, today's path) or `BGRA` for T-235's `MATEBRIDGE_CHROMA` modes
    ///   (`HEVCEncoder.capturePixelFormat`). Colour space and matrix are set the same either way (the matrix only
    ///   applies to YCbCr output).
    func start(displayID: CGDirectDisplayID, settings: VideoSettings,
               pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) async throws {
        guard ScreenCapture.hasPermission else { throw ScreenCaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.displayNotFound(displayID)
        }
        let cfg = SCStreamConfiguration()
        // SCK scales the display to the encoded size (T-049 performance mode); at scale 1000 this is the display size.
        cfg.width = settings.encodedWidthPx
        cfg.height = settings.encodedHeightPx
        if settings.dynamicRange == .hdr10 {
            // Decision 0032: 10-bit 4:2:0 video range in BT.2100 PQ, the HEVC Main10 input without conversion. The
            // same values as macOS 26+'s `captureHDRRecordingPreservedSDRHDR10` preset (read on macOS 27, T-237),
            // set one by one so the code also builds for macOS 15. Needs the display created with transfer
            // function 1 (an SDR display has no headroom to capture). HDR wins over `MATEBRIDGE_CHROMA`
            // (`ChromaPolicy`, `reason=hdr`): `pixelFormat` is not used here.
            cfg.captureDynamicRange = .hdrCanonicalDisplay
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            cfg.colorSpaceName = CGColorSpace.itur_2100_PQ
            cfg.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        } else {
            cfg.pixelFormat = pixelFormat
            cfg.colorSpaceName = CGColorSpace.sRGB
            cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        }
        // SCK discards frames that arrive slightly before the interval, so with exactly 1/fps a 60 Hz source
        // loses ~5% (measured 57.4 fps). Half the interval lets every frame through; the encoder's
        // `FrameGate` keeps the send rate at the stream fps.
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps * 2))
        cfg.queueDepth = ScreenCapture.queueDepth  // > encoder in-flight limit + the retained last buffer
        // Decision 0036: the cursor is out of the video while the tablet draws it (`VideoCursorSwitch` holds that wish
        // across capture restarts); today's behavior, cursor in the video, otherwise.
        cfg.showsCursor = VideoCursorSwitch.shared.showsCursor
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                         configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        liveLock.withLock {
            stream = s
            liveConfig = cfg
        }
        VideoCursorSwitch.shared.attach(self)
    }

    func stop() async {
        VideoCursorSwitch.shared.detach(self)
        let s = liveLock.withLock { () -> SCStream? in
            defer { stream = nil; liveConfig = nil }
            return stream
        }
        try? await s?.stopCapture()
    }

    /// Whether the running stream's configuration draws the cursor into the frames (true before it runs).
    var showsCursorNow: Bool { liveLock.withLock { liveConfig?.showsCursor ?? true } }

    /// Changes `showsCursor` of the running stream without rebuilding it (`SCStream.updateConfiguration`, decision
    /// 0036). Throws when no stream runs or ScreenCaptureKit refuses; the old setting then stays.
    func setShowsCursor(_ shows: Bool) async throws {
        let (s, current) = liveLock.withLock { (stream, liveConfig) }
        guard let s, let current else { throw ScreenCaptureError.notRunning }
        guard let next = current.copy() as? SCStreamConfiguration else { throw ScreenCaptureError.notRunning }
        next.showsCursor = shows
        try await s.updateConfiguration(next)
        liveLock.withLock { if stream === s { liveConfig = next } }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop(error) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let arrivalUs = HostClock.nowUs()
        guard sb.isValid else { meter?.recordCapture(status: "invalid", ptsUs: 0, arrivalUs: arrivalUs); return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let raw = attachments?.first?[.status] as? Int
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        // SCK timestamps are on the host time clock (mach absolute time based).
        let us = UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000)
        let status = raw.flatMap { SCFrameStatus(rawValue: $0) }
        meter?.recordCapture(status: ScreenCapture.statusName(status), ptsUs: us, arrivalUs: arrivalUs)
        if status == .complete {
            // T-323: an absent dirty-rect list counts as dirty (unknown); an empty one as unchanged.
            let rects = attachments?.first?[.dirtyRects] as? [Any]
            InjectToFrameProbe.shared.noteFrame(dirty: rects.map { !$0.isEmpty } ?? true, arrivalUs: arrivalUs)
        }
        guard status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let displayUs = (attachments?.first?[.displayTime] as? UInt64).map(ScreenCapture.machTicksToUs) ?? 0
        handler(pb, pts, us, displayUs)
    }

    /// Mach absolute time ticks (the unit of `SCStreamFrameInfo.displayTime`) to microseconds on the host clock.
    static func machTicksToUs(_ ticks: UInt64) -> UInt64 {
        MachTime.ticksToUs(ticks, numer: timebase.numer, denom: timebase.denom)
    }

    /// The timebase is fixed for the life of the process: read once, not per frame.
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Log-friendly name of an SCK frame status ("unknown" when the attachment is missing).
    static func statusName(_ status: SCFrameStatus?) -> String {
        switch status {
        case .complete: return "complete"
        case .idle: return "idle"
        case .blank: return "blank"
        case .suspended: return "suspended"
        case .started: return "started"
        case .stopped: return "stopped"
        case nil: return "unknown"
        @unknown default: return "other"
        }
    }
}
