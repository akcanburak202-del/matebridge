import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HDRProbeCore
import VideoToolbox

/// HEVC Main10 HDR encode bench on synthetic 10-bit frames (no display, no capture). It uses the hardware encoder,
/// so do NOT run it while a MateBridge stream is live (one encoder; the stream would stutter).
/// Optionally writes the encoded stream to an MP4 for the Android probe.
final class HDRBench: @unchecked Sendable {
    struct Config {
        var width = 2800
        var height = 1840
        var fps = 120
        var seconds = 5.0
        /// "fast" = today's 120 fps profile (no LLRC, RealTime=false); "llrc" = today's 60 fps profile.
        var path = "fast"
        /// "pq" (HDR10) or "hlg".
        var transfer = "pq"
        var bitrateKbps = 30_000
        var out: String?
    }

    private let cfg: Config
    private let lock = NSLock()
    private var submitted: [Int64: UInt64] = [:]
    private var latenciesMs: [Double] = []
    private var bytes = 0
    private var errors = 0
    private var skipped = 0
    private var inFlight = 0
    private var firstFormat: CMFormatDescription?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pendingSamples: [CMSampleBuffer] = []

    init(_ cfg: Config) { self.cfg = cfg }

    private var isPQ: Bool { cfg.transfer != "hlg" }

    func run() throws -> [String] {
        var lines: [String] = []
        let pool = try makeFrames(count: 12)
        var session: VTCompressionSession?
        var spec: [CFString: Any] = [:]
        if cfg.path == "llrc" { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(cfg.width), height: Int32(cfg.height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard st == noErr, let session else { return ["VTCompressionSessionCreate failed: \(st)"] }
        defer { VTCompressionSessionInvalidate(session) }

        func set(_ name: String, _ key: CFString, _ value: CFTypeRef) {
            let s = VTSessionSetProperty(session, key: key, value: value)
            lines.append("  set \(name) -> \(s == noErr ? "ok" : "error \(s)")")
        }
        set("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel)
        set("RealTime", kVTCompressionPropertyKey_RealTime, cfg.path == "llrc" ? kCFBooleanTrue : kCFBooleanFalse)
        set("AllowFrameReordering", kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set("ExpectedFrameRate", kVTCompressionPropertyKey_ExpectedFrameRate, cfg.fps as CFNumber)
        set("AverageBitRate", kVTCompressionPropertyKey_AverageBitRate, (cfg.bitrateKbps * 1000) as CFNumber)
        set("MaxKeyFrameIntervalDuration", kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        if cfg.path != "llrc" {
            set("PrioritizeEncodingSpeedOverQuality", kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        }
        set("ColorPrimaries", kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_2020)
        set("TransferFunction", kVTCompressionPropertyKey_TransferFunction,
            isPQ ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        set("YCbCrMatrix", kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        if isPQ {
            let md = HDR10Static.p3D65_1000
            set("MasteringDisplayColorVolume", kVTCompressionPropertyKey_MasteringDisplayColorVolume, md.mdcvSEI() as CFData)
            set("ContentLightLevelInfo", kVTCompressionPropertyKey_ContentLightLevelInfo, md.cllSEI() as CFData)
            set("HDRMetadataInsertionMode", kVTCompressionPropertyKey_HDRMetadataInsertionMode, kVTHDRMetadataInsertionMode_Auto)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)

        if let out = cfg.out { try? FileManager.default.removeItem(atPath: out) }

        let frameCount = Int(cfg.seconds * Double(cfg.fps))
        let period = 1.0 / Double(cfg.fps)
        let start = Date()
        for i in 0..<frameCount {
            let due = start.addingTimeInterval(Double(i) * period)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            // In-flight limit 2 (as in the product): skip a slot rather than queue.
            if lock.withLock({ inFlight >= 2 }) { lock.withLock { skipped += 1 }; continue }
            let pts = CMTime(value: Int64(i), timescale: Int32(cfg.fps))
            lock.withLock { inFlight += 1; submitted[Int64(i)] = DispatchTime.now().uptimeNanoseconds }
            let s = VTCompressionSessionEncodeFrame(session, imageBuffer: pool[i % pool.count], presentationTimeStamp: pts,
                                                    duration: CMTime(value: 1, timescale: Int32(cfg.fps)),
                                                    frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sb in
                self?.done(index: Int64(i), status: status, sample: sb)
            }
            if s != noErr { lock.withLock { errors += 1; inFlight -= 1 } }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let elapsed = Date().timeIntervalSince(start)
        finishWriter()

        return lock.withLock {
            let lat = latenciesMs
            var r = ["encode path=\(cfg.path) transfer=\(cfg.transfer) \(cfg.width)x\(cfg.height) target \(cfg.fps) fps"] + lines
            r.append(String(format: "  encoded=%d in %.2f s (%.1f fps) skipped=%d errors=%d  enc ms p50/p95/p99 = %.1f/%.1f/%.1f  %.1f Mbps",
                            lat.count, elapsed, Double(lat.count) / elapsed, skipped, errors,
                            Stats.percentile(lat, 50), Stats.percentile(lat, 95), Stats.percentile(lat, 99),
                            Double(bytes) * 8 / elapsed / 1e6))
            if let f = firstFormat, let ext = CMFormatDescriptionGetExtensions(f) as? [String: Any] {
                let keys = [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction,
                            kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionExtension_FullRangeVideo,
                            kCMFormatDescriptionExtension_MasteringDisplayColorVolume,
                            kCMFormatDescriptionExtension_ContentLightLevelInfo, kCMFormatDescriptionExtension_BitsPerComponent]
                for k in keys { r.append("  format \(k) = \(ext[k as String].map { "\($0)" } ?? "nil")") }
            }
            if let out = cfg.out { r.append("  wrote \(out)") }
            return r
        }
    }

    private func done(index: Int64, status: OSStatus, sample: CMSampleBuffer?) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock {
            inFlight -= 1
            if let t = submitted.removeValue(forKey: index) { latenciesMs.append(Double(now - t) / 1e6) }
            guard status == noErr, let sample else { errors += 1; return }
            bytes += CMSampleBufferGetTotalSampleSize(sample)
            if firstFormat == nil { firstFormat = CMSampleBufferGetFormatDescription(sample) }
        }
        if cfg.out != nil, let sample { append(sample) }
    }

    // MARK: MP4 output (passthrough, for the Android probe)

    private func append(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        if writer == nil, let out = cfg.out, let fmt = CMSampleBufferGetFormatDescription(sample) {
            guard let w = try? AVAssetWriter(outputURL: URL(fileURLWithPath: out), fileType: .mp4) else { return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
            input.expectsMediaDataInRealTime = true
            w.add(input)
            w.startWriting()
            w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
            writer = w
            writerInput = input
        }
        guard let input = writerInput else { return }
        pendingSamples.append(sample)
        while input.isReadyForMoreMediaData, !pendingSamples.isEmpty {
            input.append(pendingSamples.removeFirst())
        }
    }

    private func finishWriter() {
        lock.lock()
        guard let w = writer, let input = writerInput else { lock.unlock(); return }
        while !pendingSamples.isEmpty {
            if input.isReadyForMoreMediaData { input.append(pendingSamples.removeFirst()) } else { Thread.sleep(forTimeInterval: 0.005) }
        }
        lock.unlock()
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        w.finishWriting { sem.signal() }
        sem.wait()
    }

    // MARK: Synthetic HDR frames

    /// 10-bit 4:2:0 video-range frames, tagged BT.2020 + PQ/HLG. Top half: a grey ramp 0...1000 nits (PQ) / 0...1 (HLG);
    /// bottom half: flat patches at 100, 203 (SDR reference white, BT.2408), 400 and 1000 nits, with a moving bar.
    private func makeFrames(count: Int) throws -> [CVPixelBuffer] {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var frames: [CVPixelBuffer] = []
        for f in 0..<count {
            var pb: CVPixelBuffer?
            let s = CVPixelBufferCreate(nil, cfg.width, cfg.height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                        attrs as CFDictionary, &pb)
            guard s == kCVReturnSuccess, let pb else {
                throw NSError(domain: "hdr-probe", code: Int(s), userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate \(s)"])
            }
            fill(pb, frame: f, of: count)
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                                  isPQ ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                  .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            frames.append(pb)
        }
        return frames
    }

    private func signal(nits: Double) -> Double {
        // HLG: treat 1000 nits as scene 1.0 (nominal peak) for this synthetic pattern.
        isPQ ? PQ.encode(nits: nits) : HLG.oetf(nits / 1000)
    }

    private func fill(_ pb: CVPixelBuffer, frame: Int, of count: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = cfg.width, h = cfg.height
        let patches: [Double] = [100, 203, 400, 1000]
        let barX = (w * frame / max(count, 1)) % w
        if let y0 = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for y in 0..<h {
                let row = y0.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<w {
                    let nits: Double
                    if abs(x - barX) < 24 { nits = 50 }
                    else if y < h / 2 { nits = 1000 * Double(x) / Double(w - 1) }
                    else { nits = patches[min(patches.count - 1, x * patches.count / w)] }
                    row[x] = Luma10.videoRange(signal(nits: nits)) << 6
                }
            }
        }
        if let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let ch = CVPixelBufferGetHeightOfPlane(pb, 1), cw = CVPixelBufferGetWidthOfPlane(pb, 1)
            for y in 0..<ch {
                let row = c.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<(cw * 2) { row[x] = Luma10.chromaNeutral << 6 }
            }
        }
    }
}
