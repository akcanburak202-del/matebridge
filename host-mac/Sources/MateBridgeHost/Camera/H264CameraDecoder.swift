import CoreMedia
import CoreVideo
import Foundation
import MateBridgeCore
import VideoToolbox

/// Decodes the tablet camera's H.264 (Annex-B `CAM_FRAME` data, decision 0040) to BGRA pixel buffers with
/// VideoToolbox. `CODEC_CONFIG` (SPS + PPS) builds the session; a changed config rebuilds it. All methods run on the one
/// serial queue of the owner (`DecodeQueue`); results come back through the `completion` of each frame on a VideoToolbox
/// thread. Frame content is never logged or written.
/// A pixel buffer handed between the camera queues (it is never mutated after the decoder produced it).
struct CameraPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}

final class H264CameraDecoder: @unchecked Sendable {
    enum Result: Sendable {
        /// A decoded BGRA frame at the stream's own size.
        case frame(CameraPixelBuffer)
        /// The decoder accepted the frame but produced no picture (not an error).
        case noPicture
        case failed(status: Int32)
    }

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentSets: [[UInt8]] = []

    /// Whether a session exists (a usable `CODEC_CONFIG` was seen).
    var isConfigured: Bool { session != nil }

    deinit { invalidate() }

    /// `CODEC_CONFIG` data: Annex-B SPS and PPS. Rebuilds the session only if they differ from the current ones.
    /// Returns false for data without both (the frame is then ignored and the next keyframe is awaited).
    @discardableResult
    func configure(annexB: [UInt8]) -> Bool {
        let nals = AnnexB.nalUnits(annexB)
        guard let sps = nals.first(where: { ($0.first ?? 0) & 0x1F == 7 }),
              let pps = nals.first(where: { ($0.first ?? 0) & 0x1F == 8 }) else { return false }
        let sets = [sps, pps]
        if session != nil, sets == currentSets { return true }
        invalidate()
        var fd: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p -> OSStatus in
                let pointers: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
                let sizes = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        guard status == 0, let fd else { return false }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let specification: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        var created: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: fd, decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created)
        guard createStatus == 0, let created else { return false }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        formatDescription = fd
        currentSets = sets
        return true
    }

    /// One access unit (Annex-B). A keyframe that carries its own SPS/PPS rebuilds the session when they changed.
    /// `completion` runs exactly once, on a VideoToolbox thread (or at once when the frame cannot be submitted).
    func decode(annexB: [UInt8], captureTimeUs: UInt64, completion: @escaping @Sendable (Result) -> Void) {
        let nals = AnnexB.nalUnits(annexB)
        if nals.contains(where: { ($0.first ?? 0) & 0x1F == 7 }), nals.contains(where: { ($0.first ?? 0) & 0x1F == 8 }) {
            configure(annexB: annexB)
        }
        guard let session, let formatDescription else { return completion(.failed(status: -1)) }
        // Annex-B to length-prefixed (4 bytes), without the parameter sets and access unit delimiters.
        var avcc: [UInt8] = []
        avcc.reserveCapacity(annexB.count + 16)
        for nal in nals where !nal.isEmpty {
            let type = nal[0] & 0x1F
            if type == 7 || type == 8 || type == 9 { continue }
            let n = UInt32(nal.count)
            avcc += [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            avcc += nal
        }
        guard !avcc.isEmpty else { return completion(.noPicture) }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard status == 0, let block else { return completion(.failed(status: status)) }
        status = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: avcc.count)
        }
        guard status == 0 else { return completion(.failed(status: status)) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(clamping: captureTimeUs), timescale: 1_000_000), // wire u64; never trap (Codex r7)
                                        decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
                                           sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == 0, let sample else { return completion(.failed(status: status)) }
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._1xRealTimePlayback]
        var infoFlags = VTDecodeInfoFlags()
        let submit = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, infoFlagsOut: &infoFlags) {
            status, _, imageBuffer, _, _ in
            if status != 0 { completion(.failed(status: status)) } else if let imageBuffer { completion(.frame(CameraPixelBuffer(imageBuffer))) } else {
                completion(.noPicture)
            }
        }
        if submit != 0 { completion(.failed(status: submit)) }
    }

    /// Finishes the frames in flight and drops the session. Idempotent.
    func invalidate() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
        formatDescription = nil
        currentSets = []
    }
}

/// Scales decoded frames to the OBS sink size (1920x1080 BGRA). A frame already at that size passes through untouched.
/// A different aspect ratio is letterboxed on black, never stretched. Owned by one queue.
final class CameraFrameScaler: @unchecked Sendable {
    private let width: Int
    private let height: Int
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    deinit { if let transfer { VTPixelTransferSessionInvalidate(transfer) } }

    /// The frame at the sink size, or nil if scaling failed (the frame is dropped).
    func scaled(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let sw = CVPixelBufferGetWidth(source), sh = CVPixelBufferGetHeight(source)
        if sw == width, sh == height, CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA { return source }
        guard let destination = makeDestination() else { return nil }
        if transfer == nil {
            var created: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &created) == 0,
                  let created else { return nil }
            transfer = created
        }
        guard let transfer else { return nil }
        let sameAspect = abs(sw * height - sh * width) <= max(width, height)  // within a pixel of the same ratio
        if sameAspect {
            VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        } else {
            blacken(destination)
            VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        }
        guard VTPixelTransferSessionTransferImage(transfer, from: source, to: destination) == 0 else { return nil }
        return destination
    }

    private func makeDestination() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created) == kCVReturnSuccess
            else { return nil }
            pool = created
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    private func blacken(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            let line = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            // BGRA opaque black: B=G=R=0, A=255 (little endian word 0xFF000000).
            for x in 0..<width { line[x] = 0xFF00_0000 }
        }
    }
}
