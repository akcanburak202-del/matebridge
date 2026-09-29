import CoreMedia
import CoreVideo
import Foundation
import MateBridgeCore
import VideoToolbox

public enum VideoEncoderError: Error, CustomStringConvertible {
    case sessionCreation(OSStatus)
    case encode(OSStatus)

    public var description: String {
        switch self {
        case .sessionCreation(let s): return "VTCompressionSessionCreate failed (\(s))"
        case .encode(let s): return "VTCompressionSessionEncodeFrame failed (\(s))"
        }
    }
}

/// Real-time HEVC encoder: low-latency rate control, no B-frames, keyframes on demand.
/// Output is delivered as Annex-B `EncodedVideoFrame`s; the first output (and any change of
/// parameter sets) is preceded by a CODEC_CONFIG frame.
final class HEVCEncoder: @unchecked Sendable {
    typealias Output = @Sendable (EncodedVideoFrame, _ encodeTimeUs: UInt64) -> Void

    private var session: VTCompressionSession?
    private let output: Output
    private let lock = NSLock()
    private var forceKeyframe = true          // the very first frame is a keyframe
    private var lastParameterSets: [UInt8] = []
    private var inFlight = 0
    /// Frames submitted but not yet emitted; beyond this, new captures are skipped (bounded, newest wins).
    static let maxInFlight = 3

    private(set) var settings: VideoSettings

    init(settings: VideoSettings, output: @escaping Output) throws {
        self.settings = settings
        self.output = output

        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(settings.widthPx), height: Int32(settings.heightPx),
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { throw VideoEncoderError.sessionCreation(status) }
        session = s

        func set(_ key: CFString, _ value: CFTypeRef) {
            _ = VTSessionSetProperty(s, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, settings.fps as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, (settings.bitrateKbps * 1000) as CFNumber)
        // Cap bursts (bytes per second) at 2x the average.
        set(kVTCompressionPropertyKey_DataRateLimits, [settings.bitrateKbps * 1000 / 8 * 2, 1] as CFArray)
        // Keyframes are requested on demand; a periodic one bounds recovery time anyway.
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10 as CFNumber)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        // Colour tags consistent with STREAM_CONFIG (sRGB / BT.709, full range).
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    /// The next encoded frame will be a keyframe.
    func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    /// Encodes one captured frame. Input must be full-range 4:2:0 (see `ScreenCapture`).
    /// Returns false if the frame was skipped because the encoder is backed up.
    @discardableResult
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, captureTimeUs: UInt64) throws -> Bool {
        guard let session else { return false }
        lock.lock()
        if inFlight >= HEVCEncoder.maxInFlight { lock.unlock(); return false }
        inFlight += 1
        let key = forceKeyframe
        forceKeyframe = false
        lock.unlock()
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let start = DispatchTime.now().uptimeNanoseconds
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime,
            duration: .invalid, frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            self.lock.lock(); self.inFlight -= 1; self.lock.unlock()
            guard status == noErr, let sampleBuffer else {
                // A frame the encoder dropped breaks the reference chain: recover with a keyframe.
                self.requestKeyframe()
                return
            }
            let elapsedUs = (DispatchTime.now().uptimeNanoseconds - start) / 1000
            self.handle(sampleBuffer, captureTimeUs: captureTimeUs, encodeTimeUs: elapsedUs)
        }
        if status != noErr {
            lock.lock(); inFlight -= 1; lock.unlock()
            requestKeyframe()
            throw VideoEncoderError.encode(status)
        }
        return true
    }

    /// Flushes pending frames and tears the session down.
    func stop() {
        guard let s = session else { return }
        session = nil
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(s)
    }

    deinit { stop() }

    private func handle(_ sb: CMSampleBuffer, captureTimeUs: UInt64, encodeTimeUs: UInt64) {
        guard let format = CMSampleBufferGetFormatDescription(sb) else { return }
        let isKey: Bool = {
            guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
                  let first = arr.first else { return true }
            return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        }()

        // Parameter sets are re-announced only when they change (first frame included).
        var count = 0
        var lengthSize: Int32 = 4
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
        var sets: [[UInt8]] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if st == noErr, let ptr { sets.append(Array(UnsafeBufferPointer(start: ptr, count: size))) }
        }
        let blob = AnnexB.parameterSets(sets)
        lock.lock()
        let changed = !blob.isEmpty && blob != lastParameterSets
        if changed { lastParameterSets = blob }
        lock.unlock()
        if changed {
            output(EncodedVideoFrame(flags: .codecConfig, captureTimeUs: 0, data: blob), 0)
        }

        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        var length = 0
        var base: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &base) == kCMBlockBufferNoErr, let base else { return }
        let raw = Array(UnsafeBufferPointer(start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                                            count: length))
        guard let annexB = AnnexB.convert(lengthPrefixed: raw, lengthSize: Int(lengthSize)) else { return }
        output(EncodedVideoFrame(flags: isKey ? .keyframe : [], captureTimeUs: captureTimeUs, data: annexB),
               encodeTimeUs)
    }

    /// CODEC_CONFIG for a newly attached consumer (nil before the first frame was encoded).
    func currentCodecConfig() -> EncodedVideoFrame? {
        lock.lock(); defer { lock.unlock() }
        return lastParameterSets.isEmpty ? nil
            : EncodedVideoFrame(flags: .codecConfig, captureTimeUs: 0, data: lastParameterSets)
    }
}
