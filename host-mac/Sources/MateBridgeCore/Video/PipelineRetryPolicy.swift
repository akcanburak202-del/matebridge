import Foundation

/// What failed in a running video pipeline (`ev=pipeline_failed kind=`). Carried in the event, so the owner decides on
/// the type and not on the error text (T-289).
public enum PipelineFailureKind: String, Equatable, Sendable {
    /// VideoToolbox: the encoder tripped (`failureLimit` consecutive frame failures) or could not submit a frame.
    case encoder
    /// Anything else: ScreenCaptureKit stopped, the display went away, permission revoked.
    case other
    /// `createPipeline` failed to start (display, capture or encoder setup) even after its own fallbacks (T-293).
    /// Never a running pipeline, so it never counts as a lazy success.
    case start
}

/// Bounded recovery after a running pipeline died (T-289, astra review 2026-10-07 finding 3). It replaces the
/// session-wide `pipelineRetried` flag, which allowed exactly one rebuild per session and never fell back to SDR:
///
/// - at most `maxRetries` rebuilds inside a sliding `windowUs`, with an exponential backoff
///   (`baseDelayUs`, doubling, capped at `maxDelayUs`); the next failure inside the window gives up (no endless loop).
///   A pipeline that ran longer than the window starts a fresh budget;
/// - an HDR10 pipeline whose encoder fails a second time inside the window falls back to SDR (decision 0032,
///   PROTOCOL.md 0x05: `hdr_fallback`) instead of being rebuilt with the settings that just failed twice.
///
/// T-293, the circuit breaker (T-291 design note): after `.giveUp` the policy stays **open**. `admit(nowUs:)`, asked by
/// `onVideoAttached` before it builds a missing pipeline, refuses until the wait is over (10, 20, then 30 s, capped);
/// the first attempt after that is a **probe**, and a probe that fails opens the next step. There are no timers. Success
/// is lazy: a pipeline that ran at least `successUs` when it fails or is stopped clears the history and the ladder.
/// Not reset by a new session of the same device (the tablet's own recovery re-establishes sessions every ~6 s);
/// reset by another device (takeover, `sessionStarted(device:)`), a Mac wake and a stream prefs/mode change (`reset()`).
///
/// Pure value logic on the host clock (microseconds); no I/O, no clock reads.
public struct PipelineRetryPolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Rebuild the pipeline with the same settings after `delayUs`; `attempt` counts failures in this window (1...).
        case retry(delayUs: UInt64, attempt: Int)
        /// Re-apply the session's prefs without HDR10 and rebuild as SDR (new `config_id`).
        case fallBackToSDR
        /// The budget of this window is used up (or a probe failed): no rebuild is scheduled and the breaker is open.
        case giveUp
    }

    /// Answer of `admit(nowUs:)`.
    public enum Admission: Equatable, Sendable {
        case build
        /// The breaker is open: close the video connection at once, build nothing. `remainingUs` until the next probe.
        case refuse(remainingUs: UInt64)
    }

    public enum BreakerState: String, Equatable, Sendable {
        case closed, open, probe
    }

    /// What `ev=pipeline_breaker` reports; the owner logs when it changes.
    public struct BreakerSnapshot: Equatable, Sendable {
        public var state: BreakerState
        /// Ladder step: 0 = closed, 1...3 = 10 s, 20 s, 30 s.
        public var level: Int
        public var waitUs: UInt64
    }

    public static let windowUs: UInt64 = 60_000_000
    public static let maxRetries = 3
    public static let baseDelayUs: UInt64 = 1_000_000
    public static let maxDelayUs: UInt64 = 4_000_000
    /// A pipeline that ran this long before it failed or was stopped counts as a success (lazy, no timer).
    public static let successUs: UInt64 = 10_000_000
    public static let maxBreakerLevel = 3
    /// Every refusal is counted; the owner logs the first and every `refusalLogEvery`-th.
    public static let refusalLogEvery = 10

    struct Failure: Equatable, Sendable {
        var atUs: UInt64
        var kind: PipelineFailureKind
        /// The failed pipeline ran HDR10: only HDR10 encoder failures count toward the SDR fallback.
        var hdr10: Bool
    }

    private var failures: [Failure] = []
    private var openUntilUs: UInt64?
    private var probing = false
    private var level = 0
    private var builtAtUs: UInt64?
    private var device: DeviceID?
    /// Refusals since the breaker opened.
    public private(set) var refusals = 0

    public init() {}

    public var breaker: BreakerSnapshot {
        let state: BreakerState = probing ? .probe : (openUntilUs != nil ? .open : .closed)
        return BreakerSnapshot(state: state, level: level, waitUs: Self.breakerWait(level: level))
    }

    /// Wait of ladder step `level` (1-based): 10 s, 20 s, 30 s (capped); 0 for the closed step.
    public static func breakerWait(level: Int) -> UInt64 {
        guard level > 0 else { return 0 }
        return UInt64(min(level, maxBreakerLevel)) * 10_000_000
    }

    /// Whether refusal number `n` (1-based) is logged: the first and every `refusalLogEvery`-th.
    public static func logsRefusal(_ n: Int) -> Bool { n == 1 || n % refusalLogEvery == 0 }

    /// Failures currently counted (inside the window as of the last decision).
    public var recentFailureCount: Int { failures.count }

    /// A fresh budget and a closed breaker: Mac wake, or a stream prefs/mode change. (Not a new session of the same
    /// device, see `sessionStarted(device:)`.) A running pipeline's start time is kept.
    public mutating func reset() {
        failures.removeAll()
        clearBreaker()
    }

    /// A session started. Another device than the last one (takeover) gets a fresh budget; the same device keeps the
    /// history and the breaker, so the tablet's own session renewal cannot defeat them.
    public mutating func sessionStarted(device newDevice: DeviceID?) {
        if newDevice != device { reset() }
        device = newDevice
    }

    /// A pipeline was started successfully at `nowUs`.
    public mutating func built(nowUs: UInt64) { builtAtUs = nowUs }

    /// The pipeline was stopped on purpose (park, reconfigure, shutdown): if it had run long enough, that is a success.
    public mutating func stopped(nowUs: UInt64) {
        settleIfStable(nowUs: nowUs)
        builtAtUs = nil
    }

    /// `onVideoAttached` wants to build a missing pipeline. While the breaker is open: `.refuse`. Once the wait is
    /// over the breaker turns to probe and the attempt is allowed.
    public mutating func admit(nowUs: UInt64) -> Admission {
        guard let until = openUntilUs else { return .build }
        if nowUs >= until {
            openUntilUs = nil
            probing = true
            return .build
        }
        refusals += 1
        return .refuse(remainingUs: until - nowUs)
    }

    private mutating func clearBreaker() {
        openUntilUs = nil
        probing = false
        level = 0
        refusals = 0
    }

    private mutating func openBreaker(nowUs: UInt64) {
        level = min(level + 1, Self.maxBreakerLevel)
        openUntilUs = nowUs + Self.breakerWait(level: level)
        probing = false
        refusals = 0
    }

    private mutating func settleIfStable(nowUs: UInt64) {
        guard let built = builtAtUs, nowUs >= built, nowUs - built >= Self.successUs else { return }
        failures.removeAll()
        clearBreaker()
    }

    /// Records a failure of a running pipeline at `nowUs` and says what to do about it. `hdr10` is whether the failed
    /// pipeline ran HDR10.
    public mutating func failed(kind: PipelineFailureKind, hdr10: Bool, nowUs: UInt64) -> Decision {
        if kind != .start { settleIfStable(nowUs: nowUs) }
        builtAtUs = nil
        prune(nowUs: nowUs)
        let priorHDREncoderFailure = failures.contains { $0.kind == .encoder && $0.hdr10 }
        failures.append(Failure(atUs: nowUs, kind: kind, hdr10: hdr10))
        if hdr10, kind == .encoder, priorHDREncoderFailure {
            failures.removeAll()  // the SDR pipeline starts with a fresh budget
            clearBreaker()
            return .fallBackToSDR
        }
        if probing {  // the probe failed: next step of the ladder, no timer retry
            openBreaker(nowUs: nowUs)
            return .giveUp
        }
        let attempt = failures.count
        guard attempt <= Self.maxRetries else {
            openBreaker(nowUs: nowUs)
            return .giveUp
        }
        return .retry(delayUs: Self.delay(attempt: attempt), attempt: attempt)
    }

    private mutating func prune(nowUs: UInt64) {
        failures.removeAll { nowUs > $0.atUs && nowUs - $0.atUs > Self.windowUs }
    }

    /// Backoff before rebuild number `attempt` (1-based): 1 s, 2 s, then 4 s.
    public static func delay(attempt: Int) -> UInt64 {
        let shift = UInt64(min(max(attempt - 1, 0), 8))
        return min(baseDelayUs << shift, maxDelayUs)
    }
}
