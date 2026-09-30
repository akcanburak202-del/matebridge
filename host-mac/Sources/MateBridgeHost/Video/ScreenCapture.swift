import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import MateBridgeCore
import ScreenCaptureKit

public enum ScreenCaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case displayNotFound(CGDirectDisplayID)

    public var description: String {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is not granted. Enable MateBridge in System Settings > Privacy & Security > Screen & System Audio Recording, then restart it."
        case .displayNotFound(let id):
            return "display \(id) is not visible to ScreenCaptureKit"
        }
    }
}

/// Captures one display as full-range BT.709 4:2:0 frames (what the encoder wants, no conversion).
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// pixel buffer, presentation time, host monotonic microseconds of the frame
    typealias Handler = @Sendable (CVPixelBuffer, CMTime, UInt64) -> Void

    static let queueDepth = 5
    private let handler: Handler
    private let onStop: @Sendable (Error) -> Void
    private let meter: CadenceMeter?
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "matebridge.capture", qos: .userInteractive)

    init(meter: CadenceMeter? = nil, handler: @escaping Handler, onStop: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.meter = meter
        self.handler = handler
        self.onStop = onStop
    }

    /// Does not prompt; false means capture would fail.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func start(displayID: CGDirectDisplayID, settings: VideoSettings) async throws {
        guard ScreenCapture.hasPermission else { throw ScreenCaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.displayNotFound(displayID)
        }
        let cfg = SCStreamConfiguration()
        // SCK scales the display to the encoded size (T-049 performance mode); at scale 1000 this is the display size.
        cfg.width = settings.encodedWidthPx
        cfg.height = settings.encodedHeightPx
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // SCK discards frames that arrive slightly before the interval, so with exactly 1/fps a 60 Hz source
        // loses ~5% (measured 57.4 fps). Half the interval lets every frame through; the encoder's
        // `FrameGate` keeps the send rate at the stream fps.
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps * 2))
        cfg.queueDepth = ScreenCapture.queueDepth  // > encoder in-flight limit + the retained last buffer
        cfg.showsCursor = true
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                         configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        let s = stream
        stream = nil
        try? await s?.stopCapture()
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
        guard status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        handler(pb, pts, us)
    }

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
