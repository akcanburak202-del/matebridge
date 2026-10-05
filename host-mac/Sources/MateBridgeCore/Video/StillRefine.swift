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
    /// (1...60) override; an invalid value keeps the default.
    public static func resolve(env: [String: String], transport: SessionTransport) -> StillRefineConfig {
        var c = StillRefineConfig.disabled
        c.enabled = env["MATEBRIDGE_REFINE"]?.trimmingCharacters(in: .whitespaces) != "0"
        let ms = int(env["MATEBRIDGE_REFINE_MS"], in: stillMsRange) ?? defaultStillMs
        c.stillUs = UInt64(ms) * 1000
        c.maxFrames = int(env["MATEBRIDGE_REFINE_FRAMES"], in: framesRange) ?? defaultMaxFrames
        let kb = int(env["MATEBRIDGE_REFINE_KB"], in: kbRange) ?? (transport == .usb ? usbKB : networkKB)
        c.maxBytes = kb * 1024
        return c
    }

    private static func int(_ s: String?, in range: ClosedRange<Int>) -> Int? {
        guard let s, let v = Int(s.trimmingCharacters(in: .whitespaces)), range.contains(v) else { return nil }
        return v
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
    private var phase = Phase.idle
    private var lastCaptureUs: UInt64 = 0
    private var lastStartUs: UInt64?
    private var submittedAtUs: UInt64 = 0
    private var waitingOutput = false
    private var frames = 0
    private var bytes = 0
    private var firstBytes = 0
    private var lastBytes = 0
    private var startedUs: UInt64 = 0

    public init(config: StillRefineConfig) { self.config = config }

    public var isRunning: Bool { phase == .running }

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
    public mutating func tick(nowUs: UInt64, queueReady: Bool) -> (start: Bool, timedOut: StillRefineReport?) {
        guard config.enabled else { return (false, nil) }
        switch phase {
        case .idle:
            return (false, nil)
        case .running:
            if waitingOutput, nowUs &- submittedAtUs >= config.timeoutUs {
                return (false, finish(.timeout, nowUs: nowUs))
            }
            return (false, nil)
        case .armed:
            guard nowUs &- lastCaptureUs >= config.stillUs, queueReady else { return (false, nil) }
            if let last = lastStartUs, nowUs &- last < config.minGapUs { return (false, nil) }
            phase = .running
            lastStartUs = nowUs
            startedUs = nowUs
            submittedAtUs = nowUs
            waitingOutput = true
            frames = 0; bytes = 0; firstBytes = 0; lastBytes = 0
            return (true, nil)
        }
    }

    /// A refine frame's encoder output (`bytes` of the encoded frame). `submitNext`: submit another refine frame;
    /// `report`: the train ended with this frame.
    public mutating func noteOutput(bytes frameBytes: Int, nowUs: UInt64, queueReady: Bool)
        -> (submitNext: Bool, report: StillRefineReport?) {
        guard phase == .running, waitingOutput else { return (false, nil) }
        waitingOutput = false
        frames += 1
        bytes += frameBytes
        if frames == 1 { firstBytes = frameBytes }
        lastBytes = frameBytes
        let reason: StillRefineEnd?
        if frameBytes <= config.convergedBytes { reason = .converged }
        else if frames >= config.maxFrames { reason = .maxFrames }
        else if bytes >= config.maxBytes { reason = .maxBytes }
        else if !queueReady { reason = .queueBusy }
        else { reason = nil }
        if let reason { return (false, finish(reason, nowUs: nowUs)) }
        waitingOutput = true
        submittedAtUs = nowUs
        return (true, nil)
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
        return StillRefineReport(frames: frames, bytes: bytes, firstBytes: firstBytes, lastBytes: lastBytes,
                                 durationUs: nowUs &- startedUs, reason: reason)
    }
}
