import CoreGraphics
import CoreMedia
import CoreVideo
import DecProbeCore
import Foundation
import VideoToolbox

/// Encodes one clip (a crop of [Scene]) to an Annex-B HEVC file with MateBridge's fast-profile settings: hardware
/// HEVC Main 8-bit, no low-latency rate control, RealTime=false, no frame reordering, speed over quality, burst cap
/// 2x the average, one IDR (frame 0; the Android probe loops by restarting there). Offline: frames are submitted as
/// fast as the encoder takes them (at most [maxInFlight] queued), never paced. Uses the hardware encoder, so do not
/// run it while a MateBridge stream is live.
final class ClipEncoder: @unchecked Sendable {
    struct Result {
        var frames = 0
        var bytes = 0
        var errors = 0
        var seconds = 0.0
        var settings: [String] = []
    }

    private let spec: ClipSpec
    private let scene: Scene
    private let frames: Int
    private let fps: Int
    private let maxInFlight = 4
    private let lock = NSLock()
    private var output: [Int: [UInt8]] = [:]
    private var errors = 0

    init(spec: ClipSpec, scene: Scene, frames: Int, fps: Int) {
        self.spec = spec
        self.scene = scene
        self.frames = frames
        self.fps = fps
    }

    func run(to path: String) throws -> Result {
        var result = Result()
        var session: VTCompressionSession?
        let encSpec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        let srcAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: spec.width, kCVPixelBufferHeightKey: spec.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(spec.width), height: Int32(spec.height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encSpec as CFDictionary, imageBufferAttributes: srcAttrs as CFDictionary,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard st == noErr, let session else { throw ProbeError("VTCompressionSessionCreate \(spec.id): \(st)") }
        defer { VTCompressionSessionInvalidate(session) }

        func set(_ name: String, _ key: CFString, _ value: CFTypeRef) {
            let s = VTSessionSetProperty(session, key: key, value: value)
            result.settings.append("\(name)=\(s == noErr ? "ok" : String(s))")
        }
        set("RealTime", kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        set("AllowFrameReordering", kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel,
            spec.depth == .b8 ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_HEVC_Main10_AutoLevel)
        set("ExpectedFrameRate", kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set("AverageBitRate", kVTCompressionPropertyKey_AverageBitRate, (spec.bitrateKbps * 1000) as CFNumber)
        let bytesPerSecond = spec.bitrateKbps * 1000 / 8 * 2
        set("DataRateLimits", kVTCompressionPropertyKey_DataRateLimits, [bytesPerSecond, 1] as CFArray)
        set("MaxKeyFrameInterval", kVTCompressionPropertyKey_MaxKeyFrameInterval,
            (spec.idrInterval > 0 ? spec.idrInterval : frames + 1) as CFNumber)
        set("PrioritizeEncodingSpeedOverQuality", kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            kCFBooleanTrue)
        let colour = Self.colour(spec.depth)
        set("ColorPrimaries", kVTCompressionPropertyKey_ColorPrimaries, colour.primaries)
        set("TransferFunction", kVTCompressionPropertyKey_TransferFunction, colour.transfer)
        set("YCbCrMatrix", kVTCompressionPropertyKey_YCbCrMatrix, colour.matrix)
        if spec.depth == .pq10 {
            set("MasteringDisplayColorVolume", kVTCompressionPropertyKey_MasteringDisplayColorVolume,
                Data(HDR10SEI.mdcv()) as CFData)
            set("ContentLightLevelInfo", kVTCompressionPropertyKey_ContentLightLevelInfo, Data(HDR10SEI.cll()) as CFData)
            set("HDRMetadataInsertionMode", kVTCompressionPropertyKey_HDRMetadataInsertionMode,
                kVTHDRMetadataInsertionMode_Auto)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else {
            throw ProbeError("no pixel buffer pool for \(spec.id)")
        }

        let slots = DispatchSemaphore(value: maxInFlight)
        let start = Date()
        for i in 0..<frames {
            var pbOut: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else {
                throw ProbeError("pixel buffer \(i)")
            }
            render(frame: i, into: pb)
            slots.wait()
            let pts = CMTime(value: Int64(i), timescale: Int32(fps))
            let s = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pb, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: Int32(fps)),
                frameProperties: nil, infoFlagsOut: nil
            ) { [weak self] status, _, sample in
                self?.done(index: i, status: status, sample: sample)
                slots.signal()
            }
            if s != noErr {
                lock.withLock { errors += 1 }
                slots.signal()
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        result.seconds = Date().timeIntervalSince(start)

        // Outputs arrive in order (no reordering), but callbacks may run on any thread: write by frame index.
        let (chunks, errs) = lock.withLock { (output, errors) }
        var file = Data()
        for i in 0..<frames {
            guard let c = chunks[i] else { continue }
            file.append(contentsOf: c)
            result.frames += 1
        }
        try file.write(to: URL(fileURLWithPath: path))
        result.bytes = file.count
        result.errors = errs
        return result
    }

    private func render(frame i: Int, into pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: spec.width, height: spec.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        scene.draw(frame: i, into: ctx, originX: spec.x, originY: spec.y, clipHeight: spec.height)
        let colour = Self.colour(spec.depth)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, colour.primaries, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, colour.transfer, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, colour.matrix, .shouldPropagate)
    }

    private static func colour(_ d: ClipDepth) -> (primaries: CFString, transfer: CFString, matrix: CFString) {
        switch d {
        case .b8, .sdr10:
            return (kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2,
                    kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        case .pq10:
            return (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                    kCVImageBufferYCbCrMatrix_ITU_R_2020)
        }
    }

    private func done(index: Int, status: OSStatus, sample: CMSampleBuffer?) {
        guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample),
              let fmt = CMSampleBufferGetFormatDescription(sample)
        else {
            lock.withLock { errors += 1 }
            return
        }
        var raw = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: &raw)

        var nalLen: Int32 = 4
        var psCount = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &psCount,
                                                           nalUnitHeaderLengthOut: &nalLen)
        guard var annexB = AnnexB.fromLengthPrefixed(raw, lengthSize: Int(nalLen)) else {
            lock.withLock { errors += 1 }
            return
        }
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
            if spec.depth == .pq10 { sets += HDR10SEI.nalUnits() }   // VT keeps HDR10 SEI out of the samples
            annexB = AnnexB.join(sets) + annexB
        }
        lock.withLock { output[index] = annexB }
    }

    private func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = atts.first
        else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
