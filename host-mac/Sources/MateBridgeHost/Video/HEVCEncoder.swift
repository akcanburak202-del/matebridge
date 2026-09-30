import CoreMedia
import CoreVideo
import Foundation
import MateBridgeCore
import os
import VideoToolbox

public enum VideoEncoderError: Error, CustomStringConvertible {
    case sessionCreation(OSStatus)
    case encode(OSStatus)
    case repeatedFailures(Int)

    public var description: String {
        switch self {
        case .sessionCreation(let s): return "VTCompressionSessionCreate failed (\(s))"
        case .encode(let s): return "VTCompressionSessionEncodeFrame failed (\(s))"
        case .repeatedFailures(let n): return "encoder failed \(n) times in a row"
        }
    }
}

/// Real-time HEVC encoder: low-latency rate control, no B-frames, keyframes on demand.
/// Output is delivered as Annex-B `EncodedVideoFrame`s; the first output (and any change of
/// parameter sets) is preceded by a CODEC_CONFIG frame.
///
/// Newest frame wins: at most `maxInFlight` frames are inside VideoToolbox and one more "latest" frame waits in
/// `pending` (replaced by newer captures, submitted when a slot frees). The last captured buffer is retained so a
/// keyframe can be produced on a static screen, where ScreenCaptureKit delivers no new frames.
final class HEVCEncoder: @unchecked Sendable {
    typealias Output = @Sendable (EncodedVideoFrame, _ encodeTimeUs: UInt64) -> Void

    private struct Input: @unchecked Sendable {
        var buffer: CVPixelBuffer
        var pts: CMTime
        var captureTimeUs: UInt64
    }

    static let maxInFlight = 2
    static let failureLimit = 5
    private static let idleKeyframeNs: UInt64 = 1_000_000_000
    private static let log = Logger(subsystem: "dev.matebridge.host", category: "encoder")

    private let output: Output
    private let onFailure: @Sendable (Error) -> Void
    private let lock = NSLock()
    // All mutable state below is guarded by `lock`.
    private var session: VTCompressionSession?
    private var stopped = false
    private var forceKeyframe = true          // the very first frame is a keyframe
    private var lastParameterSets: [UInt8] = []
    private var inFlight = 0
    private var last: Input?
    private var lastPTS = CMTime.invalid
    private var lastSubmitNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var consecutiveFailures = 0
    private var idleTimer: DispatchSourceTimer?
    private var pacer: FramePacer<Input>
    private var flushScheduled = false

    let settings: VideoSettings
    /// Encoder configuration in use (for diagnostics).
    let profile: EncoderProfile
    private let meter: CadenceMeter?
    /// `VTSessionSetProperty` failures at creation (key: OSStatus), for diagnostics.
    private(set) var propertyFailures: [String] = []
    /// Every property the encoder tried to set: "Name=ok" or "Name=<OSStatus>" (T-017: was it applied?).
    private(set) var propertyReport: [String] = []

    init(settings: VideoSettings, meter: CadenceMeter? = nil, output: @escaping Output,
         onFailure: @escaping @Sendable (Error) -> Void = { _ in }) throws {
        self.settings = settings
        self.meter = meter
        self.pacer = FramePacer<Input>(streamFps: settings.fps)
        self.output = output
        self.onFailure = onFailure

        // T-047/T-053 bench: at 2800x1840 the low-latency rate control + RealTime path costs ~9-13 ms per frame and
        // tops out near 100 fps; without both the hardware encoder needs ~6 ms. Frame sizes stay even enough (p99 <=
        // 4x mean on moving content), so `.fast` is the default at every fps; MATEBRIDGE_ENCODER=llrc|fast overrides.
        let profile = EncoderProfile.resolve(
            fps: settings.fps, override: EncoderProfile.parse(ProcessInfo.processInfo.environment["MATEBRIDGE_ENCODER"]),
            defaultProfile: .fast)
        self.profile = profile
        let highRate = profile == .fast
        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        if !highRate { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(settings.encodedWidthPx), height: Int32(settings.encodedHeightPx),
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { throw VideoEncoderError.sessionCreation(status) }
        session = s

        var failures: [String] = []
        var report: [String] = []
        func set(_ name: String, _ key: CFString, _ value: CFTypeRef) {
            let st = VTSessionSetProperty(s, key: key, value: value)
            report.append("\(name)=\(st == noErr ? "ok" : String(st))")
            if st != noErr {
                failures.append("\(name)=\(st)")
                HEVCEncoder.log.error("ev=prop_set_failed key=\(name, privacy: .public) status=\(st)")
            }
        }
        set("RealTime", kVTCompressionPropertyKey_RealTime, highRate ? kCFBooleanFalse : kCFBooleanTrue)
        set("AllowFrameReordering", kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set("ExpectedFrameRate", kVTCompressionPropertyKey_ExpectedFrameRate, settings.fps as CFNumber)
        if let delay = settings.maxFrameDelayCount {
            set("MaxFrameDelayCount", kVTCompressionPropertyKey_MaxFrameDelayCount, delay as CFNumber)
        }
        set("AverageBitRate", kVTCompressionPropertyKey_AverageBitRate, (settings.bitrateKbps * 1000) as CFNumber)
        // Cap bursts (bytes per second) at 2x the average.
        set("DataRateLimits", kVTCompressionPropertyKey_DataRateLimits,
            [settings.bitrateKbps * 1000 / 8 * 2, 1] as CFArray)
        // Keyframes are requested on demand; a periodic one bounds recovery time anyway.
        set("MaxKeyFrameIntervalDuration", kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10 as CFNumber)
        set("PrioritizeEncodingSpeedOverQuality", kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            kCFBooleanTrue)
        // Colour tags consistent with STREAM_CONFIG (sRGB / BT.709, full range).
        set("ColorPrimaries", kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set("TransferFunction", kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
        set("YCbCrMatrix", kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        propertyFailures = failures
        propertyReport = report
        VTCompressionSessionPrepareToEncodeFrames(s)

        // Idle keyframe: a pending keyframe request with no new frames for ~1 s re-encodes the last buffer.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "matebridge.encoder.idle"))
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.idleTick() }
        idleTimer = timer
        timer.resume()
    }

    /// Read-back of the cadence-related properties as the session reports them (not just what we asked for).
    func cadenceReadback() -> String {
        lock.lock(); let s = session; lock.unlock()
        guard let s else { return "session closed" }
        func read(_ key: CFString) -> String {
            var raw: UnsafeMutableRawPointer?
            let st = VTSessionCopyProperty(s, key: key, allocator: nil, valueOut: &raw)
            guard st == noErr, let raw else { return "unset(\(st))" }
            return "\(Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue())"
        }
        return "RealTime=\(read(kVTCompressionPropertyKey_RealTime)) "
            + "ExpectedFrameRate=\(read(kVTCompressionPropertyKey_ExpectedFrameRate)) "
            + "MaxFrameDelayCount=\(read(kVTCompressionPropertyKey_MaxFrameDelayCount)) "
            + "Hardware=\(read(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder))"
    }

    /// Colour properties as the session reports them, for the dump tool.
    func colorReadback() -> String {
        lock.lock(); let s = session; lock.unlock()
        guard let s else { return "session closed" }
        func read(_ key: CFString) -> String {
            var raw: UnsafeMutableRawPointer?
            let st = VTSessionCopyProperty(s, key: key, allocator: nil, valueOut: &raw)
            guard st == noErr, let raw else { return "unset(\(st))" }
            return "\(Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue())"
        }
        return "primaries=\(read(kVTCompressionPropertyKey_ColorPrimaries)) "
            + "transfer=\(read(kVTCompressionPropertyKey_TransferFunction)) "
            + "matrix=\(read(kVTCompressionPropertyKey_YCbCrMatrix))"
    }

    /// The next encoded frame will be a keyframe. With `resubmitNow`, the last captured buffer is encoded
    /// immediately (needed on a static screen, where no new capture may ever arrive).
    func requestKeyframe(resubmitNow: Bool = false) {
        lock.lock(); forceKeyframe = true; lock.unlock()
        if resubmitNow { resubmitLast() }
    }

    /// Encodes one captured frame (full-range 4:2:0, see `ScreenCapture`). Never blocks and never grows a queue:
    /// if the encoder is backed up the frame replaces the single pending one.
    func encode(_ buffer: CVPixelBuffer, presentationTime: CMTime, captureTimeUs: UInt64) {
        meter?.recordEncoderIn()
        submit(Input(buffer: buffer, pts: presentationTime, captureTimeUs: captureTimeUs))
    }

    private func resubmitLast() {
        lock.lock()
        guard !stopped, let l = last else { lock.unlock(); return }
        lock.unlock()
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        submit(Input(buffer: l.buffer, pts: now, captureTimeUs: UInt64(max(0, CMTimeGetSeconds(now)) * 1_000_000)),
               bypassGate: true)
    }

    private func idleTick() {
        lock.lock()
        let due = !stopped && forceKeyframe && last != nil
            && DispatchTime.now().uptimeNanoseconds - lastSubmitNs >= HEVCEncoder.idleKeyframeNs
        lock.unlock()
        if due { resubmitLast() }
    }

    /// `bypassGate`: keyframe re-submissions must not wait for the send-rate gate.
    private func submit(_ input: Input, bypassGate: Bool = false) {
        lock.lock()
        guard !stopped, let s = session else { lock.unlock(); return }
        last = input
        var toSend: (Input, Bool)?
        var delay: UInt64?
        // The pacer decides: send now, hold as the single pending frame (newest wins), or drop a stale one.
        switch pacer.offer(input, ptsUs: input.captureTimeUs, nowUs: HostClock.nowUs(),
                           slotFree: inFlight < HEVCEncoder.maxInFlight, bypassGate: bypassGate) {
        case .submit(let f): toSend = reserveSlot(f)
        case .hold(let retryAfterUs): if let r = retryAfterUs { delay = scheduleFlushLocked(afterUs: r) }
        case .drop: break
        }
        reportOverwrittenLocked()
        lock.unlock()
        if let delay { armFlush(delay) }
        if let (frame, key) = toSend { send(frame, key: key, session: s) }
    }

    private func reportOverwrittenLocked() {
        let n = pacer.takeOverwritten()
        for _ in 0..<n { meter?.recordOverwritten() }
        let d = pacer.takeDecimated()
        for _ in 0..<d { meter?.recordDecimated() }
    }

    /// Target send rate `min(stream fps, panel Hz)` (T-058). Only the frame gate changes: the session, the virtual
    /// display and capture keep running and already encoded frames are never dropped.
    func setTargetFps(_ fps: Int) {
        lock.lock()
        pacer.setTargetFps(fps)
        lock.unlock()
    }

    /// Must hold `lock`. Claims an in-flight slot, consumes the keyframe flag and makes the PTS increase.
    private func reserveSlot(_ input: Input) -> (Input, Bool) {
        inFlight += 1
        var f = input
        if lastPTS.isValid, f.pts <= lastPTS { f.pts = lastPTS + CMTime(value: 1, timescale: 1000) }
        lastPTS = f.pts
        lastSubmitNs = DispatchTime.now().uptimeNanoseconds
        let key = forceKeyframe
        forceKeyframe = false
        return (f, key)
    }

    private func send(_ frame: Input, key: Bool, session: VTCompressionSession) {
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let start = DispatchTime.now().uptimeNanoseconds
        let captureTimeUs = frame.captureTimeUs
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: frame.buffer, presentationTimeStamp: frame.pts,
            duration: .invalid, frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            let elapsedUs = (DispatchTime.now().uptimeNanoseconds - start) / 1000
            self.completed(status: status, sampleBuffer: sampleBuffer, captureTimeUs: captureTimeUs,
                           encodeTimeUs: elapsedUs)
        }
        if status != noErr {
            HEVCEncoder.log.error("ev=encode_failed status=\(status)")
            slotFailed(VideoEncoderError.encode(status))
        }
    }

    /// A submitted frame produced output (or none); frees the slot and starts the pending frame, if any.
    private func completed(status: OSStatus, sampleBuffer: CMSampleBuffer?, captureTimeUs: UInt64, encodeTimeUs: UInt64) {
        let ok = status == noErr && sampleBuffer != nil
        if let sb = sampleBuffer, ok {
            meter?.recordEncoderOut(encodeTimeUs: encodeTimeUs)
            handle(sb, captureTimeUs: captureTimeUs, encodeTimeUs: encodeTimeUs)
        }
        if ok { lock.lock(); consecutiveFailures = 0; lock.unlock() }
        if !ok {
            // A frame the encoder dropped or failed breaks the reference chain: recover with a keyframe.
            HEVCEncoder.log.error("ev=encode_no_output status=\(status)")
            slotFailed(VideoEncoderError.encode(status))
        } else {
            releaseSlotAndDrain()
        }
    }

    private func slotFailed(_ error: Error) {
        lock.lock()
        forceKeyframe = true
        consecutiveFailures += 1
        let trip = consecutiveFailures == HEVCEncoder.failureLimit
        lock.unlock()
        // For a failed EncodeFrame call the slot was never consumed by a callback; for no-output the callback is
        // the release point. Either way exactly one release per reservation happens here.
        releaseSlotAndDrain()
        if trip { onFailure(VideoEncoderError.repeatedFailures(HEVCEncoder.failureLimit)) }
    }

    private func releaseSlotAndDrain() {
        lock.lock()
        inFlight -= 1
        let (next, delay) = takePendingLocked()
        lock.unlock()
        if let delay { armFlush(delay) }
        if let (f, k, s) = next { send(f, key: k, session: s) }
    }

    /// Must hold `lock`. Claims the pending frame if a slot is free and the gate is open (judged by the current time,
    /// not the frame's capture time); otherwise returns the delay after which a flush should retry.
    private func takePendingLocked() -> ((Input, Bool, VTCompressionSession)?, UInt64?) {
        guard !stopped, let s = session else { return (nil, nil) }
        defer { reportOverwrittenLocked() }
        switch pacer.takePending(nowUs: HostClock.nowUs(), slotFree: inFlight < HEVCEncoder.maxInFlight) {
        case .submit(let f):
            let (frame, key) = reserveSlot(f)
            return ((frame, key, s), nil)
        case .retry(let wait): return (nil, scheduleFlushLocked(afterUs: wait))
        case .none: return (nil, nil)
        }
    }

    /// Must hold `lock`. Returns the delay to arm, or nil if a flush is already scheduled.
    private func scheduleFlushLocked(afterUs: UInt64) -> UInt64? {
        if flushScheduled { return nil }
        flushScheduled = true
        return afterUs
    }

    private func armFlush(_ delayUs: UInt64) {
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .microseconds(Int(delayUs))) { [weak self] in
            self?.flushPending()
        }
    }

    private func flushPending() {
        lock.lock()
        flushScheduled = false
        let (next, delay) = takePendingLocked()
        lock.unlock()
        if let delay { armFlush(delay) }
        if let (f, k, s) = next { send(f, key: k, session: s) }
    }

    /// Flushes pending frames and tears the session down. Idempotent.
    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let s = session
        session = nil
        pacer.clearPending()
        last = nil
        let timer = idleTimer
        idleTimer = nil
        lock.unlock()
        timer?.cancel()
        if let s {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
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
