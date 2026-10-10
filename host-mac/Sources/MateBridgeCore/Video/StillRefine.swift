import Foundation

/// T-253 "refine when still": settings of the still-screen refinement train.
///
/// Measured (T-253 plan): VideoToolbox's hardware HEVC encoder ignores per-frame quality changes (`Quality`,
/// `MaxAllowedFrameQP`, a raised `AverageBitRate`), but re-encoding the same buffer as a run of ordinary P frames
/// converges the picture by 2-3 dB PSNR in 12-14 frames (~400 KB in all). The train is a run of such frames.
public struct StillRefineConfig: Equatable, Sendable {
    public var enabled: Bool
    /// No new capture for this long = the screen is still.
    public var stillUs: UInt64
    /// At most this many frames per train.
    public var maxFrames: Int
    /// A train stops once its frames add up to this many bytes.
    public var maxBytes: Int
    /// A frame this small (or smaller) means the picture has converged.
    public var convergedBytes: Int
    /// Minimum time between two train starts.
    public var minGapUs: UInt64
    /// A submitted frame whose output does not arrive within this time ends the train.
    public var timeoutUs: UInt64

    public static let defaultStillMs = 200
    public static let stillMsRange = 50...2000
    public static let defaultMaxFrames = 16
    public static let framesRange = 1...60
    public static let usbKB = 1024
    public static let networkKB = 256
    public static let kbRange = 16...8192
    /// First-frame size assumed when no real frame has been encoded yet (a motion frame is the normal estimate).
    public static let defaultFirstFrameEstimate = 64 * 1024

    public static let disabled = StillRefineConfig(enabled: false, stillUs: 200_000, maxFrames: 16,
                                                   maxBytes: 0, convergedBytes: 1536, minGapUs: 500_000,
                                                   timeoutUs: 250_000)

    public init(enabled: Bool, stillUs: UInt64, maxFrames: Int, maxBytes: Int, convergedBytes: Int,
                minGapUs: UInt64, timeoutUs: UInt64) {
        self.enabled = enabled
        self.stillUs = stillUs
        self.maxFrames = maxFrames
        self.maxBytes = maxBytes
        self.convergedBytes = convergedBytes
        self.minGapUs = minGapUs
        self.timeoutUs = timeoutUs
    }

    /// Default on; `MATEBRIDGE_REFINE=0` turns it off. `MATEBRIDGE_REFINE_MS` (50...2000), `MATEBRIDGE_REFINE_KB`
    /// (16...8192, the train's byte ceiling; default 1024 on USB, 256 on a network link) and `MATEBRIDGE_REFINE_FRAMES`
    /// (1...60) override; an invalid value keeps the default. A remote session (`remoteKbps` set, decision 0038:
    /// `STREAM_PREFS.link = 1` with that target bit rate) budgets `RemoteLinkProfile.bytes(bitrateKbps:)` instead,
    /// unless `MATEBRIDGE_REFINE_KB` is set (the developer override wins).
    public static func resolve(env: [String: String], transport: SessionTransport,
                               remoteKbps: Int? = nil) -> StillRefineConfig {
        var c = StillRefineConfig.disabled
        c.enabled = env["MATEBRIDGE_REFINE"]?.trimmingCharacters(in: .whitespaces) != "0"
        let ms = int(env["MATEBRIDGE_REFINE_MS"], in: stillMsRange) ?? defaultStillMs
        c.stillUs = UInt64(ms) * 1000
        c.maxFrames = int(env["MATEBRIDGE_REFINE_FRAMES"], in: framesRange) ?? defaultMaxFrames
        if let kb = int(env["MATEBRIDGE_REFINE_KB"], in: kbRange) {
            c.maxBytes = kb * 1024
        } else if let remoteKbps {
            c.maxBytes = RemoteLinkProfile.bytes(bitrateKbps: remoteKbps)
        } else {
            c.maxBytes = (transport == .usb ? usbKB : networkKB) * 1024
        }
        return c
    }

    private static func int(_ s: String?, in range: ClosedRange<Int>) -> Int? {
        guard let s, let v = Int(s.trimmingCharacters(in: .whitespaces)), range.contains(v) else { return nil }
        return v
    }
}

/// The session's periodic keyframe (`MaxKeyFrameIntervalDuration`, `KeyframeIntervalPolicy`): VideoToolbox emits an
/// IDR on its own once the interval has passed since the last keyframe. A refinement train must not run into it.
public enum PeriodicKeyframe {
    /// True when the next periodic keyframe may fall within `horizonUs` from now. `intervalSeconds` 0 = never.
    public static func isDue(nowUs: UInt64, lastKeyframeUs: UInt64, intervalSeconds: Int, horizonUs: UInt64) -> Bool {
        guard intervalSeconds > 0 else { return false }
        let elapsed = nowUs &- lastKeyframeUs
        return elapsed &+ horizonUs >= UInt64(intervalSeconds) * 1_000_000
    }
}

/// Why a refinement train ended.
public enum StillRefineEnd: String, Sendable {
    case converged
    case maxFrames = "max_frames"
    case maxBytes = "max_bytes"
    /// A new capture arrived (motion resumed).
    case cancelled
    /// The output queue was not empty: refinement never adds to a backed-up link.
    case queueBusy = "queue_busy"
    case timeout
    case failed
    /// A keyframe request is pending: the normal capture path serves it, refinement never turns into it.
    case keyframePending = "keyframe_pending"
    /// The session's periodic keyframe is due within a train's length: a refine frame must never be an IDR.
    case keyframeDue = "keyframe_due"
}

/// What one train did (`video ev=refine`).
public struct StillRefineReport: Equatable, Sendable {
    public var frames: Int
    public var bytes: Int
    public var firstBytes: Int
    public var lastBytes: Int
    public var durationUs: UInt64
    public var reason: StillRefineEnd

    public var logFields: String {
        "frames=\(frames) bytes=\(bytes) first_bytes=\(firstBytes) last_bytes=\(lastBytes) "
            + "ms=\(durationUs / 1000) reason=\(reason.rawValue)"
    }
}

/// Decides when the still screen is re-encoded and when that stops (T-253). Pure; `HEVCEncoder` owns one under its
/// lock and does the submitting. Every method takes the host clock and whether the output queue is ready.
///
/// Flow: `noteCapture` (every real capture) arms it; `tick` starts a train once the screen has been still for
/// `stillUs`; each refine frame's encoder output goes to `noteOutput`, which says whether to submit the next frame.
/// A capture in the middle cancels the train (`noteCapture` returns the report).
public struct StillRefinePolicy: Sendable {
    private enum Phase { case idle, armed, running }

    public let config: StillRefineConfig
    /// How long a deferred next frame waits for the queues to drain before the train ends as `queue_busy`.
    public static let queueDrainWaitUs: UInt64 = 500_000
    private var phase = Phase.idle
    private var lastCaptureUs: UInt64 = 0
    private var lastStartUs: UInt64?
    private var submittedAtUs: UInt64 = 0
    private var waitingOutput = false
    /// Packed full colour: the next frame is held back until the queues drain (since when); `tick` retries it.
    private var drainWaitSinceUs: UInt64?
    private var frames = 0
    private var bytes = 0
    private var firstBytes = 0
    private var lastBytes = 0
    private var startedUs: UInt64 = 0
    private var largestFrame = 0
    /// Identifies the running train (0 = none yet). Frames are offered with it and revalidated inside the ordered
    /// offer (`isCurrent`), so a capture that cancelled the train can never be followed by a stale refine frame.
    public private(set) var trainID: UInt64 = 0

    public init(config: StillRefineConfig) { self.config = config }

    public var isRunning: Bool { phase == .running }

    /// The train `id` is still running (not cancelled, ended or replaced).
    public func isCurrent(_ id: UInt64) -> Bool { phase == .running && trainID == id }

    /// A real capture reached the encoder: the screen is moving. Returns the report of a train it cancelled.
    @discardableResult
    public mutating func noteCapture(nowUs: UInt64) -> StillRefineReport? {
        guard config.enabled else { return nil }
        lastCaptureUs = nowUs
        let report = phase == .running ? finish(.cancelled, nowUs: nowUs) : nil
        phase = .armed
        return report
    }

    /// Timer: true = submit the first refine frame now (a train started). Also ends a train whose frame never
    /// produced output (returned in `timedOut`).
    /// `firstFrameEstimate`: expected size of the first refine frame (the last motion frame's size, or a default);
    /// a train whose first frame might not fit `maxBytes` does not start. `keyframeDue`: see `StillRefineEnd.keyframeDue`.
    public mutating func tick(nowUs: UInt64, queueReady: Bool, keyframePending: Bool = false,
                              keyframeDue: Bool = false, firstFrameEstimate: Int = 0)
        -> (start: Bool, timedOut: StillRefineReport?) {
        guard config.enabled else { return (false, nil) }
        switch phase {
        case .idle:
            return (false, nil)
        case .running:
            if let since = drainWaitSinceUs {
                if keyframePending { return (false, finish(.keyframePending, nowUs: nowUs)) }
                if keyframeDue { return (false, finish(.keyframeDue, nowUs: nowUs)) }
                if queueReady {
                    drainWaitSinceUs = nil
                    waitingOutput = true
                    submittedAtUs = nowUs
                    return (true, nil)
                }
                if nowUs &- since >= Self.queueDrainWaitUs { return (false, finish(.queueBusy, nowUs: nowUs)) }
                return (false, nil)
            }
            if waitingOutput, nowUs &- submittedAtUs >= config.timeoutUs {
                return (false, finish(.timeout, nowUs: nowUs))
            }
            return (false, nil)
        case .armed:
            guard nowUs &- lastCaptureUs >= config.stillUs, queueReady, !keyframePending, !keyframeDue,
                  firstFrameEstimate <= config.maxBytes else { return (false, nil) }
            if let last = lastStartUs, nowUs &- last < config.minGapUs { return (false, nil) }
            phase = .running
            lastStartUs = nowUs
            startedUs = nowUs
            submittedAtUs = nowUs
            waitingOutput = true
            frames = 0; bytes = 0; firstBytes = 0; lastBytes = 0; largestFrame = 0
            trainID &+= 1
            return (true, nil)
        }
    }

    /// A refine frame's encoder output (`bytes` of the encoded frame). `submitNext`: submit another refine frame;
    /// `report`: the train ended with this frame.
    ///
    /// `deferQueueBusy` (packed full colour): a not-ready queue does not end the train. The output has just been queued
    /// and the sender may not have drained it yet, so the next frame waits (`tick` retries it) for at most
    /// `queueDrainWaitUs`, then the train ends as `queue_busy`.
    public mutating func noteOutput(bytes frameBytes: Int, nowUs: UInt64, queueReady: Bool, keyframePending: Bool = false,
                                    keyframeDue: Bool = false, deferQueueBusy: Bool = false)
        -> (submitNext: Bool, report: StillRefineReport?) {
        guard phase == .running, waitingOutput else { return (false, nil) }
        waitingOutput = false
        frames += 1
        bytes += frameBytes
        if frames == 1 { firstBytes = frameBytes }
        lastBytes = frameBytes
        largestFrame = max(largestFrame, frameBytes)
        let reason: StillRefineEnd?
        if frameBytes <= config.convergedBytes { reason = .converged }
        else if frames >= config.maxFrames { reason = .maxFrames }
        // Conservative admission: the next frame is assumed as large as the largest one so far, so the ceiling holds
        // unless a frame is bigger than every earlier one (the encoder's size cannot be known beforehand).
        else if bytes + largestFrame > config.maxBytes { reason = .maxBytes }
        else if keyframePending { reason = .keyframePending }
        else if keyframeDue { reason = .keyframeDue }
        else if !queueReady && !deferQueueBusy { reason = .queueBusy }
        else { reason = nil }
        if let reason { return (false, finish(reason, nowUs: nowUs)) }
        if !queueReady {
            drainWaitSinceUs = nowUs
            return (false, nil)
        }
        waitingOutput = true
        submittedAtUs = nowUs
        return (true, nil)
    }

    /// Ends the running train for `reason` (nil when none runs).
    public mutating func end(_ reason: StillRefineEnd, nowUs: UInt64) -> StillRefineReport? {
        guard phase == .running else { return nil }
        return finish(reason, nowUs: nowUs)
    }

    /// The encoder refused a refine frame or produced no output for it.
    public mutating func noteFailure(nowUs: UInt64) -> StillRefineReport? {
        guard phase == .running else { return nil }
        return finish(.failed, nowUs: nowUs)
    }

    /// Ends the running train. Back to `idle` (not armed): the next train needs a new capture.
    private mutating func finish(_ reason: StillRefineEnd, nowUs: UInt64) -> StillRefineReport {
        phase = .idle
        waitingOutput = false
        drainWaitSinceUs = nil
        return StillRefineReport(frames: frames, bytes: bytes, firstBytes: firstBytes, lastBytes: lastBytes,
                                 durationUs: nowUs &- startedUs, reason: reason)
    }
}
