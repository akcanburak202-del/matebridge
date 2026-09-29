import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ProbeCore
import ScreenCaptureKit

/// Captures one display via ScreenCaptureKit, saves the first frame as PNG and counts frames.
final class DisplayCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var counter = FrameCounter()
    private var savedFirst = false
    private let outputURL: URL
    private var stream: SCStream?
    private let ciContext = CIContext()
    private let sampleQueue = DispatchQueue(label: "vdisplay-probe.capture")

    init(outputURL: URL) { self.outputURL = outputURL }

    func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "vdisplay-probe", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "display \(displayID) not visible to ScreenCaptureKit (saw \(content.displays.map(\.displayID)))"])
        }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = pixelWidth
        cfg.height = pixelHeight
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 3
        cfg.showsCursor = true
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    /// Frames counted since the previous call.
    func takeWindowCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return counter.takeWindow()
    }

    var totalFrames: Int { lock.lock(); defer { lock.unlock() }; return counter.total }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lock.lock()
        counter.record()
        let needSave = !savedFirst
        savedFirst = true
        lock.unlock()
        if needSave {
            let image = CIImage(cvPixelBuffer: pb)
            do {
                try ciContext.writePNGRepresentation(of: image, to: outputURL, format: .BGRA8,
                                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                print("first frame saved: \(outputURL.path) (\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)))")
            } catch {
                print("failed to save first frame: \(error)")
            }
        }
    }
}
