import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import HDRProbeCore
import ScreenCaptureKit

/// Captures one display with an HDR (or SDR) ScreenCaptureKit configuration for a few seconds and reports what the
/// frames look like: pixel format, colour tags, and the brightest / 99th-percentile luma converted back to nits.
/// Opens no window. Requires the Screen Recording permission of the process that runs it (Terminal).
final class HDRCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var reports: [String] = []
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "hdr-probe.capture")

    static func configuration(_ name: String) -> SCStreamConfiguration {
        switch name {
        case "local": return SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
        case "canonical": return SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay)
        case "recording": return SCStreamConfiguration(preset: .captureHDRRecordingPreservedSDRHDR10)
        default:
            // Today's product configuration (T-188): SDR, 8-bit 4:2:0 full range, sRGB, BT.709 matrix.
            let c = SCStreamConfiguration()
            c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            c.colorSpaceName = CGColorSpace.sRGB
            c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            return c
        }
    }

    func run(displayID: CGDirectDisplayID, preset: String, width: Int, height: Int, seconds: Double) async throws -> [String] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            return ["capture: display \(displayID) not visible to ScreenCaptureKit"]
        }
        let cfg = Self.configuration(preset)
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 5
        cfg.showsCursor = false
        let s = SCStream(filter: SCContentFilter(display: scDisplay, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        let t0 = Date()
        try await s.startCapture()
        stream = s
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        try? await s.stopCapture()
        stream = nil
        let elapsed = Date().timeIntervalSince(t0)
        return lock.withLock {
            ["capture preset=\(preset) cfg.pixelFormat=\(fourCC(cfg.pixelFormat)) cfg.colorSpace=\(cfg.colorSpaceName) "
                + "frames=\(frames) in \(String(format: "%.1f", elapsed)) s"] + reports
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { reports.append("capture stopped with error: \(error)") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let n = lock.withLock { frames += 1; return frames }
        // Analyse the first frame and then one per second (keeps the callback cheap).
        guard n == 1 || n % 60 == 0 else { return }
        let line = "  frame \(n): " + Self.describe(pb)
        lock.withLock { reports.append(line) }
    }

    /// Format, colour attachments and a luma summary. 10-bit formats store the sample in the top bits of 16-bit words.
    static func describe(_ pb: CVPixelBuffer) -> String {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let tags = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey]
            .map { (CVBufferCopyAttachment(pb, $0, nil) as? String) ?? "nil" }
        var out = "fmt=\(fourCC(fmt)) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) "
            + "primaries=\(tags[0]) transfer=\(tags[1]) matrix=\(tags[2])"
        let tenBit: [OSType] = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                                kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange]
        let videoRange = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || fmt == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        guard tenBit.contains(fmt) else { return out + " (luma summary only for 10-bit YCbCr)" }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return out }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var samples: [Double] = []
        samples.reserveCapacity((w / 8) * (h / 8))
        for y in Swift.stride(from: 0, to: h, by: 8) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
            for x in Swift.stride(from: 0, to: w, by: 8) {
                let code = row[x] >> 6
                samples.append(videoRange ? Luma10.signal(videoRange: code) : Luma10.signal(fullRange: code))
            }
        }
        let maxS = samples.max() ?? 0, p99 = Stats.percentile(samples, 99), p50 = Stats.percentile(samples, 50)
        let isPQ = tags[1].contains("2084") || tags[1].contains("PQ")
        func nits(_ s: Double) -> String { isPQ ? String(format: "%.0f nit", PQ.decode(s)) : "n/a" }
        out += String(format: " luma max=%.3f (%@) p99=%.3f (%@) p50=%.3f (%@)", maxS, nits(maxS), p99, nits(p99), p50, nits(p50))
        return out
    }
}
