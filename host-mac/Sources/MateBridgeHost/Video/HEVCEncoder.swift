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
        /// The still-screen refinement train (T-253) this frame belongs to; its output feeds `StillRefinePolicy` only
        /// while that train is still the current one.
        var refineTrain: UInt64?

        var skipsOnPendingKeyframe: Bool { refineTrain != nil }
        var isSynthetic: Bool { refineTrain != nil }

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
    /// Parameter sets of the last `CMFormatDescription` (guarded by `lock`): one extraction per format, not per frame.
    private var formatCache = ParameterSetCache()
    private var consecutiveFailures = 0
    private var idleTimer: DispatchSourceTimer?
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
    /// Host time of the newest keyframe output (init time before the first) and the byte size of the newest real
    /// (non-resubmitted) frame: the periodic-keyframe guard and the first refine frame's size estimate. Guarded by
    /// `lock`.
    private var lastKeyframeUs = HostClock.nowUs()
    /// Host time of the newest auxiliary keyframe output (packed full colour: the auxiliary session has its own
    /// periodic IDR deadline) and the submission counter pairing main and auxiliary frames. Guarded by `lock`.
    private var lastAuxKeyframeUs = HostClock.nowUs()
    private var nextPairID: UInt64 = 0
    private var lastMotionBytes = 0
    /// Byte size of the newest real auxiliary frame (packed full colour): the first refinement pair's estimate adds it.
    private var lastMotionAuxBytes = 0

    let settings: VideoSettings
    /// Encoder-level experiment knobs (T-086).
    let knobs: EncoderKnobs
    /// T-235 `MATEBRIDGE_CHROMA` / T-240 `settings.chromaPreference`: requested and applied chroma mode. Final once
    /// `init` returns.
    private(set) var chroma = ChromaDecision(knob: .unset, applied: .yuv420, reason: nil)
    /// The sharp-YUV Metal pass (`chroma.applied` is `sharp_*`); used on the owner queue only. Set in `init` only.
    private var chromaConverter: ChromaConverter?
    /// Packed full colour (decision 0034, T-258; `chroma.applied` is `packed444`): the Metal packer (owner queue only)
    /// and the auxiliary VideoToolbox session it feeds. Set in `init` only.
    private var packer: PackedChromaPacker?
    private var auxEncoder: PackedAuxEncoder?
    /// Auxiliary keyframe wanted (the next real auxiliary frame is an IDR) and the packed path's counters, `lock`.
    private var auxKeyframePending = false  // guarded by auxFlagLock (also read where `lock` is held)
    private let auxFlagLock = NSLock()
    private var packedStats: PackedChromaStatsWindow?
    private var auxOffered = 0
    private var auxLost = 0
    private var packedErrorReported = false
    /// Host time of the last auxiliary submission attempt (the idle retry of a pending auxiliary IDR), `lock`.
    private var lastAuxAttemptUs: UInt64 = 0
    /// Refinement frames waiting for both streams' outputs (T-258): capture stamp -> sizes. `lock`.
    private var refinePairs: [UInt64: RefinePair] = [:]

    private struct RefinePair {
        var train: UInt64
        var main: Int??  // nil = not in yet; .some(nil) = failed
        var aux: Int??
    }
    private var packedError: (@Sendable (String) -> Void)?
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
    /// `video ev=...` lines (`docs/LOGGING.md`).
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
         auxOutput: Output? = nil, onPackedError: @escaping @Sendable (String) -> Void = { _ in },
         onFailure: @escaping @Sendable (Error) -> Void = { _ in }) throws {
        self.packedError = onPackedError
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
        // tops out near 100 fps; without both the hardware encoder needs ~6 ms with even enough frame sizes (p99 <=
        // 4x mean on moving content). That `fast` profile is the only one (T-302 removed `MATEBRIDGE_ENCODER=llrc`).
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
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
            log: logSink,
            onSkipped: { [weak self] frame in self?.refineSkipped(frame) })
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
        set("RealTime", kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        set("AllowFrameReordering", kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // T-237: HDR10 wins over the chroma knob (`reason=hdr`, applied `420`): Main10, x420 PQ capture.
        // T-240: without the knob the tablet's `STREAM_PREFS.chroma = 1` asks for `sharp_nearest` (decision 0033).
        var chroma = ChromaPolicy.resolve(knob: knobs.chroma, preference: settings.chromaPreference,
                                          dynamicRange: settings.dynamicRange,
                                          packedChroma: settings.packedChroma,
                                          packedFellBack: settings.fullChromaFellBack)
        set("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel,
            Self.profileLevel(settings.codec, dynamicRange: settings.dynamicRange))
        set("ExpectedFrameRate", kVTCompressionPropertyKey_ExpectedFrameRate, settings.fps as CFNumber)
        set("AverageBitRate", kVTCompressionPropertyKey_AverageBitRate, (settings.bitrateKbps * 1000) as CFNumber)
        // Cap bursts (bytes per second) at 2x the average.
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
        // T-258: packed full colour needs the packer and the auxiliary session. The stream was announced as
        // `chroma_layout = 1`, so a failure here is not a silent fallback: the owner announces `chroma_layout = 0`
        // under a new config_id (`PackedSetupError`, `ev=chroma_fallback`).
        if chroma.applied == .packed444 {
            guard let auxOutput else { throw PackedSetupError(reason: "no_aux_output", detail: "") }
            do {
                packer = try PackedChromaPacker(width: settings.encodedWidthPx, height: settings.encodedHeightPx)
            } catch {
                throw PackedSetupError(reason: "metal_unavailable", detail: String(describing: error))
            }
            let configLog = logSink
            let decision = chroma
            let statsLock = lock
            let wrapped: Output = { [weak self] frame, encodeUs in
                if frame.isCodecConfig {
                    let sets = AnnexB.nalUnits(frame.data)
                    let line = ChromaConfigLog.line(decision, ChromaBitstreamInfo.parse(parameterSets: sets, codec: .hevc),
                                                    view: "aux")
                    configLog(line.level, ChromaConfigLog.event, line.fields)
                } else if !frame.data.isEmpty {
                    statsLock.withLock {
                        if frame.isKeyframe { self?.lastAuxKeyframeUs = HostClock.nowUs() }
                        let isRefine = self?.refinePairs[frame.captureTimeUs] != nil
                        self?.packedStats?.recordAux(bytes: frame.data.count, encodeUs: encodeUs,
                                                     kind: frame.isKeyframe ? .key : (isRefine ? .refine : .delta))
                        // A real (non-refinement) auxiliary frame sets the first refinement pair's size estimate.
                        if !isRefine { self?.lastMotionAuxBytes = frame.data.count }
                    }
                }
                auxOutput(frame, encodeUs)
                // After the frame is queued: a refinement train continues only once both streams' frames are in their
                // queues, so it never decides on a queue the auxiliary frame is about to overflow.
                if !frame.isCodecConfig, !frame.data.isEmpty {
                    self?.refinePairResolved(captureTimeUs: frame.captureTimeUs, aux: frame.data.count)
                }
            }
            do {
                let aux = try PackedAuxEncoder(
                    width: settings.encodedWidthPx, height: settings.encodedHeightPx, fps: settings.fps,
                    mainKbps: settings.bitrateKbps, rateWindowMs: knobs.rateWindowMs,
                    output: wrapped, onError: { [weak self] reason in self?.reportPackedError(reason) },
                    onLoss: { [weak self] t in self?.auxLostAfterSubmit(captureTimeUs: t) })
                auxEncoder = aux
                backend.aux = aux
            } catch {
                throw PackedSetupError(reason: "aux_setup", detail: String(describing: error))
            }
            packedStats = PackedChromaStatsWindow(startUs: HostClock.nowUs())
            auxKeyframePending = true  // the first auxiliary frame is an IDR, like the main one
        }
        self.chroma = chroma
        if chroma.statsEnabled, chroma.applied != .packed444 {
            chromaStats = ChromaStatsWindow(mode: chroma.applied, startUs: HostClock.nowUs())
        }

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

        // T-302: removed knobs that are still set in the launch environment are inert; say so once.
        for k in RemovedKnobs.present(env) {
            logSink(.warning, "knob_ignored", "name=\(k.name) value=\(k.value)")
        }

        // The SDR lines are unchanged; HDR10 appends `dynamic_range=hdr10`.
        let rangeField = hdr ? " dynamic_range=\(settings.dynamicRange.logName)" : ""
        logSink(.info, "encoder_config",
                "codec=\(settings.codec.logName) encoder_profile=fast "
                + "bitrate_kbps=\(settings.bitrateKbps) source=\(settings.bitrateSource) "
                + "\(knobs.logFields) quality_applied=0" + rangeField)
        // T-204 (decision 0026 §4): one line per stream start naming the configuration this log came from.
        logSink(.info, "profile", StreamProfileLog.fields(settings: settings, build: Self.buildInfo, env: env) + rangeField)
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

    /// What ScreenCaptureKit must deliver for the applied chroma mode: `420f` (today) or `BGRA` (T-235).
    var capturePixelFormat: OSType {
        chroma.applied.captureFormat == .bgra ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    /// T-235: the `chroma_stats` fields once its 10 s window is over; nil before, and always nil unless
    /// `chroma.statsEnabled`.
    func takeChromaStats(nowUs: UInt64) -> String? {
        lock.withLock { packedStats?.take(nowUs: nowUs) ?? chromaStats?.take(nowUs: nowUs) }
    }

    /// Profile name logged for H.264 (`profile=high`).
    static let h264ProfileLogName = "high"

    // Session colour properties (T-113: one source for the session and the input retag).
    static var sessionPrimaries: CFString { kCVImageBufferColorPrimaries_ITU_R_709_2 }
    static var sessionTransfer: CFString { kCVImageBufferTransferFunction_sRGB }
    static var sessionMatrix: CFString { kCVImageBufferYCbCrMatrix_ITU_R_709_2 }

    /// The session's colour properties for a dynamic range: SDR as above; HDR10 BT.2020 / SMPTE ST 2084 (PQ) /
    /// BT.2020 (decision 0032). Their string values equal `SessionColorTags`, which is what the per-frame retag comparison
    /// uses (no CFString bridging on the hot path; tested in Core).
    static func sessionColor(_ range: DynamicRange) -> (primaries: CFString, transfer: CFString, matrix: CFString) {
        range == .hdr10
            ? (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
               kCVImageBufferYCbCrMatrix_ITU_R_2020)
            : (sessionPrimaries, sessionTransfer, sessionMatrix)
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
        guard InputRetag.needsRetag(buffer: current, hasColorSpace: hasColorSpace, session: SessionColorTags.tags(for: range)) else {
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
        return "main"
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
    func requestKeyframe(resubmitNow: Bool = false, view: KeyframeView = .both) {
        // T-258: `view` picks the stream (decision 0034). The auxiliary one exists only in packed full colour.
        let aux = view.wantsAuxiliary && auxEncoder != nil
        let main = view.wantsMain || auxEncoder == nil
        guard main || aux else { return }
        if main { order.requestKeyframe() }
        if aux { auxFlagLock.withLock { auxKeyframePending = true } }
        if resubmitNow { resubmitLast() }
    }

    /// Packed full colour is running (an auxiliary session exists).
    var isPacked: Bool { auxEncoder != nil }

    /// CODEC_CONFIG of the auxiliary stream (`view = 1`); nil without packed full colour or before the first frame.
    func currentAuxCodecConfig() -> EncodedVideoFrame? { auxEncoder?.currentCodecConfig() }

    /// A keyframe request is pending in either stream (the refinement train must not run then).
    private var auxPending: Bool { auxFlagLock.withLock { auxKeyframePending } }
    private var anyKeyframePending: Bool { order.keyframePending || auxPending }

    /// The packed path failed for good (Metal, the auxiliary session): reported once; the owner falls back.
    private func reportPackedError(_ reason: String) {
        let report: (@Sendable (String) -> Void)? = lock.withLock {
            guard !packedErrorReported else { return nil }
            packedErrorReported = true
            return packedError
        }
        report?(reason)
    }

    /// Auxiliary frames offered to the auxiliary session and lost before it (both slots busy, refused) since the last
    /// call; the pipeline adds the queue and sender drops (`PackedChromaMonitor`).
    func takeAuxCounters() -> (offered: Int, lost: Int) {
        lock.withLock {
            defer { auxOffered = 0; auxLost = 0 }
            return (auxOffered, auxLost)
        }
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
                    "from=\(replaced.logValue) to=\(SessionColorTags.tags(for: settings.dynamicRange).logValue)")
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
                if keyframePending || auxPending {
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
            input.refineTrain = trainID
            return input
        }
        if let ended { logRefine(ended) }
    }

    /// 25 ms timer: starts a refinement train when the screen has been still (`StillRefinePolicy.tick`). The queue
    /// probe runs before the encoder lock is taken.
    private func refineTick() {
        let ready = refineReady()
        let keyframePending = anyKeyframePending
        let (start, timedOut, id) = lock.withLock { () -> (Bool, StillRefineReport?, UInt64) in
            let now = HostClock.nowUs()
            let r = refinePolicy.tick(nowUs: now, queueReady: ready, keyframePending: keyframePending,
                                      keyframeDue: periodicKeyframeDueLocked(nowUs: now),
                                      firstFrameEstimate: lastMotionBytes > 0 ? lastMotionBytes + (auxEncoder == nil ? 0 : (lastMotionAuxBytes > 0 ? lastMotionAuxBytes : lastMotionBytes / 2))
                                          : StillRefineConfig.defaultFirstFrameEstimate)
            return (r.start, r.timedOut, refinePolicy.trainID)
        }
        if let timedOut { logRefine(timedOut) }
        if start { resubmitLast(trainID: id) }
    }

    /// A refinement frame produced output (`bytes` > 0) or failed (`bytes` nil): continues or ends the train.
    /// Must hold `lock`. The session's periodic keyframe (`MaxKeyFrameIntervalDuration`) falls within the longest
    /// train: a refine frame must never be an IDR, so no train starts or continues then (`keyframe_due`).
    private func periodicKeyframeDueLocked(nowUs: UInt64) -> Bool {
        let c = refinePolicy.config
        let horizon = UInt64(c.maxFrames) * 1_000_000 / UInt64(max(1, settings.fps)) + c.timeoutUs + 1_000_000
        func due(_ last: UInt64) -> Bool {
            PeriodicKeyframe.isDue(nowUs: nowUs, lastKeyframeUs: last,
                                   intervalSeconds: Self.keyframeIntervalSeconds, horizonUs: horizon)
        }
        // T-258: the auxiliary session has its own periodic IDR deadline; either stream's falls within a train.
        return due(lastKeyframeUs) || (auxEncoder != nil && due(lastAuxKeyframeUs))
    }

    /// A held refine frame was dropped at reservation because a keyframe became pending: ends its train.
    private func refineSkipped(_ frame: Input) {
        guard let id = frame.refineTrain else { return }
        let report = lock.withLock { () -> StillRefineReport? in
            guard refinePolicy.isCurrent(id) else { return nil }
            return refinePolicy.end(.keyframePending, nowUs: HostClock.nowUs())
        }
        if let report { logRefine(report) }
    }

    /// `trainID` is the train the frame was submitted for. Output of any other train (cancelled, ended or replaced
    /// since) was delivered like every frame but is not counted for, and does not advance, the current train.
    private func refineOutput(trainID: UInt64, bytes: Int?) {
        let ready = refineReady()
        let keyframePending = anyKeyframePending
        let now = HostClock.nowUs()
        let (next, report) = lock.withLock { () -> (Bool, StillRefineReport?) in
            guard refinePolicy.isCurrent(trainID) else { return (false, nil) }
            guard let bytes else { return (false, refinePolicy.noteFailure(nowUs: now)) }
            let r = refinePolicy.noteOutput(bytes: bytes, nowUs: now, queueReady: ready,
                                            keyframePending: keyframePending,
                                            keyframeDue: periodicKeyframeDueLocked(nowUs: now),
                                            deferQueueBusy: auxEncoder != nil)
            return (r.submitNext, r.report)
        }
        if let report { logRefine(report) }
        if next { resubmitLast(trainID: trainID) }
    }

    /// `video ev=refine` (one line per train). A train that converged on its first frame (a tiny change on an
    /// already refined screen) or was cancelled before any output is `debug`.
    private func logRefine(_ r: StillRefineReport) {
        let quiet = r.frames == 0 || (r.frames == 1 && r.reason == .converged)
        Self.videoLog(quiet ? .debug : .info, "refine", r.logFields)
    }

    private func idleTick() {
        if order.keyframeDue(idleUs: HEVCEncoder.idleKeyframeNs / 1000) { resubmitLast(); return }
        // T-258: a pending auxiliary IDR (both auxiliary slots were busy, or a static screen) is retried here: the
        // refinement train and the capture path both leave it alone otherwise.
        guard auxEncoder != nil, auxPending else { return }
        let now = HostClock.nowUs()
        let due = lock.withLock { now &- lastAuxAttemptUs >= Self.auxRetryUs }
        if due { resubmitLast() }
    }

    /// Spacing of the idle retry of a pending auxiliary IDR (the idle timer ticks every 250 ms).
    private static let auxRetryUs: UInt64 = 200_000

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
        /// The packed full colour auxiliary session (T-258), closed after the main one on the same owner queue.
        var aux: PackedAuxEncoder?
        init(session: VTCompressionSession) { self.session = session }

        /// After the encoder is gone (its `deinit` already stopped the order) a queued frame is not submitted.
        func encode(_ frame: Input, keyframe: Bool, token: EncoderSubmitToken) {
            encoder?.send(frame, key: keyframe, token: token, session: session)
        }

        /// Synchronous `CompleteFrames` runs here, on the owner queue, never on a Swift cooperative thread.
        func completeAndInvalidate() {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            aux?.stop()
        }
    }

    /// Owner queue only (`Backend.encode`).
    private func send(_ frame: Input, key: Bool, token: EncoderSubmitToken, session: VTCompressionSession) {
        // T-235: the Metal pass runs here, so only frames that are really submitted are converted (the pacer may
        // replace or decimate captures); its time falls between `deliveredUs` and `submittedUs` in the trace.
        let pairID: UInt64 = lock.withLock { nextPairID &+= 1; return nextPairID }
        var metalUs: UInt64 = 0   // wall time of the Metal pass(es) for this frame (T-311 `FrameTrace.convertedUs`)
        var image = chromaConverter.map { convertForEncoder(frame.buffer, $0, metalUs: &metalUs) } ?? frame.buffer
        // T-258: one Metal pass makes both pictures; the auxiliary one goes to its own session right away, with this
        // frame's PTS and `capture_time_us`. The main frame is submitted below, the auxiliary one never waits for it.
        if let packer, let auxEncoder { image = packAndSubmitAux(frame, pairID: pairID, packer: packer, aux: auxEncoder, metalUs: &metalUs) ?? image }
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let start = DispatchTime.now().uptimeNanoseconds
        let captureTimeUs = frame.captureTimeUs
        var trace = FrameTrace()
        trace.pairID = pairID
        // Origin: the earliest of the SCK stamps and the callback (T-072), so the totals can never be shorter than
        // the stages; the raw stamps travel along and are logged as signed offsets.
        trace.ptsUs = captureTimeUs
        trace.displayUs = frame.displayTimeUs
        trace.deliveredUs = frame.deliveredUs
        trace.captureUs = FrameTrace.origin(displayUs: frame.displayTimeUs, ptsUs: captureTimeUs,
                                            deliveredUs: frame.deliveredUs)
        trace.slotWaitUs = frame.slotWaitUs
        trace.convertedUs = metalUs
        trace.resubmit = frame.resubmit
        let refineTrain = frame.refineTrain
        trace.submittedUs = HostClock.nowUs()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: image, presentationTimeStamp: frame.pts,
            duration: .invalid, frameProperties: props, infoFlagsOut: nil
        ) { [weak self, trace] status, _, sampleBuffer in
            guard let self else { return }
            let elapsedUs = (DispatchTime.now().uptimeNanoseconds - start) / 1000
            var t = trace
            t.encodedUs = HostClock.nowUs()
            self.completed(status: status, sampleBuffer: sampleBuffer, token: token, captureTimeUs: captureTimeUs, refineTrain: refineTrain,
                           encodeTimeUs: elapsedUs, trace: t)
        }
        if status != noErr {
            HEVCEncoder.log.error("ev=encode_failed status=\(status)")
            slotFailed(token, VideoEncoderError.encode(status))
        }
    }

    /// T-258 (owner queue): packs `frame` and hands the auxiliary picture to the auxiliary session; returns the main
    /// picture for the main session, nil when the frame could not be packed (the main session then gets the `BGRA`
    /// frame, a normal 4:2:0 picture, and the owner falls back).
    private func packAndSubmitAux(_ frame: Input, pairID: UInt64, packer: PackedChromaPacker, aux: PackedAuxEncoder,
                                  metalUs: inout UInt64) -> CVPixelBuffer? {
        switch packer.pack(frame.buffer) {
        case .packed(let main, let auxBuffer, let wallUs, let gpuUs):
            metalUs &+= wallUs
            lock.withLock { packedStats?.recordPack(wallUs: wallUs, gpuUs: gpuUs) }
            // A refinement frame never takes the auxiliary keyframe (it would end the train, like the main one).
            let wantKey = frame.refineTrain == nil && auxFlagLock.withLock {
                defer { auxKeyframePending = false }
                return auxKeyframePending
            }
            lock.withLock {
                auxOffered += 1
                lastAuxAttemptUs = HostClock.nowUs()
                if let train = frame.refineTrain {
                    if refinePairs.count >= 16 { refinePairs.removeAll() }
                    refinePairs[frame.captureTimeUs] = RefinePair(train: train, main: nil, aux: nil)
                }
            }
            if !aux.encode(auxBuffer, presentationTime: frame.pts, captureTimeUs: frame.captureTimeUs, pairID: pairID,
                              keyframe: wantKey) {
                // The auxiliary stream lost a frame: its chain has a hole, so the next one is an IDR.
                lock.withLock { auxLost += 1; packedStats?.recordAuxLost() }
                auxFlagLock.withLock { auxKeyframePending = true }
                refinePairResolved(captureTimeUs: frame.captureTimeUs, aux: .some(nil))
            }
            return main
        case .passThrough:
            return nil
        case .failed(let reason):
            lock.withLock { packedStats?.recordPackFailure() }
            reportPackedError("pack_\(reason)")
            return nil
        }
    }

    /// T-235: the converted `420f` buffer, or `buffer` unchanged when it is not a session-size `BGRA` frame or the
    /// pass failed (VideoToolbox then converts the `BGRA` frame itself; counted as `conv_fail`).
    private func convertForEncoder(_ buffer: CVPixelBuffer, _ converter: ChromaConverter,
                                   metalUs: inout UInt64) -> CVPixelBuffer {
        switch converter.convert(buffer) {
        case .converted(let out, let wallUs, let gpuUs):
            metalUs &+= wallUs
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
                           captureTimeUs: UInt64, refineTrain: UInt64? = nil, encodeTimeUs: UInt64, trace: FrameTrace) {
        let ok = status == noErr && sampleBuffer != nil
        var outputBytes = 0
        if let sb = sampleBuffer, ok {
            meter?.recordEncoderOut(encodeTimeUs: encodeTimeUs)
            if chroma.statsEnabled, !trace.resubmit, trace.encodedUs >= trace.deliveredUs {
                lock.withLock { chromaStats?.recordEncoded(captureToEncodeUs: trace.encodedUs - trace.deliveredUs) }
            }
            outputBytes = handle(sb, captureTimeUs: captureTimeUs, encodeTimeUs: encodeTimeUs, trace: trace,
                                 refine: refineTrain != nil)
            if !trace.resubmit, outputBytes > 0 { lock.withLock { lastMotionBytes = outputBytes } }
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
        if let refineTrain {
            let mainBytes: Int? = ok && outputBytes > 0 ? outputBytes : nil
            if auxEncoder == nil {
                refineOutput(trainID: refineTrain, bytes: mainBytes)
            } else {
                // T-258: the byte budget and the convergence test see both streams' real sizes together, so a tiny
                // main frame cannot end a train whose auxiliary picture still changes (and the total ceiling holds).
                refinePairResolved(captureTimeUs: captureTimeUs, main: .some(mainBytes))
            }
        }
    }

    /// One stream's output (or failure) of a refinement frame; when both are in, the train sees their sum. `main` /
    /// `aux`: nil argument = not this stream's report; `.some(nil)` = that stream failed.
    private func refinePairResolved(captureTimeUs: UInt64, main: Int?? = nil, aux: Int?? = nil) {
        let done: (train: UInt64, total: Int?)? = lock.withLock {
            guard var pair = refinePairs[captureTimeUs] else { return nil }
            if let main { pair.main = main }
            if let aux { pair.aux = aux }
            guard let m = pair.main, let a = pair.aux else {
                refinePairs[captureTimeUs] = pair
                return nil
            }
            refinePairs[captureTimeUs] = nil
            if let m, let a { return (pair.train, m + a) }
            return (pair.train, nil)
        }
        if let done { refineOutput(trainID: done.train, bytes: done.total) }
    }

    /// The auxiliary session lost a frame it had accepted (callback failure, or discarded after a lost one): counted
    /// for the fallback rule, the next auxiliary frame is an IDR, and a refinement pair waiting for it fails.
    private func auxLostAfterSubmit(captureTimeUs: UInt64) {
        lock.withLock { auxLost += 1; packedStats?.recordAuxLost() }
        auxFlagLock.withLock { auxKeyframePending = true }
        refinePairResolved(captureTimeUs: captureTimeUs, aux: .some(nil))
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
        let refineT = refineTimer
        refineTimer = nil
        lock.unlock()
        timer?.cancel()
        refineT?.cancel()
        // `order` is nil only if `init` threw before creating it (then there is no session to close).
        if let order { order.stop(completion: completion) } else { completion?() }
    }

    /// Only enqueues the teardown: no wait, and the teardown block captures the backend, never `self`.
    deinit { beginStop(completion: nil) }

    /// Returns the size of the delivered frame in bytes (0 when nothing was delivered).
    @discardableResult
    private func handle(_ sb: CMSampleBuffer, captureTimeUs: UInt64, encodeTimeUs: UInt64, trace: FrameTrace,
                        refine: Bool = false) -> Int {
        guard let format = CMSampleBufferGetFormatDescription(sb) else { return 0 }
        let isKey = Self.isKeyframe(sb)

        // Parameter sets are re-announced only when they change (first frame included). They can only change with the
        // format description object, so the same object is not looked at again.
        let (params, isNewFormat) = lock.withLock { formatCache.parameters(for: format, codec: settings.codec) }
        let sets = params.sets
        let blob = params.blob
        let changed: Bool = isNewFormat && lock.withLock {
            let c = !blob.isEmpty && blob != lastParameterSets
            if c { lastParameterSets = blob }
            return c
        }
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

        guard let annexB = Self.annexBPayload(of: sb, lengthSize: params.lengthSize) else { return 0 }
        if isKey { lock.withLock { lastKeyframeUs = HostClock.nowUs() } }
        lock.withLock { packedStats?.recordMain(bytes: annexB.count, kind: isKey ? .key : (refine ? .refine : .delta)) }
        var frame = EncodedVideoFrame(flags: isKey ? .keyframe : [], captureTimeUs: captureTimeUs, data: annexB)
        frame.pairID = trace.pairID
        frame.trace = trace
        output(frame, encodeTimeUs)
        return annexB.count
    }

    /// Keyframe flag of an encoded sample (`NotSync` absent; no attachments counts as a keyframe).
    static func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
              let first = arr.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    /// The encoded sample as one Annex-B access unit (length prefixes of `lengthSize` bytes become start codes); nil
    /// when the sample has no data or is malformed. One copy out of the block buffer, then converted in place (T-313).
    static func annexBPayload(of sb: CMSampleBuffer, lengthSize: Int) -> [UInt8]? {
        guard let block = CMSampleBufferGetDataBuffer(sb), var data = bytes(of: block),
              AnnexB.convertInPlace(&data, lengthSize: lengthSize) else { return nil }
        return data
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

/// The parameter sets of the last `CMFormatDescription` an encoder saw (T-313). VideoToolbox hands out the same format
/// description object for every frame of a stable stream, so VPS/SPS/PPS are extracted and joined once per object, not
/// per frame. A new object is extracted again (the caller compares the blob with what it announced last, so a
/// CODEC_CONFIG still goes out on every change). Not thread-safe: the owner guards it.
struct ParameterSetCache {
    struct Entry {
        var sets: [[UInt8]]
        var blob: [UInt8]
        var lengthSize: Int
    }

    private var format: CMFormatDescription?
    private var entry: Entry?

    /// `isNew` is true when `format` is not the object of the previous call (the sets were extracted now).
    mutating func parameters(for format: CMFormatDescription, codec: Codec) -> (entry: Entry, isNew: Bool) {
        if let entry, let last = self.format, last === format { return (entry, false) }
        let (sets, lengthSize) = HEVCEncoder.parameterSets(format, codec: codec)
        let fresh = Entry(sets: sets, blob: AnnexB.parameterSets(sets), lengthSize: lengthSize)
        self.format = format
        entry = fresh
        return (fresh, true)
    }
}
