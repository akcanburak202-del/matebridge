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

    private let handler: Handler
    private let onStop: @Sendable (Error) -> Void
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "matebridge.capture", qos: .userInteractive)

    init(handler: @escaping Handler, onStop: @escaping @Sendable (Error) -> Void = { _ in }) {
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
        cfg.width = settings.widthPx
        cfg.height = settings.heightPx
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        cfg.queueDepth = 5  // > encoder in-flight limit + the retained last buffer
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
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        // SCK timestamps are on the host time clock (mach absolute time based).
        let us = UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000)
        handler(pb, pts, us)
    }
}
