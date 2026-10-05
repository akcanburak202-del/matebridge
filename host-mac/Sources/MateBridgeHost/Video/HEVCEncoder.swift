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
/// keyframe can be produced on a static screen, where ScreenCaptureKit delivers no new frames (`resubmitLast`). The
/// idle quality refresh that re-encoded it on a timer (T-086/T-087) was retired by T-204 (decision 0026).
///
/// **Single submit owner (T-162).** Every `VTCompressionSessionEncodeFrame`, every live bitrate change (T-177)
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
        /// Any re-submission of the last buffer (synthetic `now + lead` stamp); trace only (T-170).
        var resubmit = false
        /// A frame of the still-screen refinement train (T-253); its output feeds `StillRefinePolicy`.
        var refine = false

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
    /// `MATEBRIDGE_BITRATE_STEP` timer (T-177 device check); nil unless the knob is set.
    private var stepTimer: DispatchSourceTimer?
    private var stepTick = 0
    /// `captureTimeUs - deliveredUs` of the newest real capture (SCK stamps run ahead of delivery, ~+6.6 ms) and the
    /// newest stamp offered; re-submissions are stamped `now + lead` (T-086, see `resubmitLast`).
    private var captureLeadUs: Int64 = 0
    private var lastStampUs: UInt64?
    /// The first input retag was logged (T-113). Guarded by `lock`.
    private var retagLogged = false
    /// T-235 `chroma_stats` window; nil unless `chroma.statsEnabled` (knob set, or the sharp path runs). Guarded by
    /// `lock`.
    private var chromaStats: ChromaStatsWindow?
    /// The first failed Metal pass was logged. Guarded by `lock`.
    private var chromaFailureLogged = false
    /// T-253 still-screen refinement (guarded by `lock`), its 25 ms start timer, and the output queue's "empty"
    /// probe (called outside `lock`: the queue lock is taken before the encoder lock elsewhere).
    private var refinePolicy: StillRefinePolicy
    private var refineTimer: DispatchSourceTimer?
    private let refineReady: @Sendable () -> Bool

    let settings: VideoSettings
    /// Encoder configuration in use (for diagnostics).
    let profile: EncoderProfile
    /// Encoder-level experiment knobs (T-086).
    let knobs: EncoderKnobs
    /// `kVTCompressionPropertyKey_Quality` was accepted (then `AverageBitRate` is not set).
    private(set) var qualityApplied = false
    /// T-235 `MATEBRIDGE_CHROMA` / T-240 `settings.chromaPreference`: requested and applied chroma mode. Final once
    /// `init` returns.
    private(set) var chroma = ChromaDecision(knob: .unset, applied: .yuv420, reason: nil)
    /// The sharp-YUV Metal pass (`chroma.applied` is `sharp_*`); used on the owner queue only. Set in `init` only.
    private var chromaConverter: ChromaConverter?
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
    /// `video ev=bitrate_set` (T-177; `docs/LOGGING.md`).
    static let videoLog: LogSink = { level, event, fields in
        HostLog.log(level, component: "video", event: event, fields: fields)
    }

    /// - Parameters:
    ///   - knobs: encoder experiment knobs; nil reads them from the process environment (`EncoderKnobs.parse`).
    ///   - logSink: where `ev=encoder_config` / `ev=profile` go (the benches print them instead).
    ///   - refine: still-screen refinement (T-253); `.disabled` (default) keeps the encoder exactly as before.
    ///   - refineReady: whether the output queue can take another refinement frame (`VideoFrameQueue.isReadyForRefine`).
    init(settings: VideoSettings, meter: CadenceMeter? = nil, knobs: EncoderKnobs? = nil,
         logSink: @escaping LogSink = HEVCEncoder.hostLog, refine: StillRefineConfig = .disabled,
         refineReady: @escaping @Sendable () -> Bool = { true }, output: @escaping Output,
         onFailure: @escaping @Sendable (Error) -> Void = { _ in }) throws {
        self.settings = settings
        self.refinePolicy = StillRefinePolicy(config: refine)
        self.refineReady = refineReady
        self.meter = meter
        self.output = output
        self.onFailure = onFailure
        self.logSink = logSink
        let env = ProcessInfo.processInfo.environment
        let knobs = knobs ?? EncoderKnobs.parse(env)
        self.knobs = knobs

        // T-047/T-053 bench: at 2800x1840 the low-latency rate control + RealTime path costs ~9-13 ms per frame and
        // tops out near 100 fps; without both the hardware encoder needs ~6 ms. Frame sizes stay even enough (p99 <=
        // 4x mean on moving content), so `.fast` is the default at every fps; MATEBRIDGE_ENCODER=llrc|fast overrides.
        let profile = EncoderProfile.resolve(
            fps: settings.fps, override: EncoderProfile.parse(env["MATEBRIDGE_ENCODER"]),
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
            initialBitrateKbps: settings.bitrateKbps,
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
        @discardableResult
        func set(_ name: String, _ key: CFString, _ value: CFTypeRef) -> OSStatus {
            let st = VTSessionSetProperty(s, key: key, value: value)
            report.append("\(name)=\(st == noErr ? "ok" : String(st))")
            if st != noErr {
                failures.append("\(name)=\(st)")
                HEVCEncoder.log.error("ev=prop_set_failed key=\(name, privacy: .public) status=\(st)")
            }
            return st
        }
        let hdr = settings.dynamicRange == .hdr10
        set("RealTime", kVTCompressionPropertyKey_RealTime, highRate ? kCFBooleanFalse : kCFBooleanTrue)
        set("AllowFrameReordering", kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // T-235: `444` asks for the undocumented HEVC Main 4:4:4 profile (fast path only, `ChromaPolicy`); refused,
        // the session stays Main and capture stays 4:2:0. Every other mode sets exactly what it set before.
        // T-237: HDR10 wins over the chroma knob (`reason=hdr`, applied `420`): Main10, x420 PQ capture.
        // T-240: without the knob the tablet's `STREAM_PREFS.chroma = 1` asks for `sharp_nearest` (decision 0033).
        var chroma = ChromaPolicy.resolve(knob: knobs.chroma, preference: settings.chromaPreference,
                                          codec: settings.codec, profile: profile, dynamicRange: settings.dynamicRange)
        if chroma.applied == .yuv444 {
            if set("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel, Self.main444ProfileLevel) != noErr {
                set("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel, Self.profileLevel(settings.codec))
                chroma = chroma.fallingBack(.profileRejected)
            }
        } else {
            set("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel,
                Self.profileLevel(settings.codec, dynamicRange: settings.dynamicRange))
        }
        set("ExpectedFrameRate", kVTCompressionPropertyKey_ExpectedFrameRate, settings.fps as CFNumber)
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
        // `MATEBRIDGE_RATE_WINDOW_MS` adds a shorter window (T-177 diagnostics).
        set("DataRateLimits", kVTCompressionPropertyKey_DataRateLimits,
            Self.dataRateLimits(kbps: settings.bitrateKbps, shortWindowMs: knobs.rateWindowMs))
        // Keyframes are requested on demand (TCP is reliable); the periodic one is only a long safety net (T-075).
        set("MaxKeyFrameIntervalDuration", kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            HEVCEncoder.keyframeIntervalSeconds as CFNumber)
        // Always on (T-204 retired `MATEBRIDGE_PRIO_SPEED=0`: ~25 ms per frame without it, T-086).
        set("PrioritizeEncodingSpeedOverQuality", kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            kCFBooleanTrue)
        // Colour tags consistent with STREAM_CONFIG (SDR: sRGB / BT.709, full range; HDR10: BT.2020 / PQ / BT.2020,
        // limited range from the x420 input). Captured buffers are retagged to these before encoding (T-113,
        // `retagForSession`).
        let color = Self.sessionColor(settings.dynamicRange)
        set("ColorPrimaries", kVTCompressionPropertyKey_ColorPrimaries, color.primaries)
        set("TransferFunction", kVTCompressionPropertyKey_TransferFunction, color.transfer)
        set("YCbCrMatrix", kVTCompressionPropertyKey_YCbCrMatrix, color.matrix)
        if hdr {
            // Decision 0032: HDR10 static metadata as SEI (MDCV + CLL), inserted by VideoToolbox.
            let md = HDR10Metadata.host
            set("MasteringDisplayColorVolume", kVTCompressionPropertyKey_MasteringDisplayColorVolume,
                Data(md.mdcvSEI) as CFData)
            set("ContentLightLevelInfo", kVTCompressionPropertyKey_ContentLightLevelInfo, Data(md.cllSEI) as CFData)
            set("HDRMetadataInsertionMode", kVTCompressionPropertyKey_HDRMetadataInsertionMode,
                kVTHDRMetadataInsertionMode_Auto)
        }
        // A failed prepare is recorded like a refused property (only on failure, so the SDR `encoder_set[…]` report
        // is unchanged when it succeeds).
        let prepared = VTCompressionSessionPrepareToEncodeFrames(s)
        if prepared != noErr {
            failures.append("PrepareToEncodeFrames=\(prepared)")
            report.append("PrepareToEncodeFrames=\(prepared)")
            HEVCEncoder.log.error("ev=prepare_failed status=\(prepared)")
        }
        propertyFailures = failures
        propertyReport = report
        // HDR10: a refused Main10 / colour / metadata property, or a session that would not prepare with them, means
        // the stream would not be what STREAM_CONFIG announces; the owner falls back to SDR (`ev=hdr_fallback
        // reason=encoder_rejected`). `deinit` closes the session. SDR keeps logging failures only, as before.
        if hdr, let refused = HDRPolicy.refusedEncoderProperty(failures) {
            throw HDRSetupError(reason: .encoderRejected, detail: refused)
        }

        // T-235: the sharp modes need the Metal pass; without it the session runs today's 4:2:0 path.
        if let upsample = chroma.applied.sharpUpsample {
            do {
                chromaConverter = try ChromaConverter(width: settings.encodedWidthPx, height: settings.encodedHeightPx,
                                                      upsample: upsample)
            } catch {
                logSink(.warning, "chroma_metal_unavailable",
                        "error=\(StreamProfileLog.value(String(describing: error)))")
                chroma = chroma.fallingBack(.metalUnavailable)
            }
        }
        self.chroma = chroma
        if chroma.statsEnabled { chromaStats = ChromaStatsWindow(mode: chroma.applied, startUs: HostClock.nowUs()) }

        // Idle keyframe: a pending keyframe request with no new frames for ~1 s re-encodes the last buffer.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "matebridge.encoder.idle"))
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.idleTick() }
        idleTimer = timer
        timer.resume()

        // T-253: starts a refinement train once the screen has been still; later frames are chained from outputs.
        if refine.enabled {
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "matebridge.encoder.refine"))
            t.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
            t.setEventHandler { [weak self] in self?.refineTick() }
            refineTimer = t
            t.resume()
        }

        // T-177 debug step (off by default): drives the live setter on a timer.
        if let step = knobs.bitrateStep {
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "matebridge.encoder.bitrate_step"))
            let every = DispatchTimeInterval.milliseconds(step.periodMs)
            t.schedule(deadline: .now() + every, repeating: every)
            t.setEventHandler { [weak self] in self?.bitrateStepTick(step) }
            stepTimer = t
            t.resume()
        }

        // The SDR lines are unchanged; HDR10 appends `dynamic_range=hdr10`.
        let rangeField = hdr ? " dynamic_range=\(settings.dynamicRange.logName)" : ""
        logSink(.info, "encoder_config",
                "codec=\(settings.codec.logName) encoder_profile=\(profile.rawValue) "
                + "bitrate_kbps=\(settings.bitrateKbps) source=\(settings.bitrateSource) "
                + "\(knobs.logFields) quality_applied=\(qualityApplied ? 1 : 0)" + rangeField)
        // T-204 (decision 0026 §4): one line per stream start naming the configuration this log came from.
        logSink(.info, "profile", StreamProfileLog.fields(settings: settings, encoderProfile: profile,
                                                          build: Self.buildInfo, env: env) + rangeField)
    }

    /// The running build (T-145), for `ev=profile`'s `sha=`: the same source as `ev=app_start`.
    private static let buildInfo = BuildInfo(infoDictionary: Bundle.main.infoDictionary)

    /// `DataRateLimits` value: `[bytes, seconds, ...]` (`RateLimitWindows`). The default 1 s pair stays two integers,
    /// exactly what was set before T-177.
    static func dataRateLimits(kbps: Int, shortWindowMs: Int?) -> CFArray {
        var values: [NSNumber] = []
        for p in RateLimitWindows.pairs(kbps: kbps, shortWindowMs: shortWindowMs) {
            values.append(NSNumber(value: p.bytes))
            values.append(p.windowMs == 1000 ? NSNumber(value: 1) : NSNumber(value: Double(p.windowMs) / 1000))
        }
        return values as CFArray
    }

    static func codecType(_ codec: Codec) -> CMVideoCodecType {
        codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
    }

    /// HEVC Main (Main10 for an HDR10 stream, decision 0032), or H.264 High (constant since T-204 retired
    /// `MATEBRIDGE_H264_PROFILE`), level chosen by the encoder. `HDRPolicy` never derives HDR10 for H.264.
    static func profileLevel(_ codec: Codec, dynamicRange: DynamicRange = .sdr) -> CFString {
        if codec == .h264 { return kVTProfileLevel_H264_High_AutoLevel }
        return dynamicRange == .hdr10 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
    }

    /// T-235 `MATEBRIDGE_CHROMA=444`: HEVC Main 4:4:4. The SDK has no constant; `ave.hevc` accepts this string
    /// (research 2026-10-05 section 1). Apple may change it, hence the `profile_rejected` fallback.
    static var main444ProfileLevel: CFString { "HEVC_Main444_AutoLevel" as CFString }

    /// What ScreenCaptureKit must deliver for the applied chroma mode: `420f` (today) or `BGRA` (T-235).
    var capturePixelFormat: OSType {
        chroma.applied.captureFormat == .bgra ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    /// T-235: the `chroma_stats` fields once its 10 s window is over; nil before, and always nil unless
    /// `chroma.statsEnabled`.
    func takeChromaStats(nowUs: UInt64) -> String? {
        lock.withLock { chromaStats?.take(nowUs: nowUs) }
    }

    /// Profile name logged for H.264 (`profile=high`).
    static let h264ProfileLogName = "high"

    // Session colour properties (T-113: one source for the session and the input retag).
    static var sessionPrimaries: CFString { kCVImageBufferColorPrimaries_ITU_R_709_2 }
    static var sessionTransfer: CFString { kCVImageBufferTransferFunction_sRGB }
    static var sessionMatrix: CFString { kCVImageBufferYCbCrMatrix_ITU_R_709_2 }
    static let sessionColorTags = ColorTags(primaries: sessionPrimaries as String, transfer: sessionTransfer as String,
                                            matrix: sessionMatrix as String)

    /// The session's colour properties for a dynamic range: SDR as above; HDR10 BT.2020 / SMPTE ST 2084 (PQ) /
    /// BT.2020 (decision 0032). Their string values equal `SessionColorTags` (tested in Core).
    static func sessionColor(_ range: DynamicRange) -> (primaries: CFString, transfer: CFString, matrix: CFString) {
        range == .hdr10
            ? (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
               kCVImageBufferYCbCrMatrix_ITU_R_2020)
            : (sessionPrimaries, sessionTransfer, sessionMatrix)
    }

    /// `sessionColor(range)` as `ColorTags` (the retag comparison and its log line).
    static func colorTags(for range: DynamicRange) -> ColorTags {
        let c = sessionColor(range)
        return ColorTags(primaries: c.primaries as String, transfer: c.transfer as String, matrix: c.matrix as String)
    }

    /// T-113: VideoToolbox colour-converts every input whose colour tags differ from the session's (~2.4 ms per
    /// 2800x1840 frame on the M6, and a gamma shift). ScreenCaptureKit tags its sRGB 4:2:0 buffers with BT.709
    /// transfer, so they are retagged to the session's tags here (see `InputRetag`). The pixels are not touched.
    /// HDR10 (decision 0032): the session is BT.2020 / PQ / BT.2020; SCK's BT.2100 PQ capture normally carries those
    /// tags already, anything else is rewritten the same way.
    /// Returns the tags that were replaced, nil when the buffer already matched (or carries no colour information).
    static func retagForSession(_ buffer: CVPixelBuffer, range: DynamicRange = .sdr) -> ColorTags? {
        func tag(_ key: CFString) -> String? { CVBufferCopyAttachment(buffer, key, nil) as? String }
        let current = ColorTags(primaries: tag(kCVImageBufferColorPrimariesKey),
                                transfer: tag(kCVImageBufferTransferFunctionKey),
                                matrix: tag(kCVImageBufferYCbCrMatrixKey))
        let hasColorSpace = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil) != nil
        guard InputRetag.needsRetag(buffer: current, hasColorSpace: hasColorSpace, session: colorTags(for: range)) else {
            return nil
        }
        let c = sessionColor(range)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, c.primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, c.transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, c.matrix, .shouldPropagate)
        return current
    }

    /// Profile name for the `ev=encoder_config` line logged with the parameter sets.
    private var profileLogName: String {
        if settings.codec == .h264 { return Self.h264ProfileLogName }
        if settings.dynamicRange == .hdr10 { return "main10" }
        return chroma.applied == .yuv444 ? "main444" : "main"
    }

    /// Effective periodic keyframe interval in seconds (0 = on request only).
    static let keyframeIntervalSeconds = KeyframeIntervalPolicy.fromEnvironment()

    /// Read-back of the cadence-related properties as the session reports them (not just what we asked for).
    func cadenceReadback() -> String {
        guard !order.isStopped else { return "session closed" }
        return "RealTime=\(read(kVTCompressionPropertyKey_RealTime)) "
            + "ExpectedFrameRate=\(read(kVTCompressionPropertyKey_ExpectedFrameRate)) "
            + "MaxKeyFrameIntervalDuration=\(read(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration)) "
            + "MaxFrameDelayCount=\(read(kVTCompressionPropertyKey_MaxFrameDelayCount)) "
            + "Hardware=\(read(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder))"
    }

    /// Colour properties as the session reports them, for the dump tool.
    func colorReadback() -> String {
        guard !order.isStopped else { return "session closed" }
        return "primaries=\(read(kVTCompressionPropertyKey_ColorPrimaries)) "
            + "transfer=\(read(kVTCompressionPropertyKey_TransferFunction)) "
            + "matrix=\(read(kVTCompressionPropertyKey_YCbCrMatrix))"
    }

    /// `ev=encoder_hw status=` when there is no live session to read (closed, or no encoder in the pipeline).
    static let noSessionStatus: OSStatus = kVTInvalidSessionErr

    /// T-187: did VideoToolbox pick the hardware encoder? Reads `UsingHardwareAcceleratedVideoEncoder` once; a
    /// non-`noErr` read or a missing/non-boolean value is `unknown`. A closed session reports `noSessionStatus`.
    /// The session only enables (does not require) the hardware encoder, so a software fallback is possible.
    func hardwareCheck() -> EncoderHardwareCheck {
        guard !order.isStopped else { return .unknown(status: Self.noSessionStatus) }
        let (status, value) = copyProperty(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder)
        return EncoderHardwareCheck(usingHardware: status == noErr ? value as? Bool : nil, status: status)
    }

    /// `key` as the session reports it, or `unset(<OSStatus>)` (cadence and colour read-backs).
    private func read(_ key: CFString) -> String {
        let (status, value) = copyProperty(key)
        guard status == noErr, let value else { return "unset(\(status))" }
        return "\(value)"
    }

    /// `VTSessionCopyProperty` on the live session: the status and the (retained, now owned) value.
    private func copyProperty(_ key: CFString) -> (OSStatus, AnyObject?) {
        var raw: UnsafeMutableRawPointer?
        let st = VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &raw)
        guard let raw else { return (st, nil) }
        return (st, Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue())
    }

    /// The next encoded frame will be a keyframe. With `resubmitNow`, the last captured buffer is encoded
    /// immediately (needed on a static screen, where no new capture may ever arrive).
    func requestKeyframe(resubmitNow: Bool = false) {
        order.requestKeyframe()
        if resubmitNow { resubmitLast() }
    }

    /// Encodes one captured frame (full-range 4:2:0, or `BGRA` under T-235's `MATEBRIDGE_CHROMA`; see
    /// `capturePixelFormat`). Never blocks and never grows a queue:
    /// if the encoder is backed up the frame replaces the single pending one.
    func encode(_ buffer: CVPixelBuffer, presentationTime: CMTime, captureTimeUs: UInt64,
                displayTimeUs: UInt64 = 0) {
        meter?.recordEncoderIn()
        // T-113: before the buffer reaches VideoToolbox (and before it becomes `last`, which re-submissions reuse).
        // Unconditional since T-204.
        if let replaced = Self.retagForSession(buffer, range: settings.dynamicRange) { noteRetag(replaced) }
        let input = Input(buffer: buffer, pts: presentationTime, captureTimeUs: captureTimeUs,
                          deliveredUs: HostClock.nowUs(), displayTimeUs: displayTimeUs)
        // T-253: motion cancels a running refinement train. It is noted inside the ordered offer, so every refine
        // frame offered before this point was validated against the old train and none can follow it.
        var cancelled: StillRefineReport?
        order.offer(bypassGate: false) { _ in
            lock.lock()
            cancelled = refinePolicy.noteCapture(nowUs: HostClock.nowUs())
            captureLeadUs = ResubmitStamp.lead(captureUs: input.captureTimeUs, deliveredUs: input.deliveredUs)
            lastStampUs = max(lastStampUs ?? 0, input.captureTimeUs)
            lock.unlock()
            return input
        }
        if let cancelled { logRefine(cancelled) }
    }

    /// Logs the first retag of this encoder (one line per session: which tags the capture carried).
    private func noteRetag(_ replaced: ColorTags) {
        lock.lock()
        let first = !retagLogged
        retagLogged = true
        lock.unlock()
        if first {
            logSink(.info, "input_retag",
                    "from=\(replaced.logValue) to=\(Self.colorTags(for: settings.dynamicRange).logValue)")
        }
    }

    /// Re-encodes the last captured buffer (keyframe on a static screen: the idle keyframe timer and
    /// `requestKeyframe(resubmitNow:)`). Reading `last` and offering it happen under one lock, so a newer capture can
    /// never be replaced in `last` by an older buffer.
    /// The stamp keeps the real captures' capture-to-delivery lead (T-086): the tablet pacer judges lateness as
    /// `ready - capture_time`, and a re-submission stamped plain "now" would look one lead (~6.6 ms) late.
    ///
    /// `refine` (T-253): a frame of the still-screen refinement train. It goes through the pacer gate like a capture
    /// (`bypassGate: false`), so the train runs at the stream rate, never as a burst.
    ///
    /// `trainID` names the train a refinement frame belongs to; it is revalidated here, inside the ordered offer
    /// (where a capture notes its cancel under the same order lock), and a pending keyframe request is never given to
    /// a refinement frame: the train ends and the normal capture path serves the keyframe.
    private func resubmitLast(trainID: UInt64? = nil) {
        let refine = trainID != nil
        var ended: StillRefineReport?
        order.offerChecked(bypassGate: !refine) { last, keyframePending in
            guard let l = last else { return nil }
            let nowUs = HostClock.nowUs()
            lock.lock()
            if let id = trainID {
                if !refinePolicy.isCurrent(id) { lock.unlock(); return nil }
                if keyframePending {
                    ended = refinePolicy.end(.keyframePending, nowUs: nowUs)
                    lock.unlock()
                    return nil
                }
            }
            let stamp = ResubmitStamp.stamp(nowUs: nowUs, leadUs: captureLeadUs, lastStampUs: lastStampUs)
            lastStampUs = max(lastStampUs ?? 0, stamp)
            lock.unlock()
            var input = Input(buffer: l.buffer, pts: CMTime(value: CMTimeValue(stamp), timescale: 1_000_000),
                              captureTimeUs: stamp, deliveredUs: nowUs)
            input.resubmit = true
            input.refine = refine
            return input
        }
        if let ended { logRefine(ended) }
    }

    /// 25 ms timer: starts a refinement train when the screen has been still (`StillRefinePolicy.tick`). The queue
    /// probe runs before the encoder lock is taken.
    private func refineTick() {
        let ready = refineReady()
        let keyframePending = order.keyframePending
        let (start, timedOut, id) = lock.withLock { () -> (Bool, StillRefineReport?, UInt64) in
            let r = refinePolicy.tick(nowUs: HostClock.nowUs(), queueReady: ready, keyframePending: keyframePending)
            return (r.start, r.timedOut, refinePolicy.trainID)
        }
        if let timedOut { logRefine(timedOut) }
        if start { resubmitLast(trainID: id) }
    }

    /// A refinement frame produced output (`bytes` > 0) or failed (`bytes` nil): continues or ends the train.
    private func refineOutput(bytes: Int?) {
        let ready = refineReady()
        let keyframePending = order.keyframePending
        let now = HostClock.nowUs()
        let (next, report, id) = lock.withLock { () -> (Bool, StillRefineReport?, UInt64) in
            guard let bytes else { return (false, refinePolicy.noteFailure(nowUs: now), 0) }
            let id = refinePolicy.trainID
            let r = refinePolicy.noteOutput(bytes: bytes, nowUs: now, queueReady: ready,
                                            keyframePending: keyframePending)
            return (r.submitNext, r.report, id)
        }
        if let report { logRefine(report) }
        if next { resubmitLast(trainID: id) }
    }

    /// `video ev=refine` (one line per train). A train that converged on its first frame (a tiny change on an
    /// already refined screen) or was cancelled before any output is `debug`.
    private func logRefine(_ r: StillRefineReport) {
        let quiet = r.frames == 0 || (r.frames == 1 && r.reason == .converged)
        Self.videoLog(quiet ? .debug : .info, "refine", r.logFields)
    }

    private func idleTick() {
        if order.keyframeDue(idleUs: HEVCEncoder.idleKeyframeNs / 1000) { resubmitLast() }
    }

    /// Target send rate `min(stream fps, panel Hz)` (T-058). Only the frame gate changes: the session, the virtual
    /// display and capture keep running and already encoded frames are never dropped.
    func setTargetFps(_ fps: Int) {
        order.setTargetFps(fps)
    }

    /// Changes the live session's target bitrate without restarting anything (T-177): no new `STREAM_CONFIG`, no
    /// video reconnect, no keyframe. Clamped to `BitrateRequest.defaultRange` and deduplicated; applied on the owner
    /// queue between two submits, never after `stop`. Whether VideoToolbox honours it (the `.fast` profile may
    /// accept and ignore it, cf. T-087) is a device measurement. With `MATEBRIDGE_QUALITY` accepted only
    /// `DataRateLimits` changes (`AverageBitRate` is not in use).
    @discardableResult
    func setTargetBitrate(kbps: Int) -> BitrateRequest.Decision {
        order.setBitrate(kbps: kbps)
    }

    /// `MATEBRIDGE_BITRATE_STEP` tick (its own timer queue).
    private func bitrateStepTick(_ step: BitrateStepKnob) {
        let kbps = lock.withLock { () -> Int in
            defer { stepTick += 1 }
            return step.value(atTick: stepTick)
        }
        setTargetBitrate(kbps: kbps)
    }

    /// Owner queue only (`Backend.setBitrate`, enqueued by `EncoderSubmitOrder.setBitrate`). Logs one line per
    /// applied change (requests equal to the value in force never get here).
    private func applyBitrate(kbps: Int, session: VTCompressionSession) {
        var avg = "skipped"
        if !qualityApplied {
            avg = String(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                              value: (kbps * 1000) as CFNumber))
        }
        let limits = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                                          value: Self.dataRateLimits(kbps: kbps, shortWindowMs: knobs.rateWindowMs))
        Self.videoLog(.info, "bitrate_set", "kbps=\(kbps) avg_status=\(avg) limits_status=\(limits)")
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

        /// After the encoder is gone nothing is set (its `deinit` already stopped the order).
        func setBitrate(kbps: Int) {
            encoder?.applyBitrate(kbps: kbps, session: session)
        }

        /// Synchronous `CompleteFrames` runs here, on the owner queue, never on a Swift cooperative thread.
        func completeAndInvalidate() {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    /// Owner queue only (`Backend.encode`).
    private func send(_ frame: Input, key: Bool, token: EncoderSubmitToken, session: VTCompressionSession) {
        // T-235: the Metal pass runs here, so only frames that are really submitted are converted (the pacer may
        // replace or decimate captures); its time falls between `deliveredUs` and `submittedUs` in the trace.
        let image = chromaConverter.map { convertForEncoder(frame.buffer, $0) } ?? frame.buffer
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
        trace.resubmit = frame.resubmit
        let refine = frame.refine
        trace.submittedUs = HostClock.nowUs()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: image, presentationTimeStamp: frame.pts,
            duration: .invalid, frameProperties: props, infoFlagsOut: nil
        ) { [weak self, trace] status, _, sampleBuffer in
            guard let self else { return }
            let elapsedUs = (DispatchTime.now().uptimeNanoseconds - start) / 1000
            var t = trace
            t.encodedUs = HostClock.nowUs()
            self.completed(status: status, sampleBuffer: sampleBuffer, token: token, captureTimeUs: captureTimeUs, refine: refine,
                           encodeTimeUs: elapsedUs, trace: t)
        }
        if status != noErr {
            HEVCEncoder.log.error("ev=encode_failed status=\(status)")
            slotFailed(token, VideoEncoderError.encode(status))
        }
    }

    /// T-235: the converted `420f` buffer, or `buffer` unchanged when it is not a session-size `BGRA` frame or the
    /// pass failed (VideoToolbox then converts the `BGRA` frame itself; counted as `conv_fail`).
    private func convertForEncoder(_ buffer: CVPixelBuffer, _ converter: ChromaConverter) -> CVPixelBuffer {
        switch converter.convert(buffer) {
        case .converted(let out, let wallUs, let gpuUs):
            lock.withLock { chromaStats?.recordConversion(wallUs: wallUs, gpuUs: gpuUs) }
            return out
        case .passThrough:
            return buffer
        case .failed(let reason):
            let first = lock.withLock { () -> Bool in
                chromaStats?.recordConversionFailure()
                defer { chromaFailureLogged = true }
                return !chromaFailureLogged
            }
            if first { logSink(.warning, "chroma_convert_failed", "reason=\(reason)") }
            return buffer
        }
    }

    /// A submitted frame produced output (or none); frees the slot and starts the pending frame, if any.
    private func completed(status: OSStatus, sampleBuffer: CMSampleBuffer?, token: EncoderSubmitToken,
                           captureTimeUs: UInt64, refine: Bool = false, encodeTimeUs: UInt64, trace: FrameTrace) {
        let ok = status == noErr && sampleBuffer != nil
        var outputBytes = 0
        if let sb = sampleBuffer, ok {
            meter?.recordEncoderOut(encodeTimeUs: encodeTimeUs)
            if chroma.statsEnabled, !trace.resubmit, trace.encodedUs >= trace.deliveredUs {
                lock.withLock { chromaStats?.recordEncoded(captureToEncodeUs: trace.encodedUs - trace.deliveredUs) }
            }
            outputBytes = handle(sb, captureTimeUs: captureTimeUs, encodeTimeUs: encodeTimeUs, trace: trace)
        }
        if ok { lock.lock(); consecutiveFailures = 0; lock.unlock() }
        if !ok {
            // A frame the encoder dropped or failed breaks the reference chain: recover with a keyframe.
            HEVCEncoder.log.error("ev=encode_no_output status=\(status)")
            slotFailed(token, VideoEncoderError.encode(status))
        } else {
            order.release(token, failed: false)
        }
        // After the release, so the next refinement frame can claim the slot at once.
        if refine { refineOutput(bytes: ok && outputBytes > 0 ? outputBytes : nil) }
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
        let timer = idleTimer
        idleTimer = nil
        let step = stepTimer
        stepTimer = nil
        let refineT = refineTimer
        refineTimer = nil
        lock.unlock()
        timer?.cancel()
        step?.cancel()
        refineT?.cancel()
        // `order` is nil only if `init` threw before creating it (then there is no session to close).
        if let order { order.stop(completion: completion) } else { completion?() }
    }

    /// Only enqueues the teardown: no wait, and the teardown block captures the backend, never `self`.
    deinit { beginStop(completion: nil) }

    /// Returns the size of the delivered frame in bytes (0 when nothing was delivered).
    @discardableResult
    private func handle(_ sb: CMSampleBuffer, captureTimeUs: UInt64, encodeTimeUs: UInt64, trace: FrameTrace) -> Int {
        guard let format = CMSampleBufferGetFormatDescription(sb) else { return 0 }
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
            // T-240: every session, with `source=env|prefs|default`.
            let info = ChromaBitstreamInfo.parse(parameterSets: sets, codec: settings.codec)
            let line = ChromaConfigLog.line(chroma, info)
            logSink(line.level, ChromaConfigLog.event, line.fields)
            output(EncodedVideoFrame(flags: .codecConfig, captureTimeUs: 0, data: blob), 0)
        }

        guard let block = CMSampleBufferGetDataBuffer(sb), let raw = Self.bytes(of: block) else { return 0 }
        guard let annexB = AnnexB.convert(lengthPrefixed: raw, lengthSize: lengthSize) else { return 0 }
        var frame = EncodedVideoFrame(flags: isKey ? .keyframe : [], captureTimeUs: captureTimeUs, data: annexB)
        frame.trace = trace
        output(frame, encodeTimeUs)
        return annexB.count
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
