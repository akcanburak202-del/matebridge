import CoreMedia
import CoreVideo
import Foundation
import MateBridgeCore
import os
import VideoToolbox

/// The auxiliary VideoToolbox session of packed full colour (decision 0034, T-258): encodes the AVC444v2 auxiliary
/// `420f` picture with the same fast profile as the main session, at half the main target bitrate.
///
/// Driven by `HEVCEncoder` from its single submit owner queue (`encode`), so the auxiliary PTS rise exactly like the
/// main ones and carry the same value. It never waits for the main session and the main session never waits for it:
/// at most `maxInFlight` (2) auxiliary frames are inside VideoToolbox, and a frame that finds both busy is dropped
/// (`encode` returns false) and the caller asks for an auxiliary keyframe, because the dropped frame broke that
/// stream's reference chain.
final class PackedAuxEncoder: @unchecked Sendable {
    typealias Output = @Sendable (EncodedVideoFrame, _ encodeTimeUs: UInt64) -> Void

    static let maxInFlight = 2
    static let failureLimit = 5
    private static let log = Logger(subsystem: "dev.matebridge.host", category: "aux-encoder")

    /// The auxiliary target as a fraction of the main one (decision 0034 section 6).
    static func auxBitrateKbps(main kbps: Int) -> Int { max(1_000, kbps / 2) }

    private let session: VTCompressionSession
    private let output: Output
    private let onError: @Sendable (String) -> Void
    private let lock = NSLock()
    private var inFlight = 0
    private var failures = 0
    private var lastParameterSets: [UInt8] = []
    private var closed = false
    private var currentKbps: Int
    private let rateWindowMs: Int?
    private let logSink: HEVCEncoder.LogSink
    /// Property failures at creation ("Name=<OSStatus>"), for diagnostics.
    private(set) var propertyFailures: [String] = []

    /// - Parameters:
    ///   - mainKbps: the main session's target; the auxiliary one is half of it.
    ///   - profile: the main session's resolved profile (the same rate control and speed settings).
    init(width: Int, height: Int, fps: Int, mainKbps: Int, profile: EncoderProfile, rateWindowMs: Int?,
         logSink: @escaping HEVCEncoder.LogSink, output: @escaping Output,
         onError: @escaping @Sendable (String) -> Void) throws {
        self.output = output
        self.onError = onError
        self.rateWindowMs = rateWindowMs
        self.logSink = logSink
        let kbps = Self.auxBitrateKbps(main: mainKbps)
        currentKbps = kbps
        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        if profile != .fast { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
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
        set("RealTime", kVTCompressionPropertyKey_RealTime, profile == .fast ? kCFBooleanFalse : kCFBooleanTrue)
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
        if prepared != noErr {
            VTCompressionSessionInvalidate(s)
            throw VideoEncoderError.sessionCreation(prepared)
        }
    }

    /// Frames inside VideoToolbox right now.
    var framesInFlight: Int { lock.withLock { inFlight } }

    /// Submits one auxiliary picture. false = not submitted (both slots busy, the session is closed, or VideoToolbox
    /// refused it): the caller counts a loss and requests an auxiliary keyframe. Owner queue only.
    func encode(_ buffer: CVPixelBuffer, presentationTime: CMTime, captureTimeUs: UInt64, keyframe: Bool) -> Bool {
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
            self.completed(status: status, sampleBuffer: sampleBuffer, captureTimeUs: captureTimeUs,
                           encodeUs: (DispatchTime.now().uptimeNanoseconds - start) / 1000)
        }
        if status != noErr {
            Self.log.error("ev=aux_encode_failed status=\(status)")
            failedFrame()
            return false
        }
        return true
    }

    /// Live bitrate change (the main target's half), like `HEVCEncoder.setTargetBitrate`.
    func setBitrate(mainKbps: Int) {
        let kbps = Self.auxBitrateKbps(main: mainKbps)
        let apply: Bool = lock.withLock {
            guard !closed, kbps != currentKbps else { return false }
            currentKbps = kbps
            return true
        }
        guard apply else { return }
        let avg = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                       value: (kbps * 1000) as CFNumber)
        let limits = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                                          value: HEVCEncoder.dataRateLimits(kbps: kbps, shortWindowMs: rateWindowMs))
        logSink(.info, "bitrate_set", "view=aux kbps=\(kbps) avg_status=\(avg) limits_status=\(limits)")
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

    private func completed(status: OSStatus, sampleBuffer: CMSampleBuffer?, captureTimeUs: UInt64, encodeUs: UInt64) {
        guard status == noErr, let sb = sampleBuffer else {
            Self.log.error("ev=aux_encode_no_output status=\(status)")
            failedFrame()
            return
        }
        lock.withLock { failures = 0 }
        handle(sb, captureTimeUs: captureTimeUs, encodeUs: encodeUs)
        lock.withLock { inFlight = max(0, inFlight - 1) }
    }

    private func handle(_ sb: CMSampleBuffer, captureTimeUs: UInt64, encodeUs: UInt64) {
        guard let format = CMSampleBufferGetFormatDescription(sb) else { return }
        let isKey: Bool = {
            guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
                  let first = arr.first else { return true }
            return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        }()
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
              let annexB = AnnexB.convert(lengthPrefixed: raw, lengthSize: lengthSize) else { return }
        var frame = EncodedVideoFrame(flags: isKey ? .keyframe : [], captureTimeUs: captureTimeUs, data: annexB)
        frame.view = 1
        output(frame, encodeUs)
    }

    deinit { stop() }
}
