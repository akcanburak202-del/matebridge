import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import MateBridgeCore
import VideoToolbox

/// `MateBridgeApp --sharpness-bench` (T-086): how sharp text stays through the real encoder, during motion, when the
/// screen stops, and after the idle quality refresh.
///
/// A 2800x1840 synthetic text page (CoreText: several sizes, grey and coloured text, hairlines) scrolls for
/// `--motion-frames` frames at the stream fps and then stops. Frames go through `HEVCEncoder` itself, with the app's
/// environment knobs (`MATEBRIDGE_CODEC`, `_BITRATE_KBPS`, `_PRIO_SPEED`, `_QUALITY`, `_IDLE_REFRESH_*`, `_ENCODER`),
/// like ScreenCaptureKit: nothing is submitted while the content is static, so only the idle refresh (if enabled)
/// produces more frames. The Annex-B output is decoded in-process with `VTDecompressionSession` and compared with the
/// source luma (PSNR, 8x8 SSIM). No display, capture, input or network is touched.
///
/// Like the real pipeline, the idle refresh re-submits the very `CVPixelBuffer` of the last motion frame
/// (`--refresh-buffer same`, default) or, to tell the two apart, a content copy (`--refresh-buffer copy`, T-087).
public enum SharpnessBench {
    static let width = 2800
    static let height = 1840
    /// Luma variance (std dev 10) above which an 8x8 source block counts as text for `ssim_text`.
    static let textBlockVariance = 100.0

    /// Exits the process when `--sharpness-bench` is on the command line.
    public static func runIfRequested() {
        guard let parsed = SharpnessBenchOptions.parse(CommandLine.arguments) else { return }
        switch parsed {
        case .failure(let error):
            print("error: \(error.message)")
            exit(2)
        case .success(let options):
            exit(run(options))
        }
    }

    // MARK: Source

    /// Luma and interleaved CbCr planes of the whole scrolling page (full range, BT.709).
    struct Page {
        var width: Int
        var height: Int
        var luma: [UInt8]
        var chroma: [UInt8]   // (height / 2) rows of width bytes (Cb, Cr pairs)

        /// Luma of the visible window starting at row `top`.
        func lumaWindow(top: Int, rows: Int) -> LumaPlane {
            LumaPlane(width: width, height: rows, data: Array(luma[(top * width)..<((top + rows) * width)]))
        }
    }

    static func makePage(width: Int, height: Int) -> Page? {
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 255, count: bytesPerRow * height)
        let ok: Bool = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            drawPage(ctx, width: width, height: height)
            return true
        }
        guard ok else { return nil }
        return toYCbCr(rgba, width: width, height: height)
    }

    private static func drawPage(_ ctx: CGContext, width: Int, height: Int) {
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)   // macOS draws greyscale-antialiased text on screen
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let sample = "The quick brown fox jumps over the lazy dog 0123456789 (){}[] ; MateBridge iiil1| mm WW rnm"
        let fonts = ["Helvetica", "Menlo", "Times New Roman"]
        // Pixel sizes of 9...24 pt text on a 2x HiDPI display.
        let sizes: [CGFloat] = [18, 20, 22, 24, 26, 28, 32, 40, 48]
        let colours: [CGColor] = [
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            CGColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1),
            CGColor(srgbRed: 0.1, green: 0.3, blue: 0.85, alpha: 1),
            CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1),
            CGColor(srgbRed: 0.1, green: 0.55, blue: 0.2, alpha: 1),
        ]
        var y = CGFloat(height) - 40
        var row = 0
        while y > 20 {
            let size = sizes[row % sizes.count]
            let colour = colours[(row / 2) % colours.count]
            let fontName = fonts[row % fonts.count]
            // Every seventh row: light text on a dark band (dark-mode UI).
            let dark = row % 7 == 6
            if dark {
                ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
                ctx.fill(CGRect(x: 0, y: y - size * 0.35, width: CGFloat(width), height: size * 1.4))
            }
            let font = CTFontCreateWithName(fontName as CFString, size, nil)
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: dark ? CGColor(srgbRed: 0.92, green: 0.92, blue: 0.92, alpha: 1) : colour,
            ]
            let line = CTLineCreateWithAttributedString(
                CFAttributedStringCreate(nil, String(repeating: sample + "  ", count: 3) as CFString,
                                         attrs as CFDictionary))
            ctx.textPosition = CGPoint(x: 24 + CGFloat(row % 5) * 3, y: y)
            CTLineDraw(line, ctx)
            y -= size * 1.5
            row += 1
            // Hairlines between some rows: 1 px grey, 1 px black, and a short vertical tick comb.
            if row % 4 == 0 {
                ctx.setFillColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1))
                ctx.fill(CGRect(x: 0, y: y + size * 0.6, width: CGFloat(width), height: 1))
                ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
                for i in stride(from: 0, to: width, by: 6) {
                    ctx.fill(CGRect(x: CGFloat(i), y: y + size * 0.6 + 3, width: 1, height: 10))
                }
            }
        }
    }

    /// RGBA (sRGB) to full-range BT.709 Y and 2x2-averaged interleaved CbCr.
    private static func toYCbCr(_ rgba: [UInt8], width: Int, height: Int) -> Page {
        var luma = [UInt8](repeating: 0, count: width * height)
        var chroma = [UInt8](repeating: 128, count: width * (height / 2))
        rgba.withUnsafeBufferPointer { src in
            luma.withUnsafeMutableBufferPointer { yp in
                chroma.withUnsafeMutableBufferPointer { cp in
                    for y in 0..<height {
                        for x in 0..<width {
                            let i = (y * width + x) * 4
                            let r = Double(src[i]), g = Double(src[i + 1]), b = Double(src[i + 2])
                            yp[y * width + x] = UInt8(clamping: Int((0.2126 * r + 0.7152 * g + 0.0722 * b).rounded()))
                        }
                    }
                    for cy in 0..<(height / 2) {
                        for cx in 0..<(width / 2) {
                            var r = 0.0, g = 0.0, b = 0.0
                            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                                let i = ((cy * 2 + dy) * width + cx * 2 + dx) * 4
                                r += Double(src[i]); g += Double(src[i + 1]); b += Double(src[i + 2])
                            }
                            r /= 4; g /= 4; b /= 4
                            let yy = 0.2126 * r + 0.7152 * g + 0.0722 * b
                            cp[cy * width + cx * 2] = UInt8(clamping: Int(((b - yy) / 1.8556 + 128).rounded()))
                            cp[cy * width + cx * 2 + 1] = UInt8(clamping: Int(((r - yy) / 1.5748 + 128).rounded()))
                        }
                    }
                }
            }
        }
        return Page(width: width, height: height, luma: luma, chroma: chroma)
    }

    /// One visible frame (rows `top ..< top + height`) as an IOSurface-backed full-range NV12 buffer.
    static func frame(_ page: Page, top: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, page.width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        for (plane, source, rows, first) in [(0, page.luma, height, top), (1, page.chroma, height / 2, top / 2)] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            source.withUnsafeBufferPointer { src in
                for r in 0..<rows {
                    (base + r * stride).copyMemory(from: src.baseAddress! + (first + r) * page.width,
                                                   byteCount: page.width)
                }
            }
        }
        return pb
    }

    // MARK: Decode

    final class Decoder {
        private var session: VTDecompressionSession?
        private var format: CMVideoFormatDescription?
        let codec: Codec

        init(codec: Codec) { self.codec = codec }

        deinit { if let session { VTDecompressionSessionInvalidate(session) } }

        /// CODEC_CONFIG: (re)creates the session. Returns false if the parameter sets are unusable.
        func configure(_ annexB: [UInt8]) -> Bool {
            let sets = AnnexB.nalUnits(annexB)
            guard !sets.isEmpty else { return false }
            let ptrs = sets.map { s -> UnsafeMutablePointer<UInt8> in
                let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
                p.initialize(from: s, count: s.count)
                return p
            }
            defer { ptrs.forEach { $0.deallocate() } }
            let cptrs = ptrs.map { UnsafePointer($0) }
            let sizes = sets.map(\.count)
            var fd: CMFormatDescription?
            let st: OSStatus = codec == .h264
                ? CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: sets.count, parameterSetPointers: cptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
                : CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: sets.count, parameterSetPointers: cptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
            guard st == noErr, let fd else { return false }
            if let session { VTDecompressionSessionInvalidate(session) }
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ]
            var ds: VTDecompressionSession?
            guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                               imageBufferAttributes: attrs as CFDictionary,
                                               outputCallback: nil, decompressionSessionOut: &ds) == noErr,
                  let ds else { return false }
            session = ds
            format = fd
            return true
        }

        /// Decodes one Annex-B access unit synchronously; returns its luma plane.
        func decode(_ annexB: [UInt8]) -> LumaPlane? {
            guard let session, let format else { return nil }
            var avcc: [UInt8] = []
            for nal in AnnexB.nalUnits(annexB) {
                let n = UInt32(nal.count)
                avcc += [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
                avcc += nal
            }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block) == kCMBlockBufferNoErr, let block,
                  avcc.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                       offsetIntoDestination: 0,
                                                                       dataLength: avcc.count) }) == kCMBlockBufferNoErr
            else { return nil }
            var sb: CMSampleBuffer?
            var size = avcc.count
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                                            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                            sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                            sampleBufferOut: &sb) == noErr, let sb else { return nil }
            let result = LockedBox<LumaPlane?>(nil)
            let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                guard status == noErr, let image else { return }
                result.value = Decoder.luma(image)
            }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            return st == noErr ? result.value : nil
        }

        static func luma(_ pb: CVPixelBuffer) -> LumaPlane? {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
            let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            var out = [UInt8](repeating: 0, count: w * h)
            out.withUnsafeMutableBytes { dst in
                for r in 0..<h { (dst.baseAddress! + r * w).copyMemory(from: base + r * stride, byteCount: w) }
            }
            return LumaPlane(width: w, height: h, data: out)
        }
    }

    final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ v: T) { _value = v }
        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    // MARK: Run

    struct Output {
        var frame: EncodedVideoFrame
        var encodeUs: UInt64
    }

    /// Returns the process exit code.
    static func run(_ o: SharpnessBenchOptions) -> Int32 {
        let env = ProcessInfo.processInfo.environment
        var knobs = EncoderKnobs.parse(env)
        if let b = o.refreshBuffer { knobs.idleRefresh.buffer = b }
        let settings = VideoSettings.tabletDefault.applyingExperimentKnobs(env)
            .applying(StreamPrefs(fps: UInt16(clamping: o.fps), scalePermille: 1000))
        let shift = max(2, (o.shiftPx + 1) & ~1)   // even, so the chroma rows move with the luma rows
        let staticMs = o.effectiveStaticMs(idleRefresh: knobs.idleRefresh)
        print("sharpness-bench \(width)x\(height) fps=\(settings.fps) codec=\(settings.codec.logName) "
              + "bitrate_kbps=\(settings.bitrateKbps) source=\(settings.bitrateSource) \(knobs.logFields) "
              + "motion_frames=\(o.motionFrames) shift_px=\(shift) static_ms=\(staticMs) "
              + "resume_frames=\(o.resumeFrames) "
              + "refresh_buffer=\(knobs.idleRefresh.buffer.rawValue)")
        let frames = o.motionFrames + o.resumeFrames
        guard let page = makePage(width: width, height: height + frames * shift) else {
            print("error: cannot render the text page")
            return 1
        }

        let outputs = LockedBox<[Output]>([])
        let failed = LockedBox<String?>(nil)
        let encoder: HEVCEncoder
        do {
            encoder = try HEVCEncoder(
                settings: settings, knobs: knobs,
                logSink: { level, event, fields in print("log \(level.rawValue) ev=\(event) \(fields)") },
                output: { frame, us in outputs.value.append(Output(frame: frame, encodeUs: us)) },
                onFailure: { failed.value = "\($0)" })
        } catch {
            print("error: \(error)")
            return 1
        }

        // Motion: one frame per stream interval, timestamped on the host clock like ScreenCaptureKit.
        var sourceIndex: [UInt64: Int] = [:]   // capture time -> frame index (scroll position index * shift)
        let intervalNs = UInt64(1e9 / Double(settings.fps))
        func scroll(_ indices: Range<Int>) -> Bool {
            var next = DispatchTime.now().uptimeNanoseconds
            for i in indices {
                let now = DispatchTime.now().uptimeNanoseconds
                if next > now { Thread.sleep(forTimeInterval: Double(next - now) / 1e9) }
                next += intervalNs
                guard let pb = frame(page, top: i * shift, height: height) else { return false }
                let pts = CMClockGetTime(CMClockGetHostTimeClock())
                let us = UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000)
                sourceIndex[us] = i
                encoder.encode(pb, presentationTime: pts, captureTimeUs: us)
            }
            return true
        }
        guard scroll(0..<o.motionFrames) else { print("error: cannot allocate a frame"); return 1 }
        let lastTop = (o.motionFrames - 1) * shift
        // Static: no new captures (as with ScreenCaptureKit); only the idle refresh may encode more frames.
        Thread.sleep(forTimeInterval: Double(staticMs) / 1000)
        // Resume (optional): scrolling continues, so a refresh-only setting must not linger.
        guard scroll(o.motionFrames..<frames) else { print("error: cannot allocate a frame"); return 1 }
        encoder.stop()
        if let f = failed.value { print("error: encoder failed: \(f)") }

        // Decode everything in order; measure each picture against the source rows it was made from.
        let decoder = Decoder(codec: settings.codec)
        let lastRef = page.lumaWindow(top: lastTop, rows: height)
        var motion: [(psnr: Double, bytes: Int)] = []
        var resume: [(psnr: Double, bytes: Int)] = []
        var lastMotion: (LumaPlane, Output)?
        var refreshes: [(LumaPlane, Output)] = []
        var lastPicture: (LumaPlane, Output)?   // the last one before the resume
        var configs = 0
        for out in outputs.value {
            if out.frame.isCodecConfig {
                configs += 1
                guard decoder.configure(out.frame.data) else { print("error: bad parameter sets"); return 1 }
                continue
            }
            guard let pic = decoder.decode(out.frame.data) else { print("error: decode failed"); return 1 }
            if let i = sourceIndex[out.frame.captureTimeUs] {
                let ref = page.lumaWindow(top: i * shift, rows: height)
                let sample = (ImageQuality.psnr(ref, pic), out.frame.data.count)
                if i >= o.motionFrames { resume.append(sample); continue }
                motion.append(sample)
                if i * shift == lastTop { lastMotion = (pic, out) }
            } else {
                refreshes.append((pic, out))
            }
            lastPicture = (pic, out)
        }

        // `ssim_text`: only blocks with detail in the source (text, lines), not the flat page background.
        func line(_ phase: String, _ pic: LumaPlane, _ out: Output, extra: String = "") {
            print(String(format: "phase=%@ psnr_y=%.2f ssim_y=%.4f ssim_text=%.4f bytes=%d key=%d enc_ms=%.1f%@",
                         phase, ImageQuality.psnr(lastRef, pic), ImageQuality.ssim(lastRef, pic),
                         ImageQuality.ssim(lastRef, pic, minReferenceVariance: textBlockVariance),
                         out.frame.data.count, out.frame.isKeyframe ? 1 : 0, Double(out.encodeUs) / 1000, extra))
        }
        if !motion.isEmpty {
            let mean = motion.map(\.psnr).reduce(0, +) / Double(motion.count)
            let bytes = Double(motion.map(\.bytes).reduce(0, +)) / Double(motion.count)
            print(String(format: "phase=motion_mean frames=%d of=%d psnr_y=%.2f bytes=%.0f",
                         motion.count, o.motionFrames, mean, bytes))
        }
        if let (pic, out) = lastMotion { line("motion_last", pic, out) } else { print("phase=motion_last missing=1") }
        for (n, (pic, out)) in refreshes.enumerated() { line("idle_refresh", pic, out, extra: " n=\(n + 1)") }
        if let (pic, out) = lastPicture { line("static_end", pic, out, extra: " refreshes=\(refreshes.count)") }
        if o.resumeFrames > 0 {
            let n = Double(max(1, resume.count))
            let maxBytes = resume.map(\.bytes).max() ?? 0
            print(String(format: "phase=resume_mean frames=%d of=%d psnr_y=%.2f bytes=%.0f max_bytes=%d first_bytes=%d",
                         resume.count, o.resumeFrames, resume.map(\.psnr).reduce(0, +) / n,
                         Double(resume.map(\.bytes).reduce(0, +)) / n, maxBytes, resume.first?.bytes ?? 0))
        }
        print("summary codec_configs=\(configs) outputs=\(outputs.value.count - configs)")
        return failed.value == nil ? 0 : 1
    }
}
