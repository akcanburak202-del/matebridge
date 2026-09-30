import CoreMedia
import CoreVideo
import Foundation
import MateBridgeCore
import VideoToolbox

/// `MateBridgeApp --encode-bench` (T-047): measures how fast VideoToolbox HEVC can encode 2800x1840 frames under
/// different session configurations. Synthetic frames only; no display, SCK, input or network is touched.
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
        public var note: String
    }

    // MARK: Synthetic frames

    /// Full-range 4:2:0, like `ScreenCapture`. Each pool frame differs: a sliding gradient plus text-like glyph cells.
    static func makeFramePool(width: Int, height: Int, count: Int) -> [CVPixelBuffer] {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        var pool: [CVPixelBuffer] = []
        for f in 0..<count {
            var pb: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                      attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            fill(pb, width: width, height: height, frame: f)
            CVPixelBufferUnlockBaseAddress(pb, [])
            pool.append(pb)
        }
        return pool
    }

    private static func fill(_ pb: CVPixelBuffer, width: Int, height: Int, frame: Int) {
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
        var outputs = 0
        var failures = 0
        func record(us: UInt64, bytes b: Int) { lock.lock(); durationsUs.append(us); bytes += b; outputs += 1; lock.unlock() }
        func fail() { lock.lock(); failures += 1; lock.unlock() }
    }

    private static func makeSession(_ c: EncodeBenchConfig, width: Int, height: Int, fps: Int,
                                    notes: inout [String]) -> VTCompressionSession? {
        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        if c.lowLatencyRateControl { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
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
            c.main10 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
        set("ExpectedFrameRate", kVTCompressionPropertyKey_ExpectedFrameRate, (c.expectedFps ?? fps) as CFNumber)
        set("AverageBitRate", kVTCompressionPropertyKey_AverageBitRate, (c.bitrateKbps * 1000) as CFNumber)
        if c.dataRateLimits {
            set("DataRateLimits", kVTCompressionPropertyKey_DataRateLimits, [c.bitrateKbps * 1000 / 8 * 2, 1] as CFArray)
        }
        set("MaxKeyFrameIntervalDuration", kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10 as CFNumber)
        if c.prioritizeSpeed {
            set("PrioritizeEncodingSpeedOverQuality", kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                kCFBooleanTrue)
        }
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
                           paceFps: Int?, pool: [CVPixelBuffer]) -> Result {
        let mode = paceFps.map { "paced \($0)" } ?? "max"
        var notes: [String] = []
        var sessions: [VTCompressionSession] = []
        for _ in 0..<c.sessions {
            guard let s = makeSession(c, width: width, height: height, fps: fps, notes: &notes) else {
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
            let buf = pool[frameIndex % pool.count]
            let session = sessions[frameIndex % sessions.count]
            frameIndex += 1
            ptsCounter += 1
            let start = DispatchTime.now().uptimeNanoseconds
            let st = VTCompressionSessionEncodeFrame(
                session, imageBuffer: buf, presentationTimeStamp: CMTime(value: ptsCounter, timescale: Int32(fps)),
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sb in
                let us = (DispatchTime.now().uptimeNanoseconds - start) / 1000
                if status == noErr, let sb { collector.record(us: us, bytes: CMSampleBufferGetTotalSampleSize(sb)) }
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
            mbps: Double(collector.bytes) * 8 / elapsed / 1e6, note: Array(Set(notes)).sorted().joined(separator: " "))
    }

    /// Human-readable list of HEVC encoders VideoToolbox offers.
    public static func encoderList() -> [String] {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let arr = list as? [[String: Any]] else { return [] }
        return arr.compactMap { e in
            guard let codec = e[kVTVideoEncoderList_CodecName as String] as? String, codec.contains("H.265") || codec.contains("HEVC") else { return nil }
            let id = e[kVTVideoEncoderList_EncoderID as String] as? String ?? "?"
            let hw = (e[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
            return "\(id) hardware=\(hw)"
        }
    }

    /// Returns the process exit code.
    public static func runAll(_ o: EncodeBenchOptions) -> Int32 {
        let width = 2800, height = 1840
        print("encode-bench \(width)x\(height) fps=\(o.fps) seconds=\(o.seconds)")
        print("encoders: \(encoderList().joined(separator: "; "))")
        let pool = makeFramePool(width: width, height: height, count: 12)
        guard pool.count == 12 else { print("error: cannot allocate frames"); return 1 }
        print("config | mode | out fps | submitted | skipped | enc ms p50/p95/p99 | Mbps | notes")
        for c in o.configs {
            for pace in [nil, o.fps] as [Int?] {
                let r = run(c, width: width, height: height, fps: o.fps, seconds: o.seconds, paceFps: pace, pool: pool)
                print(String(format: "%@ | %@ | %.1f | %d | %d | %.1f/%.1f/%.1f | %.1f | %@",
                             r.config, r.mode, r.outFps, r.submitted, r.skipped, r.p50Ms, r.p95Ms, r.p99Ms, r.mbps, r.note))
                fflush(stdout)
            }
        }
        return 0
    }
}
