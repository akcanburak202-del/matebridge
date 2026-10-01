import CoreMedia
import CoreVideo
import Foundation
import MateBridgeCore
import VideoToolbox

/// `MateBridgeApp --encode-bench` (T-047): measures how fast VideoToolbox HEVC (or H.264 with `MATEBRIDGE_CODEC=h264`,
/// T-086) can encode 2800x1840 frames under different session configurations. Synthetic frames only; no display, SCK, input or network is touched.
public enum EncodeBench {
    public struct Result: Sendable {
        public var config: String
        public var mode: String
        public var outFps: Double
        public var submitted: Int
        public var skipped: Int
        public var p50Ms: Double
        public var p95Ms: Double
        public var p99Ms: Double
        public var mbps: Double
        public var sizes = FrameSizeStats()
        /// Mean encoded bytes per output frame (keyframes included).
        public var meanBytes = 0.0
        public var note: String
    }

    // MARK: Synthetic frames

    /// Full-range 4:2:0, like `ScreenCapture`. Each pool frame differs: a sliding gradient plus text-like glyph cells.
    static func makeFramePool(width: Int, height: Int, count: Int, content: EncodeBenchContent) -> [CVPixelBuffer] {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        var pool: [CVPixelBuffer] = []
        for f in 0..<count {
            var pb: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                      attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            fill(pb, width: width, height: height, frame: content == .scroll ? f : 0, patch: content == .patch ? f : nil)
            CVPixelBufferUnlockBaseAddress(pb, [])
            pool.append(pb)
        }
        return pool
    }

    private static func fill(_ pb: CVPixelBuffer, width: Int, height: Int, frame: Int, patch: Int?) {
        let shift = frame * 29
        if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = p + y * stride
                let cellY = y / 20, inCellY = y % 20
                for x in 0..<width {
                    var v = UInt8(truncatingIfNeeded: ((x + shift) >> 3) + (y >> 4))
                    v = 40 + (v & 0x3F)                       // gentle moving gradient
                    if y < height * 2 / 3 && inCellY < 14 {   // text-like block region
                        let cellX = (x + shift / 3) / 12, inCellX = (x + shift / 3) % 12
                        if inCellX < 9 {
                            var h = UInt32(truncatingIfNeeded: cellX &* 73856093 ^ cellY &* 19349663)
                            h = (h ^ (h >> 13)) &* 0x5bd1e995
                            if (h >> UInt32((inCellX + inCellY) % 16)) & 1 == 1 { v = 235 }
                        }
                    }
                    row[x] = v
                }
            }
        }
        if let patch, let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            // A 240x120 region near the top-left changes from frame to frame (pen stroke / caret area).
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 100..<220 { for x in 100..<340 {
                p[y * stride + x] = UInt8(truncatingIfNeeded: ((x * 7 + y * 3 + patch * 41) >> 2) & 0xFF)
            } }
        }
        if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<(height / 2) {
                let row = p + y * stride
                for x in 0..<(width / 2) {
                    row[2 * x] = UInt8(truncatingIfNeeded: 110 + ((x + shift / 2) >> 6))
                    row[2 * x + 1] = UInt8(truncatingIfNeeded: 140 + (y >> 6))
                }
            }
        }
    }

    // MARK: Session

    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var durationsUs: [UInt64] = []
        var bytes = 0
        var frames: [(size: Int, isKey: Bool)] = []
        var outputs = 0
        var failures = 0
        func record(us: UInt64, bytes b: Int, isKey: Bool) {
            lock.lock(); durationsUs.append(us); bytes += b; outputs += 1; frames.append((b, isKey)); lock.unlock()
        }
        func fail() { lock.lock(); failures += 1; lock.unlock() }
    }

    private static func makeSession(_ c: EncodeBenchConfig, width: Int, height: Int, fps: Int, codec: Codec,
                                    h264Profile: H264Profile, notes: inout [String]) -> VTCompressionSession? {
        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        if c.lowLatencyRateControl { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: HEVCEncoder.codecType(codec),
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { notes.append("create=\(st)"); return nil }
        func set(_ name: String, _ key: CFString, _ value: CFTypeRef) {
            let r = VTSessionSetProperty(s, key: key, value: value)
            if r != noErr { notes.append("\(name)=\(r)") }
        }
        if let rt = c.realTime { set("RealTime", kVTCompressionPropertyKey_RealTime, rt ? kCFBooleanTrue : kCFBooleanFalse) }
        if let pe = c.maximizePowerEfficiency {
            set("MaximizePowerEfficiency", kVTCompressionPropertyKey_MaximizePowerEfficiency,
                pe ? kCFBooleanTrue : kCFBooleanFalse)
        }
        set("AllowFrameReordering", kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc && c.main10 ? kVTProfileLevel_HEVC_Main10_AutoLevel
                : HEVCEncoder.profileLevel(codec, h264: h264Profile))
        set("ExpectedFrameRate", kVTCompressionPropertyKey_ExpectedFrameRate, (c.expectedFps ?? fps) as CFNumber)
        // As in `HEVCEncoder` (T-086): Quality replaces AverageBitRate; if it is refused, the bitrate is used.
        var qualityOK = false
        if let q = c.quality {
            let r = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_Quality, value: q as CFNumber)
            qualityOK = r == noErr
            notes.append(qualityOK ? "quality=\(q)" : "Quality=\(r)")
        }
        if !qualityOK {
            set("AverageBitRate", kVTCompressionPropertyKey_AverageBitRate, (c.bitrateKbps * 1000) as CFNumber)
        }
        if c.dataRateLimits {
            set("DataRateLimits", kVTCompressionPropertyKey_DataRateLimits, [c.bitrateKbps * 1000 / 8 * 2, 1] as CFArray)
        }
        set("MaxKeyFrameIntervalDuration", kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, HEVCEncoder.keyframeIntervalSeconds as CFNumber)
        // Explicit false when off, like `HEVCEncoder` with MATEBRIDGE_PRIO_SPEED=0 (T-086).
        set("PrioritizeEncodingSpeedOverQuality", kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            c.prioritizeSpeed ? kCFBooleanTrue : kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(s)
        var raw: UnsafeMutableRawPointer?
        if VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                 allocator: nil, valueOut: &raw) == noErr, let raw {
            let hw = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
            notes.append("hw=\(hw)")
        }
        return s
    }

    // MARK: Runs

    /// `paceFps == nil`: submit as fast as the encoder accepts (bounded in-flight). Otherwise submit at that rate and
    /// skip frames when the session is full (newest wins, as in the app).
    public static func run(_ c: EncodeBenchConfig, width: Int, height: Int, fps: Int, seconds: Double,
                           paceFps: Int?, pool: [CVPixelBuffer], codec: Codec = .hevc,
                           h264Profile: H264Profile = .high) -> Result {
        let mode = paceFps.map { "paced \($0)" } ?? "max"
        var notes: [String] = []
        var sessions: [VTCompressionSession] = []
        for _ in 0..<c.sessions {
            guard let s = makeSession(c, width: width, height: height, fps: fps, codec: codec, h264Profile: h264Profile,
                                      notes: &notes) else {
                return Result(config: c.name, mode: mode, outFps: 0, submitted: 0, skipped: 0, p50Ms: 0, p95Ms: 0,
                              p99Ms: 0, mbps: 0, note: notes.joined(separator: " "))
            }
            sessions.append(s)
        }
        let slots = DispatchSemaphore(value: c.inFlight * sessions.count)
        let collector = Collector()
        var submitted = 0, skipped = 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        let endNs = t0 + UInt64(seconds * 1e9)
        var next = t0
        let intervalNs = paceFps.map { UInt64(1e9 / Double($0)) } ?? 0
        var frameIndex = 0
        var ptsCounter: Int64 = 0

        while DispatchTime.now().uptimeNanoseconds < endNs {
            if let _ = paceFps {
                next += intervalNs
                let now = DispatchTime.now().uptimeNanoseconds
                if next > now { Thread.sleep(forTimeInterval: Double(next - now) / 1e9) }
                if slots.wait(timeout: .now()) != .success { skipped += 1; continue }
            } else {
                slots.wait()
            }
            // Ping-pong through the pool so consecutive frames always differ by one step (no wrap-around jump).
            let period = max(1, 2 * (pool.count - 1))
            let k = frameIndex % period
            let buf = pool[k < pool.count ? k : period - k]
            let session = sessions[frameIndex % sessions.count]
            frameIndex += 1
            ptsCounter += 1
            let start = DispatchTime.now().uptimeNanoseconds
            let st = VTCompressionSessionEncodeFrame(
                session, imageBuffer: buf, presentationTimeStamp: CMTime(value: ptsCounter, timescale: Int32(fps)),
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sb in
                let us = (DispatchTime.now().uptimeNanoseconds - start) / 1000
                if status == noErr, let sb {
                    let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
                    let isKey = (atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
                    collector.record(us: us, bytes: CMSampleBufferGetTotalSampleSize(sb), isKey: isKey)
                }
                else { collector.fail() }
                slots.signal()
            }
            if st != noErr { collector.fail(); slots.signal(); notes.append("encode=\(st)"); break }
            submitted += 1
        }
        for s in sessions { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        for s in sessions { VTCompressionSessionInvalidate(s) }

        collector.lock.lock(); defer { collector.lock.unlock() }
        let d = collector.durationsUs
        if collector.failures > 0 { notes.append("failures=\(collector.failures)") }
        return Result(
            config: c.name, mode: mode, outFps: Double(collector.outputs) / elapsed, submitted: submitted,
            skipped: skipped,
            p50Ms: Double(CadenceWindow.percentile(d, 50)) / 1000, p95Ms: Double(CadenceWindow.percentile(d, 95)) / 1000,
            p99Ms: Double(CadenceWindow.percentile(d, 99)) / 1000,
            mbps: Double(collector.bytes) * 8 / elapsed / 1e6,
            sizes: FrameSizeStats(frames: collector.frames),
            meanBytes: collector.outputs > 0 ? Double(collector.bytes) / Double(collector.outputs) : 0,
            note: Array(Set(notes)).sorted().joined(separator: " "))
    }

    /// Human-readable list of the HEVC (or H.264) encoders VideoToolbox offers.
    public static func encoderList(codec: Codec = .hevc) -> [String] {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let arr = list as? [[String: Any]] else { return [] }
        return arr.compactMap { e in
            guard let type = e[kVTVideoEncoderList_CodecType as String] as? Int,
                  type == Int(HEVCEncoder.codecType(codec)) else { return nil }
            let id = e[kVTVideoEncoderList_EncoderID as String] as? String ?? "?"
            let hw = (e[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
            return "\(id) hardware=\(hw)"
        }
    }

    /// Returns the process exit code. The codec knobs are read from the environment here (T-086).
    public static func runAll(_ options: EncodeBenchOptions) -> Int32 {
        let o = options.applyingEnvironment(ProcessInfo.processInfo.environment)
        let width = 2800, height = 1840
        print("encode-bench \(width)x\(height) fps=\(o.fps) seconds=\(o.seconds) content=\(o.content.rawValue) "
              + "codec=\(o.codec.logName)\(o.codec == .h264 ? " profile=\(o.h264Profile.rawValue)" : "")"
              + (o.bitrateOverrideKbps.map { " bitrate_kbps=\($0)" } ?? ""))
        print("encoders: \(encoderList(codec: o.codec).joined(separator: "; "))")
        let pool = makeFramePool(width: width, height: height, count: 12, content: o.content)
        guard pool.count == 12 else { print("error: cannot allocate frames"); return 1 }
        print("config | mode | out fps | submitted | skipped | enc ms p50/p95/p99 | Mbps | KB/frame | delta KB p50/p99/max (mean, p99/mean) | key KB max (n) | notes")
        for c in o.configs {
            for pace in [nil, o.fps] as [Int?] {
                let r = run(c, width: width, height: height, fps: o.fps, seconds: o.seconds, paceFps: pace, pool: pool,
                            codec: o.codec, h264Profile: o.h264Profile)
                let z = r.sizes
                print(String(format: "%@ | %@ | %.1f | %d | %d | %.1f/%.1f/%.1f | %.1f | %.1f | %.0f/%.0f/%.0f (%.0f, %.2fx) | %.0f (%d) | %@",
                             r.config, r.mode, r.outFps, r.submitted, r.skipped, r.p50Ms, r.p95Ms, r.p99Ms, r.mbps,
                             r.meanBytes / 1000,
                             Double(z.deltaP50) / 1000, Double(z.deltaP99) / 1000, Double(z.deltaMax) / 1000,
                             z.deltaMean / 1000, z.p99ToMean, Double(z.keyMax) / 1000, z.keyCount, r.note))
                fflush(stdout)
            }
        }
        return 0
    }
}
