import CoreMedia
import CoreVideo
import Foundation
import MateBridgeCore
import os
import VideoToolbox

/// The auxiliary VideoToolbox session of packed full colour (decision 0034, T-258): encodes the AVC444v2 auxiliary
/// `420f` picture with the same fast profile as the main session, at a quarter of the main target bitrate (`AuxBitratePolicy`).
///
/// Driven by `HEVCEncoder` from its single submit owner queue (`encode`), so the auxiliary PTS rise exactly like the
/// main ones and carry the same value. It never waits for the main session and the main session never waits for it:
/// at most `maxInFlight` (2) auxiliary frames are inside VideoToolbox, and a frame that finds both busy is dropped
/// (`encode` returns false) and the caller asks for an auxiliary keyframe, because the dropped frame broke that
/// stream's reference chain.
/// A property the auxiliary session needs for bit-exact samples was refused.
struct AuxSetupError: Error, CustomStringConvertible {
    let detail: String
    var description: String { "aux property refused: \(detail)" }
}

final class PackedAuxEncoder: @unchecked Sendable {
    typealias Output = @Sendable (EncodedVideoFrame, _ encodeTimeUs: UInt64) -> Void

    static let maxInFlight = 2
    static let failureLimit = 5
    private static let log = Logger(subsystem: "dev.matebridge.host", category: "aux-encoder")

    /// The auxiliary target as a fraction of the main one (`AuxBitratePolicy`, T-262).
    static func auxBitrateKbps(main kbps: Int) -> Int { AuxBitratePolicy.kbps(main: kbps) }

    private let session: VTCompressionSession
    private let output: Output
    private let onError: @Sendable (String) -> Void
    /// An accepted frame was lost afterwards (VideoToolbox failed it, or it followed a lost one and was discarded): the
    /// caller counts a loss and re-arms the auxiliary IDR. Argument: that frame's `capture_time_us`.
    private let onLoss: @Sendable (UInt64) -> Void
    /// A frame was lost after submission: later deltas reference a broken chain and are discarded until a keyframe.
    private var awaitingKeyframe = false
    private let lock = NSLock()
    private var inFlight = 0
    private var failures = 0
    private var lastParameterSets: [UInt8] = []
    private var closed = false
    /// Property failures at creation ("Name=<OSStatus>"), for diagnostics.
    private(set) var propertyFailures: [String] = []

    /// - Parameters:
    ///   - mainKbps: the main session's target; the auxiliary one follows `AuxBitratePolicy`.
    init(width: Int, height: Int, fps: Int, mainKbps: Int, rateWindowMs: Int?,
         output: @escaping Output,
         onError: @escaping @Sendable (String) -> Void,
         onLoss: @escaping @Sendable (UInt64) -> Void = { _ in }) throws {
        self.output = output
        self.onError = onError
        self.onLoss = onLoss
        let kbps = Self.auxBitrateKbps(main: mainKbps)
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { throw VideoEncoderError.sessionCreation(status) }
        session = s
        var failed: [String] = []
        func set(_ name: String, _ key: CFString, _ value: CFTypeRef) {
            let st = VTSessionSetProperty(s, key: key, value: value)
            if st != noErr {
                failed.append("\(name)=\(st)")
                Self.log.error("ev=prop_set_failed key=\(name, privacy: .public) status=\(st)")
            }
        }
        set("RealTime", kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        set("AllowFrameReordering", kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set("ExpectedFrameRate", kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set("AverageBitRate", kVTCompressionPropertyKey_AverageBitRate, (kbps * 1000) as CFNumber)
        set("DataRateLimits", kVTCompressionPropertyKey_DataRateLimits,
            HEVCEncoder.dataRateLimits(kbps: kbps, shortWindowMs: rateWindowMs))
        set("MaxKeyFrameIntervalDuration", kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            HEVCEncoder.keyframeIntervalSeconds as CFNumber)
        set("PrioritizeEncodingSpeedOverQuality", kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            kCFBooleanTrue)
        set("ColorPrimaries", kVTCompressionPropertyKey_ColorPrimaries, HEVCEncoder.sessionPrimaries)
        set("TransferFunction", kVTCompressionPropertyKey_TransferFunction, HEVCEncoder.sessionTransfer)
        set("YCbCrMatrix", kVTCompressionPropertyKey_YCbCrMatrix, HEVCEncoder.sessionMatrix)
        let prepared = VTCompressionSessionPrepareToEncodeFrames(s)
        if prepared != noErr { failed.append("PrepareToEncodeFrames=\(prepared)") }
        propertyFailures = failed
        // The auxiliary samples are raw chroma: if the session does not carry exactly the session colour tags (or the
        // profile), VideoToolbox would colour-convert the buffers and corrupt the packed chroma silently. Any refused
        // required property is a setup failure (the owner falls back, `reason=aux_setup`).
        let required = ["ProfileLevel", "ColorPrimaries", "TransferFunction", "YCbCrMatrix"]
        if let refused = failed.first(where: { f in required.contains { f.hasPrefix($0 + "=") } }) {
            VTCompressionSessionInvalidate(s)
            throw AuxSetupError(detail: refused)
        }
        if prepared != noErr {
            VTCompressionSessionInvalidate(s)
            throw VideoEncoderError.sessionCreation(prepared)
        }
    }

    /// Frames inside VideoToolbox right now.
    var framesInFlight: Int { lock.withLock { inFlight } }

    /// Submits one auxiliary picture. false = not submitted (both slots busy, the session is closed, or VideoToolbox
    /// refused it): the caller counts a loss and requests an auxiliary keyframe. Owner queue only.
    func encode(_ buffer: CVPixelBuffer, presentationTime: CMTime, captureTimeUs: UInt64, pairID: UInt64,
                keyframe: Bool) -> Bool {
        let accepted: Bool = lock.withLock {
            guard !closed, inFlight < Self.maxInFlight else { return false }
            inFlight += 1
            return true
        }
        guard accepted else { return false }
        let props: CFDictionary? = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let start = DispatchTime.now().uptimeNanoseconds
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: presentationTime, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            self.completed(status: status, sampleBuffer: sampleBuffer, captureTimeUs: captureTimeUs, pairID: pairID,
                           encodeUs: (DispatchTime.now().uptimeNanoseconds - start) / 1000)
        }
        if status != noErr {
            Self.log.error("ev=aux_encode_failed status=\(status)")
            failedFrame()  // the caller sees `false`: it counts the loss and re-arms the keyframe itself
            return false
        }
        return true
    }

    /// CODEC_CONFIG of the auxiliary stream (`view = 1`); nil before the first frame was encoded.
    func currentCodecConfig() -> EncodedVideoFrame? {
        lock.withLock {
            guard !lastParameterSets.isEmpty else { return nil }
            var f = EncodedVideoFrame(flags: .codecConfig, captureTimeUs: 0, data: lastParameterSets)
            f.view = 1
            return f
        }
    }

    /// The SPS of the last parameter sets, for `ev=chroma_config`.
    var lastSets: [[UInt8]] { lock.withLock { AnnexB.nalUnits(lastParameterSets) } }

    /// Flushes and closes the session. Synchronous; call from the owner queue or a dispatch queue, never from a Swift
    /// cooperative thread. Idempotent.
    func stop() {
        let wasClosed: Bool = lock.withLock { defer { closed = true }; return closed }
        guard !wasClosed else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    private func failedFrame() {
        let trip: Bool = lock.withLock {
            inFlight = max(0, inFlight - 1)
            failures += 1
            return failures == Self.failureLimit
        }
        if trip { onError("aux_encode_errors") }
    }

    private func completed(status: OSStatus, sampleBuffer: CMSampleBuffer?, captureTimeUs: UInt64, pairID: UInt64,
                           encodeUs: UInt64) {
        guard status == noErr, let sb = sampleBuffer else {
            Self.log.error("ev=aux_encode_no_output status=\(status)")
            lock.withLock { awaitingKeyframe = true }
            failedFrame()
            onLoss(captureTimeUs)
            return
        }
        lock.withLock { failures = 0 }
        let delivered = handle(sb, captureTimeUs: captureTimeUs, pairID: pairID, encodeUs: encodeUs)
        lock.withLock { inFlight = max(0, inFlight - 1) }
        if !delivered { onLoss(captureTimeUs) }
    }

    /// true when the frame went to `output`; false when it was discarded (after a lost frame, until a keyframe).
    @discardableResult
    private func handle(_ sb: CMSampleBuffer, captureTimeUs: UInt64, pairID: UInt64, encodeUs: UInt64) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(sb) else { return false }
        let isKey: Bool = {
            guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
                  let first = arr.first else { return true }
            return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        }()
        let discard: Bool = lock.withLock {
            if isKey { awaitingKeyframe = false }
            return awaitingKeyframe
        }
        if discard { return false }
        let (sets, lengthSize) = HEVCEncoder.parameterSets(format, codec: .hevc)
        let blob = AnnexB.parameterSets(sets)
        let changed: Bool = lock.withLock {
            let c = !blob.isEmpty && blob != lastParameterSets
            if c { lastParameterSets = blob }
            return c
        }
        if changed {
            var config = EncodedVideoFrame(flags: .codecConfig, captureTimeUs: 0, data: blob)
            config.view = 1
            output(config, 0)
        }
        guard let block = CMSampleBufferGetDataBuffer(sb), let raw = HEVCEncoder.bytes(of: block),
              let annexB = AnnexB.convert(lengthPrefixed: raw, lengthSize: lengthSize) else { return false }
        var frame = EncodedVideoFrame(flags: isKey ? .keyframe : [], captureTimeUs: captureTimeUs, data: annexB)
        frame.view = 1
        frame.pairID = pairID
        output(frame, encodeUs)
        return true
    }

    deinit { stop() }
}
