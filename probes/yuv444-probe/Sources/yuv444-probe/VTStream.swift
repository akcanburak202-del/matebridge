import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import YUV444Core
import YUV444GPU

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// One hardware HEVC encode session with MateBridge's fast-profile settings (`HEVCEncoder`): Main profile, RealTime
/// false, no low-latency rate control, no reordering, speed over quality, burst cap 2x the average, colour tags of
/// `SessionTags`. Outputs come on VideoToolbox's callback threads.
final class VTStream: @unchecked Sendable {
    struct Config {
        var width: Int
        var height: Int
        var fps: Int = 60
        var bitrateKbps: Int = 20_000
        /// Constant quality 0...1 instead of an average bitrate (falls back to the bitrate if refused).
        var quality: Float? = nil
        /// Only the first frame is a keyframe unless `forceKey` is passed per frame.
        var keyframeEveryFrames: Int = 0
        /// Tags the session declares (default = MateBridge's). Tests override them.
        var primaries: CFString = SessionTags.primaries
        var transfer: CFString = SessionTags.transfer
        var matrix: CFString = SessionTags.matrix
    }

    struct Output {
        var index: Int
        var bytes: Int
        var isSync: Bool
        var sample: CMSampleBuffer
    }

    let config: Config
    private(set) var settingsReport: [String] = []
    private(set) var qualityApplied = false
    private let session: VTCompressionSession

    init(_ config: Config) throws {
        self.config = config
        var s: VTCompressionSession?
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(config.width), height: Int32(config.height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw ProbeError("VTCompressionSessionCreate: \(st)") }
        session = s
        var report: [String] = []
        func set(_ name: String, _ key: CFString, _ value: CFTypeRef) {
            let r = VTSessionSetProperty(s, key: key, value: value)
            report.append("\(name)=\(r == noErr ? "ok" : String(r))")
        }
        set("RealTime", kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        set("AllowFrameReordering", kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set("ExpectedFrameRate", kVTCompressionPropertyKey_ExpectedFrameRate, config.fps as CFNumber)
        var q = false
        if let quality = config.quality {
            let r = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber)
            report.append("Quality=\(r == noErr ? "ok" : String(r))")
            q = r == noErr
        }
        qualityApplied = q
        if !q { set("AverageBitRate", kVTCompressionPropertyKey_AverageBitRate, (config.bitrateKbps * 1000) as CFNumber) }
        set("DataRateLimits", kVTCompressionPropertyKey_DataRateLimits,
            [config.bitrateKbps * 1000 / 8 * 2, 1] as CFArray)
        set("MaxKeyFrameInterval", kVTCompressionPropertyKey_MaxKeyFrameInterval,
            (config.keyframeEveryFrames > 0 ? config.keyframeEveryFrames : 1_000_000) as CFNumber)
        set("PrioritizeEncodingSpeedOverQuality", kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set("ColorPrimaries", kVTCompressionPropertyKey_ColorPrimaries, config.primaries)
        set("TransferFunction", kVTCompressionPropertyKey_TransferFunction, config.transfer)
        set("YCbCrMatrix", kVTCompressionPropertyKey_YCbCrMatrix, config.matrix)
        let prepared = VTCompressionSessionPrepareToEncodeFrames(s)
        if prepared != noErr { report.append("Prepare=\(prepared)") }
        settingsReport = report
    }

    deinit { VTCompressionSessionInvalidate(session) }

    /// "ok" when every property was accepted, else the failed ones.
    var settingsSummary: String {
        let bad = settingsReport.filter { !$0.hasSuffix("=ok") }
        return bad.isEmpty ? "ok" : bad.joined(separator: ",")
    }

    var hardware: String {
        var v: CFTypeRef?
        VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: nil, valueOut: &v)
        return (v as? Bool).map { $0 ? "hw" : "sw" } ?? "?"
    }

    /// Submits one frame; `done` runs on a VideoToolbox thread (also on error, with `nil`).
    @discardableResult
    func encode(_ pb: CVPixelBuffer, index: Int, forceKey: Bool = false, done: @escaping @Sendable (Output?) -> Void) -> Bool {
        let pts = CMTime(value: Int64(index), timescale: Int32(config.fps))
        let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: Int32(config.fps)), frameProperties: props, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else { done(nil); return }
            done(Output(index: index, bytes: CMBlockBufferGetDataLength(block), isSync: Self.isSync(sample), sample: sample))
        }
        if st != noErr { done(nil); return false }
        return true
    }

    func finish() { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }

    static func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = atts.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    /// Annex-B bytes of one encoded sample; on sync frames VPS/SPS/PPS are prepended.
    static func annexB(_ sample: CMSampleBuffer) -> [UInt8]? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let fmt = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var raw = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: &raw)
        var nalLen: Int32 = 4
        var psCount = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &psCount,
                                                           nalUnitHeaderLengthOut: &nalLen)
        guard var out = AnnexB.fromLengthPrefixed(raw, lengthSize: Int(nalLen)) else { return nil }
        if isSync(sample) {
            var sets: [[UInt8]] = []
            for k in 0..<psCount {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt, parameterSetIndex: k, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    sets.append(Array(UnsafeBufferPointer(start: ptr, count: size)))
                }
            }
            out = AnnexB.join(sets) + out
        }
        return out
    }
}

/// Decodes encoded samples (in order) to `420f` pixel buffers with VideoToolbox, synchronously.
final class VTDecoder {
    private var session: VTDecompressionSession?

    func decode(_ sample: CMSampleBuffer, handler: @escaping (CVPixelBuffer) -> Void) throws {
        if session == nil {
            guard let fmt = CMSampleBufferGetFormatDescription(sample) else { throw ProbeError("no format description") }
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ]
            var s: VTDecompressionSession?
            let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                                  imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                                  decompressionSessionOut: &s)
            guard st == noErr, let s else { throw ProbeError("VTDecompressionSessionCreate: \(st)") }
            session = s
        }
        guard let session else { return }
        var failure: OSStatus = noErr
        var got = false
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            failure = status
            if status == noErr, let image { got = true; handler(image) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if st != noErr || failure != noErr || !got { throw ProbeError("decode failed: call=\(st) frame=\(failure) got=\(got)") }
    }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}
