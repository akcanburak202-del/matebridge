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

/// Real-time HEVC (or, with `MATEBRIDGE_CODEC=h264`, H.264; T-086) encoder: no B-frames, keyframes on demand.
/// Output is delivered as Annex-B `EncodedVideoFrame`s; the first output (and any change of
/// parameter sets) is preceded by a CODEC_CONFIG frame.
///
/// Newest frame wins: at most `maxInFlight` frames are inside VideoToolbox and one more "latest" frame waits in
/// `pending` (replaced by newer captures, submitted when a slot frees). The last captured buffer is retained so a
/// keyframe can be produced on a static screen, where ScreenCaptureKit delivers no new frames. The same buffer (or,
/// with `MATEBRIDGE_IDLE_REFRESH_BUFFER=copy`, a copy of it) is re-encoded by the optional idle quality refresh
/// (`MATEBRIDGE_IDLE_REFRESH_MS`, T-086), optionally under a QP cap (`MATEBRIDGE_IDLE_REFRESH_QP`, T-087).
///
/// **Single submit owner (T-162).** Every `VTCompressionSessionEncodeFrame`, the per-frame `MaxAllowedFrameQP` update
/// and the final `CompleteFrames`/`Invalidate` run on one serial owner queue (`EncoderSubmitOrder`), enqueued in slot
/// reservation order. So PTS reach VideoToolbox strictly increasing and no frame is submitted after invalidate. All
/// other threads (ScreenCaptureKit, timers, VideoToolbox's output callback, the coordinator) only take the lock and
/// enqueue; nothing waits on the owner queue with `sync`.
final class HEVCEncoder: @unchecked Sendable {
    typealias Output = @Sendable (EncodedVideoFrame, _ encodeTimeUs: UInt64) -> Void

    /// CMTime ordered with `CMTimeCompare` (the `EncoderSubmitOrder` stamp).
    struct PTS: Comparable, @unchecked Sendable {
        var time: CMTime
        static func < (a: PTS, b: PTS) -> Bool { CMTimeCompare(a.time, b.time) < 0 }
        static func == (a: PTS, b: PTS) -> Bool { CMTimeCompare(a.time, b.time) == 0 }
    }

    struct Input: EncoderSubmitFrame, @unchecked Sendable {
        var buffer: CVPixelBuffer
        var pts: CMTime
        var captureTimeUs: UInt64
        /// SCK callback time on the host clock (T-070).
        var deliveredUs: UInt64
        /// Trace origin: SCK display time (0 = unknown, the trace falls back to `captureTimeUs`).
        var displayTimeUs: UInt64 = 0
        /// Both encoder slots were free when the frame arrived (T-072: splits `hold` into gate and slot wait).
        var slotFreeAtArrival = true
        /// Time spent waiting for a free slot, set when the frame claims its slot (`reserveSlot`).
        var slotWaitUs: UInt64 = 0
        /// An idle quality refresh re-submission (T-087: the refresh QP cap applies to these only).
        var refresh = false

        var stamp: PTS {
            get { PTS(time: pts) }
            set { pts = newValue.time }
        }
        static func stamp(after previous: PTS) -> PTS { PTS(time: previous.time + CMTime(value: 1, timescale: 1000)) }
        var gateUs: UInt64 { captureTimeUs }
        mutating func arrived(slotFree: Bool) { slotFreeAtArrival = slotFree }
        /// T-072: a frame that arrived with both slots busy waited for the slot until the last release; the rest of
        /// its hold is gate wait. (Frames that arrived with a free slot never wait for one.)
        mutating func reserved(lastSlotFreeUs: UInt64) {
            slotWaitUs = !slotFreeAtArrival && lastSlotFreeUs > deliveredUs ? lastSlotFreeUs - deliveredUs : 0
        }
    }

    static let maxInFlight = 2
    static let failureLimit = 5
    private static let idleKeyframeNs: UInt64 = 1_000_000_000
    private static let log = Logger(subsystem: "dev.matebridge.host", category: "encoder")

    private let output: Output
    private let onFailure: @Sendable (Error) -> Void
    /// Submission order, slots, keyframe flag, pacer and teardown (T-162). Its lock is taken before `lock`, never
    /// after: `build` closures passed to `order.offer` may take `lock`; nothing calls `order` while holding `lock`.
    private var order: EncoderSubmitOrder<Backend>!
    private let session: VTCompressionSession
    private let lock = NSLock()
    // All mutable state below is guarded by `lock`.
    private var lastParameterSets: [UInt8] = []
    private var consecutiveFailures = 0
    private var idleTimer: DispatchSourceTimer?
    private var refreshTimer: DispatchSourceTimer?
    private var idleRefresh: IdleRefreshPolicy
    /// `captureTimeUs - deliveredUs` of the newest real capture (SCK stamps run ahead of delivery, ~+6.6 ms) and the
    /// newest stamp offered; re-submissions are stamped `now + lead` (T-086, see `resubmitLast`).
    private var captureLeadUs: Int64 = 0
    private var lastStampUs: UInt64?
    /// Refresh-frame QP cap (T-087); nil unless `MATEBRIDGE_IDLE_REFRESH_QP` is set. Owner queue only: decided and
    /// applied in the same submit block as the frame it belongs to (`send`), so needs no lock.
    private var qpBoost: RefreshQPBoost?
    /// `qpBoost != nil`, fixed at creation (read without the lock).
    private let qpBoostEnabled: Bool
    /// Pool for `MATEBRIDGE_IDLE_REFRESH_BUFFER=copy` (T-087). Used only on the refresh timer queue.
    private var refreshPool: CVPixelBufferPool?
    /// The first input retag was logged (T-113). Guarded by `lock`.
    private var retagLogged = false

    let settings: VideoSettings
    /// Encoder configuration in use (for diagnostics).
    let profile: EncoderProfile
    /// Encoder-level experiment knobs (T-086).
    let knobs: EncoderKnobs
    /// `kVTCompressionPropertyKey_Quality` was accepted (then `AverageBitRate` is not set).
    private(set) var qualityApplied = false
    private let logSink: LogSink
    private let meter: CadenceMeter?
    /// `VTSessionSetProperty` failures at creation (key: OSStatus), for diagnostics.
    private(set) var propertyFailures: [String] = []
    /// Every property the encoder tried to set: "Name=ok" or "Name=<OSStatus>" (T-017: was it applied?).
    private(set) var propertyReport: [String] = []

    /// `(level, event, fields)`; defaults to the host log (`host.log`, component `encoder`).
    typealias LogSink = @Sendable (LogLevel, String, String) -> Void
    static let hostLog: LogSink = { level, event, fields in
        HostLog.log(level, component: "encoder", event: event, fields: fields)
    }

    /// - Parameters:
    ///   - knobs: encoder experiment knobs; nil reads them from the process environment (`EncoderKnobs.parse`).
    ///   - logSink: where `ev=encoder_config` / `ev=idle_refresh` go (the benches print them instead).
    init(settings: VideoSettings, meter: CadenceMeter? = nil, knobs: EncoderKnobs? = nil,
         logSink: @escaping LogSink = HEVCEncoder.hostLog, output: @escaping Output,
         onFailure: @escaping @Sendable (Error) -> Void = { _ in }) throws {
        self.settings = settings
        self.meter = meter
        self.output = output
        self.onFailure = onFailure
        self.logSink = logSink
        let knobs = knobs ?? EncoderKnobs.parse(ProcessInfo.processInfo.environment)
        self.knobs = knobs
        self.idleRefresh = IdleRefreshPolicy(config: knobs.idleRefresh, fps: settings.fps)
        if knobs.idleRefresh.isEnabled, !knobs.idleRefresh.keyframe, let qp = knobs.idleRefresh.maxQP {
            self.qpBoost = RefreshQPBoost(maxQP: qp)
        }
        self.qpBoostEnabled = qpBoost != nil

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
            codecType: Self.codecType(settings.codec), encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { throw VideoEncoderError.sessionCreation(status) }
        session = s
        let backend = Backend(session: s)
        order = EncoderSubmitOrder(
            backend: backend, streamFps: settings.fps, maxInFlight: HEVCEncoder.maxInFlight,
            nowUs: { HostClock.nowUs() },
            pacerCounts: { [meter] overwritten, decimated, deferred in
                for _ in 0..<overwritten { meter?.recordOverwritten() }
                for _ in 0..<decimated { meter?.recordDecimated() }
                for _ in 0..<deferred { meter?.recordDeferred() }
            },
            log: logSink)
        backend.encoder = self

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
        set("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel,
            Self.profileLevel(settings.codec, h264: knobs.h264Profile))
        set("ExpectedFrameRate", kVTCompressionPropertyKey_ExpectedFrameRate, settings.fps as CFNumber)
        if let delay = settings.maxFrameDelayCount {
            set("MaxFrameDelayCount", kVTCompressionPropertyKey_MaxFrameDelayCount, delay as CFNumber)
        }
        // T-086: a constant-quality target replaces the average bitrate; if VideoToolbox refuses it, fall back.
        var qualityOK = false
        if let q = knobs.quality {
            let st = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_Quality, value: q as CFNumber)
            report.append("Quality=\(st == noErr ? "ok" : String(st))")
            qualityOK = st == noErr
            if !qualityOK {
                failures.append("Quality=\(st)")
                logSink(.warning, "quality_rejected", "status=\(st) fallback=bitrate")
            }
        }
        qualityApplied = qualityOK
        if !qualityOK {
            set("AverageBitRate", kVTCompressionPropertyKey_AverageBitRate, (settings.bitrateKbps * 1000) as CFNumber)
        }
        // Cap bursts (bytes per second) at 2x the average (also with Quality: the cap is the safety net).
        set("DataRateLimits", kVTCompressionPropertyKey_DataRateLimits,
            [settings.bitrateKbps * 1000 / 8 * 2, 1] as CFArray)
        // Keyframes are requested on demand (TCP is reliable); the periodic one is only a long safety net (T-075).
        set("MaxKeyFrameIntervalDuration", kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            HEVCEncoder.keyframeIntervalSeconds as CFNumber)
        set("PrioritizeEncodingSpeedOverQuality", kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            knobs.prioritizeSpeed ? kCFBooleanTrue : kCFBooleanFalse)
        // Colour tags consistent with STREAM_CONFIG (sRGB / BT.709, full range). Captured buffers are retagged to
        // these before encoding (T-113, `retagForSession`).
        set("ColorPrimaries", kVTCompressionPropertyKey_ColorPrimaries, Self.sessionPrimaries)
        set("TransferFunction", kVTCompressionPropertyKey_TransferFunction, Self.sessionTransfer)
        set("YCbCrMatrix", kVTCompressionPropertyKey_YCbCrMatrix, Self.sessionMatrix)
        propertyFailures = failures
        propertyReport = report
        VTCompressionSessionPrepareToEncodeFrames(s)

        // Idle keyframe: a pending keyframe request with no new frames for ~1 s re-encodes the last buffer.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "matebridge.encoder.idle"))
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.idleTick() }
        idleTimer = timer
        timer.resume()

        // Idle quality refresh (T-086, off by default): polled once per frame interval.
        if knobs.idleRefresh.isEnabled {
            let refresh = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "matebridge.encoder.refresh"))
            let every = DispatchTimeInterval.microseconds(Int(max(1_000, idleRefresh.intervalUs)))
            refresh.schedule(deadline: .now() + every, repeating: every, leeway: .microseconds(500))
            refresh.setEventHandler { [weak self] in self?.idleRefreshTick() }
            refreshTimer = refresh
            refresh.resume()
        }

        logSink(.info, "encoder_config",
                "codec=\(settings.codec.logName) encoder_profile=\(profile.rawValue) "
                + "bitrate_kbps=\(settings.bitrateKbps) source=\(settings.bitrateSource) "
                + "\(knobs.logFields) quality_applied=\(qualityApplied ? 1 : 0)")
        if qpBoostEnabled, profile == .fast {
            // T-087 bench: the fast profile (no low-latency rate control) accepts a mid-stream MaxAllowedFrameQP
            // and ignores it, so the refresh frames stay all-skip in a settled session.
            logSink(.warning, "idle_refresh_qp", "effective=0 reason=fast_profile_ignores_midstream_qp")
        }
    }

    static func codecType(_ codec: Codec) -> CMVideoCodecType {
        codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
    }

    static func profileLevel(_ codec: Codec, h264: H264Profile) -> CFString {
        guard codec == .h264 else { return kVTProfileLevel_HEVC_Main_AutoLevel }
        switch h264 {
        case .high: return kVTProfileLevel_H264_High_AutoLevel
        case .main: return kVTProfileLevel_H264_Main_AutoLevel
        case .cbp: return kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        case .high52: return kVTProfileLevel_H264_High_5_2
        }
    }

    // Session colour properties (T-113: one source for the session and the input retag).
    static var sessionPrimaries: CFString { kCVImageBufferColorPrimaries_ITU_R_709_2 }
    static var sessionTransfer: CFString { kCVImageBufferTransferFunction_sRGB }
    static var sessionMatrix: CFString { kCVImageBufferYCbCrMatrix_ITU_R_709_2 }
    static let sessionColorTags = ColorTags(primaries: sessionPrimaries as String, transfer: sessionTransfer as String,
                                            matrix: sessionMatrix as String)

    /// T-113: VideoToolbox colour-converts every input whose colour tags differ from the session's (~2.4 ms per
    /// 2800x1840 frame on the M6, and a gamma shift). ScreenCaptureKit tags its sRGB 4:2:0 buffers with BT.709
    /// transfer, so they are retagged to the session's tags here (see `InputRetag`). The pixels are not touched.
    /// Returns the tags that were replaced, nil when the buffer already matched (or carries no colour information).
    static func retagForSession(_ buffer: CVPixelBuffer) -> ColorTags? {
        func tag(_ key: CFString) -> String? { CVBufferCopyAttachment(buffer, key, nil) as? String }
        let current = ColorTags(primaries: tag(kCVImageBufferColorPrimariesKey),
                                transfer: tag(kCVImageBufferTransferFunctionKey),
                                matrix: tag(kCVImageBufferYCbCrMatrixKey))
        let hasColorSpace = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil) != nil
        guard InputRetag.needsRetag(buffer: current, hasColorSpace: hasColorSpace, session: sessionColorTags) else {
            return nil
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, sessionPrimaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, sessionTransfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, sessionMatrix, .shouldPropagate)
        return current
    }

    /// Profile name for the `ev=encoder_config` line logged with the parameter sets.
    private var profileLogName: String { settings.codec == .h264 ? knobs.h264Profile.rawValue : "main" }

    /// Effective periodic keyframe interval in seconds (0 = on request only).
    static let keyframeIntervalSeconds = KeyframeIntervalPolicy.fromEnvironment()

    /// Read-back of the cadence-related properties as the session reports them (not just what we asked for).
    func cadenceReadback() -> String {
        guard !order.isStopped else { return "session closed" }
        let s = session
        func read(_ key: CFString) -> String {
            var raw: UnsafeMutableRawPointer?
            let st = VTSessionCopyProperty(s, key: key, allocator: nil, valueOut: &raw)
            guard st == noErr, let raw else { return "unset(\(st))" }
            return "\(Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue())"
        }
        return "RealTime=\(read(kVTCompressionPropertyKey_RealTime)) "
            + "ExpectedFrameRate=\(read(kVTCompressionPropertyKey_ExpectedFrameRate)) "
            + "MaxKeyFrameIntervalDuration=\(read(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration)) "
            + "MaxFrameDelayCount=\(read(kVTCompressionPropertyKey_MaxFrameDelayCount)) "
            + "Hardware=\(read(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder))"
    }

    /// Colour properties as the session reports them, for the dump tool.
    func colorReadback() -> String {
        guard !order.isStopped else { return "session closed" }
        let s = session
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
        order.requestKeyframe()
        if resubmitNow { resubmitLast() }
    }

    /// Encodes one captured frame (full-range 4:2:0, see `ScreenCapture`). Never blocks and never grows a queue:
    /// if the encoder is backed up the frame replaces the single pending one.
    func encode(_ buffer: CVPixelBuffer, presentationTime: CMTime, captureTimeUs: UInt64,
                displayTimeUs: UInt64 = 0) {
        meter?.recordEncoderIn()
        // T-113: before the buffer reaches VideoToolbox (and before it becomes `last`, which re-submissions reuse).
        if knobs.retagInput, let replaced = Self.retagForSession(buffer) { noteRetag(replaced) }
        let input = Input(buffer: buffer, pts: presentationTime, captureTimeUs: captureTimeUs,
                          deliveredUs: HostClock.nowUs(), displayTimeUs: displayTimeUs)
        order.offer(bypassGate: false) { _ in
            lock.lock()
            idleRefresh.captured(nowUs: input.deliveredUs)
            captureLeadUs = ResubmitStamp.lead(captureUs: input.captureTimeUs, deliveredUs: input.deliveredUs)
            lastStampUs = max(lastStampUs ?? 0, input.captureTimeUs)
            lock.unlock()
            return input
        }
    }

    /// Logs the first retag of this encoder (one line per session: which tags the capture carried).
    private func noteRetag(_ replaced: ColorTags) {
        lock.lock()
        let first = !retagLogged
        retagLogged = true
        lock.unlock()
        if first {
            logSink(.info, "input_retag", "from=\(replaced.logValue) to=\(Self.sessionColorTags.logValue)")
        }
    }

    /// Re-encodes the last captured buffer (keyframe on a static screen, idle refresh). Reading `last` and offering
    /// it happen under one lock, so a newer capture can never be replaced in `last` by an older buffer.
    /// The stamp keeps the real captures' capture-to-delivery lead (T-086): the tablet pacer judges lateness as
    /// `ready - capture_time`, and a re-submission stamped plain "now" would look one lead (~6.6 ms) late.
    ///
    /// `refresh`: an idle quality refresh (T-087). With `MATEBRIDGE_IDLE_REFRESH_BUFFER=copy` its content is copied
    /// into a fresh buffer first (outside the lock); if a newer capture replaced `last` meanwhile, the stale copy is
    /// dropped (that capture re-armed the refresh policy anyway).
    private func resubmitLast(refresh: Bool = false) {
        var copy: CVPixelBuffer?
        var copiedFrom: CVPixelBuffer?
        if refresh, knobs.idleRefresh.buffer == .copy {
            guard let source = order.lastOffered?.buffer else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            copy = copyForRefresh(source)
            let us = (DispatchTime.now().uptimeNanoseconds - start) / 1000
            logSink(.debug, "idle_refresh_copy", "us=\(us) ok=\(copy != nil ? 1 : 0)")
            copiedFrom = source
        }
        order.offer(bypassGate: true) { last in
            guard let l = last else { return nil }
            if let copiedFrom, l.buffer !== copiedFrom { return nil }
            let nowUs = HostClock.nowUs()
            lock.lock()
            let stamp = ResubmitStamp.stamp(nowUs: nowUs, leadUs: captureLeadUs, lastStampUs: lastStampUs)
            lastStampUs = max(lastStampUs ?? 0, stamp)
            lock.unlock()
            var input = Input(buffer: copy ?? l.buffer, pts: CMTime(value: CMTimeValue(stamp), timescale: 1_000_000),
                              captureTimeUs: stamp, deliveredUs: nowUs)
            input.refresh = refresh
            return input
        }
    }

    /// Copies a captured frame into a new IOSurface-backed buffer of the same size and format, with its attachments
    /// (colour tags). Refresh timer queue only (owns `refreshPool`). nil if the copy cannot be made.
    private func copyForRefresh(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        if let pool = refreshPool, let attrs = CVPixelBufferPoolGetPixelBufferAttributes(pool) as? [CFString: Any],
           attrs[kCVPixelBufferWidthKey] as? Int != width || attrs[kCVPixelBufferHeightKey] as? Int != height
            || (attrs[kCVPixelBufferPixelFormatTypeKey] as? NSNumber)?.uint32Value != format {
            refreshPool = nil
        }
        if refreshPool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            refreshPool = pool
        }
        guard let pool = refreshPool else { return nil }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let copy = made else {
            return nil
        }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let planes = CVPixelBufferGetPlaneCount(source)
        guard planes == CVPixelBufferGetPlaneCount(copy), planes > 0 else { return nil }
        for p in 0..<planes {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, p),
                  let to = CVPixelBufferGetBaseAddressOfPlane(copy, p) else { return nil }
            let fromStride = CVPixelBufferGetBytesPerRowOfPlane(source, p)
            let toStride = CVPixelBufferGetBytesPerRowOfPlane(copy, p)
            let rows = min(CVPixelBufferGetHeightOfPlane(source, p), CVPixelBufferGetHeightOfPlane(copy, p))
            if fromStride == toStride {
                memcpy(to, from, fromStride * rows)
            } else {
                let n = min(fromStride, toStride)
                for r in 0..<rows { memcpy(to + r * toStride, from + r * fromStride, n) }
            }
        }
        CVBufferPropagateAttachments(source, copy)
        return copy
    }

    /// `MaxAllowedFrameQP` as the session reports it (diagnostics).
    private static func readMaxQP(_ session: VTCompressionSession) -> String {
        var raw: UnsafeMutableRawPointer?
        let st = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, allocator: nil,
                                       valueOut: &raw)
        guard st == noErr, let raw else { return "unset(\(st))" }
        return "\(Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue())"
    }

    /// T-087: sets or lifts the refresh-frame QP cap before a frame is submitted (only when the knob is set). Owner
    /// queue only, in the submit block of the frame it applies to (T-162).
    private func updateQPBoost(refresh: Bool, session: VTCompressionSession) {
        guard var boost = qpBoost, let change = boost.before(refresh: refresh) else { return }
        switch change {
        case .apply(let qp):
            let st = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
                                          value: qp as CFNumber)
            if st != noErr {
                boost.applyFailed()
                logSink(.warning, "idle_refresh_qp", "effective=0 status=\(st)")
            }
            logSink(.debug, "idle_refresh_qp", "change=apply qp=\(qp) status=\(st) readback=\(Self.readMaxQP(session))")
        case .restore:
            // No cap is set at creation and VideoToolbox refuses NULL here, so "lifted" is the codec maximum
            // (measured T-087: a cap of 51 behaves exactly like no cap).
            let st = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
                                          value: IdleRefreshConfig.maxQPRange.upperBound as CFNumber)
            if st != noErr { logSink(.warning, "idle_refresh_qp", "restore_failed status=\(st)") }
            logSink(.debug, "idle_refresh_qp", "change=restore status=\(st) readback=\(Self.readMaxQP(session))")
        }
        qpBoost = boost
    }

    /// Idle quality refresh (T-086): re-encodes the last captured buffer once the screen has been static for the
    /// configured delay, so the tablet does not keep the last (motion-time) frame.
    private func idleRefreshTick() {
        guard order.lastOffered != nil else { return }
        lock.lock()
        let action = idleRefresh.tick(nowUs: HostClock.nowUs())
        lock.unlock()
        switch action {
        case .none:
            return
        case .resubmit(let first):
            if first { logSink(.info, "idle_refresh", "frames=\(knobs.idleRefresh.count)") }
            resubmitLast(refresh: true)
        case .keyframe:
            logSink(.info, "idle_refresh", "frames=1 mode=key")
            requestKeyframe(resubmitNow: true)
        }
    }

    private func idleTick() {
        if order.keyframeDue(idleUs: HEVCEncoder.idleKeyframeNs / 1000) { resubmitLast() }
    }

    /// Target send rate `min(stream fps, panel Hz)` (T-058). Only the frame gate changes: the session, the virtual
    /// display and capture keep running and already encoded frames are never dropped.
    func setTargetFps(_ fps: Int) {
        order.setTargetFps(fps)
    }

    /// `CompressionBackend` over the VideoToolbox session; called on the owner queue only. Holds the encoder weakly
    /// (the encoder owns the order, which owns this backend), so the teardown block never retains the encoder.
    final class Backend: CompressionBackend, @unchecked Sendable {
        let session: VTCompressionSession
        weak var encoder: HEVCEncoder?
        init(session: VTCompressionSession) { self.session = session }

        /// After the encoder is gone (its `deinit` already stopped the order) a queued frame is not submitted.
        func encode(_ frame: Input, keyframe: Bool, token: EncoderSubmitToken) {
            encoder?.send(frame, key: keyframe, token: token, session: session)
        }

        /// Synchronous `CompleteFrames` runs here, on the owner queue, never on a Swift cooperative thread.
        func completeAndInvalidate() {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    /// Owner queue only (`Backend.encode`).
    private func send(_ frame: Input, key: Bool, token: EncoderSubmitToken, session: VTCompressionSession) {
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let start = DispatchTime.now().uptimeNanoseconds
        let captureTimeUs = frame.captureTimeUs
        var trace = FrameTrace()
        // Origin: the earliest of the SCK stamps and the callback (T-072), so the totals can never be shorter than
        // the stages; the raw stamps travel along and are logged as signed offsets.
        trace.ptsUs = captureTimeUs
        trace.displayUs = frame.displayTimeUs
        trace.deliveredUs = frame.deliveredUs
        trace.captureUs = FrameTrace.origin(displayUs: frame.displayTimeUs, ptsUs: captureTimeUs,
                                            deliveredUs: frame.deliveredUs)
        trace.slotWaitUs = frame.slotWaitUs
        if qpBoostEnabled { updateQPBoost(refresh: frame.refresh, session: session) }
        trace.submittedUs = HostClock.nowUs()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: frame.buffer, presentationTimeStamp: frame.pts,
            duration: .invalid, frameProperties: props, infoFlagsOut: nil
        ) { [weak self, trace] status, _, sampleBuffer in
            guard let self else { return }
            let elapsedUs = (DispatchTime.now().uptimeNanoseconds - start) / 1000
            var t = trace
            t.encodedUs = HostClock.nowUs()
            self.completed(status: status, sampleBuffer: sampleBuffer, token: token, captureTimeUs: captureTimeUs,
                           encodeTimeUs: elapsedUs, trace: t)
        }
        if status != noErr {
            HEVCEncoder.log.error("ev=encode_failed status=\(status)")
            slotFailed(token, VideoEncoderError.encode(status))
        }
    }

    /// A submitted frame produced output (or none); frees the slot and starts the pending frame, if any.
    private func completed(status: OSStatus, sampleBuffer: CMSampleBuffer?, token: EncoderSubmitToken,
                           captureTimeUs: UInt64, encodeTimeUs: UInt64, trace: FrameTrace) {
        let ok = status == noErr && sampleBuffer != nil
        if let sb = sampleBuffer, ok {
            meter?.recordEncoderOut(encodeTimeUs: encodeTimeUs)
            handle(sb, captureTimeUs: captureTimeUs, encodeTimeUs: encodeTimeUs, trace: trace)
        }
        if ok { lock.lock(); consecutiveFailures = 0; lock.unlock() }
        if !ok {
            // A frame the encoder dropped or failed breaks the reference chain: recover with a keyframe.
            HEVCEncoder.log.error("ev=encode_no_output status=\(status)")
            slotFailed(token, VideoEncoderError.encode(status))
        } else {
            order.release(token, failed: false)
        }
    }

    private func slotFailed(_ token: EncoderSubmitToken, _ error: Error) {
        lock.lock()
        consecutiveFailures += 1
        let trip = consecutiveFailures == HEVCEncoder.failureLimit
        lock.unlock()
        // For a failed EncodeFrame call the slot was never consumed by a callback; for no-output the callback is
        // the release point. Release is idempotent per token (T-162): should VideoToolbox report both for one frame,
        // the second release is logged and ignored.
        order.release(token, failed: true)
        if trip { onFailure(VideoEncoderError.repeatedFailures(HEVCEncoder.failureLimit)) }
    }

    /// Flushes the frames already inside the encoder and tears the session down, then returns. For synchronous
    /// callers (benches): it blocks until the owner queue has run the teardown. Idempotent. From Swift concurrency use
    /// `shutdown()`, which does not block a cooperative thread.
    func stop() {
        let done = DispatchSemaphore(value: 0)
        beginStop { done.signal() }
        // On the owner queue the teardown block is queued behind the caller: waiting would deadlock.
        if order?.isOnOwnerQueue == false { done.wait() }
    }

    /// `stop()` for async callers: resumes once the owner queue has completed and invalidated the session.
    func shutdown() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            beginStop { c.resume() }
        }
    }

    /// Cancels the timers and enqueues the teardown on the owner queue (never waits). `completion` runs on the owner
    /// queue after `CompleteFrames`/`Invalidate`.
    private func beginStop(completion: (@Sendable () -> Void)?) {
        lock.lock()
        idleRefresh.reset()
        let timer = idleTimer
        idleTimer = nil
        let refresh = refreshTimer
        refreshTimer = nil
        lock.unlock()
        timer?.cancel()
        refresh?.cancel()
        // `order` is nil only if `init` threw before creating it (then there is no session to close).
        if let order { order.stop(completion: completion) } else { completion?() }
    }

    /// Only enqueues the teardown: no wait, and the teardown block captures the backend, never `self`.
    deinit { beginStop(completion: nil) }

    private func handle(_ sb: CMSampleBuffer, captureTimeUs: UInt64, encodeTimeUs: UInt64, trace: FrameTrace) {
        guard let format = CMSampleBufferGetFormatDescription(sb) else { return }
        let isKey: Bool = {
            guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
                  let first = arr.first else { return true }
            return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        }()

        // Parameter sets are re-announced only when they change (first frame included).
        let (sets, lengthSize) = Self.parameterSets(format, codec: settings.codec)
        let blob = AnnexB.parameterSets(sets)
        lock.lock()
        let changed = !blob.isEmpty && blob != lastParameterSets
        if changed { lastParameterSets = blob }
        lock.unlock()
        if changed {
            let level = Self.levelIdc(sets, codec: settings.codec).map { String($0) } ?? "unknown"
            logSink(.info, "encoder_config", "codec=\(settings.codec.logName) profile=\(profileLogName) "
                    + "level_idc=\(level) sets=\(sets.count)")
            output(EncodedVideoFrame(flags: .codecConfig, captureTimeUs: 0, data: blob), 0)
        }

        guard let block = CMSampleBufferGetDataBuffer(sb), let raw = Self.bytes(of: block) else { return }
        guard let annexB = AnnexB.convert(lengthPrefixed: raw, lengthSize: lengthSize) else { return }
        var frame = EncodedVideoFrame(flags: isKey ? .keyframe : [], captureTimeUs: captureTimeUs, data: annexB)
        frame.trace = trace
        output(frame, encodeTimeUs)
    }

    /// All bytes of a block buffer. The data pointer is valid for `lengthAtOffset` bytes only: a block buffer made of
    /// several segments (`lengthAtOffset != totalLength`) is copied with `CMBlockBufferCopyDataBytes` (T-162).
    static func bytes(of block: CMBlockBuffer) -> [UInt8]? {
        var lengthAtOffset = 0
        var total = 0
        var base: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &total, dataPointerOut: &base) == kCMBlockBufferNoErr
        else { return nil }
        if total == 0 { return [] }
        if lengthAtOffset == total, let base {
            return Array(UnsafeBufferPointer(start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                                             count: total))
        }
        var bytes = [UInt8](repeating: 0, count: total)
        let st = bytes.withUnsafeMutableBytes { dst in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: dst.baseAddress!)
        }
        return st == kCMBlockBufferNoErr ? bytes : nil
    }

    /// Parameter sets (HEVC: VPS, SPS, PPS; H.264: SPS, PPS) without start codes, and the NAL length size.
    static func parameterSets(_ format: CMFormatDescription, codec: Codec) -> ([[UInt8]], Int) {
        func get(_ i: Int, _ ptr: UnsafeMutablePointer<UnsafePointer<UInt8>?>?, _ size: UnsafeMutablePointer<Int>?,
                 _ count: UnsafeMutablePointer<Int>?, _ length: UnsafeMutablePointer<Int32>?) -> OSStatus {
            codec == .h264
                ? CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: ptr, parameterSetSizeOut: size,
                    parameterSetCountOut: count, nalUnitHeaderLengthOut: length)
                : CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: ptr, parameterSetSizeOut: size,
                    parameterSetCountOut: count, nalUnitHeaderLengthOut: length)
        }
        var count = 0
        var lengthSize: Int32 = 4
        _ = get(0, nil, nil, &count, &lengthSize)
        var sets: [[UInt8]] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            if get(i, &ptr, &size, nil, nil) == noErr, let ptr {
                sets.append(Array(UnsafeBufferPointer(start: ptr, count: size)))
            }
        }
        return (sets, Int(lengthSize))
    }

    /// Level from the SPS (H.264 level_idc, HEVC general_level_idc), for the log.
    static func levelIdc(_ sets: [[UInt8]], codec: Codec) -> UInt8? {
        for nal in sets {
            if codec == .h264, let l = H264SPS.levelIdc(nal) { return l }
            if codec == .hevc, let l = HEVCSPS.generalLevelIdc(sps: nal) { return l }
        }
        return nil
    }

    /// CODEC_CONFIG for a newly attached consumer (nil before the first frame was encoded).
    func currentCodecConfig() -> EncodedVideoFrame? {
        lock.lock(); defer { lock.unlock() }
        return lastParameterSets.isEmpty ? nil
            : EncodedVideoFrame(flags: .codecConfig, captureTimeUs: 0, data: lastParameterSets)
    }
}
