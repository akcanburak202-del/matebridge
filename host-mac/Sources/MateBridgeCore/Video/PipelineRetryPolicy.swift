import Foundation

/// What failed in a running video pipeline (`ev=pipeline_failed kind=`). Carried in the event, so the owner decides on
/// the type and not on the error text (T-289).
public enum PipelineFailureKind: String, Equatable, Sendable {
    /// VideoToolbox: the encoder tripped (`failureLimit` consecutive frame failures) or could not submit a frame.
    case encoder
    /// Anything else: ScreenCaptureKit stopped, the display went away, permission revoked.
    case other
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
/// Pure value logic on the host clock (microseconds); no I/O, no clock reads.
public struct PipelineRetryPolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Rebuild the pipeline with the same settings after `delayUs`; `attempt` counts failures in this window (1...).
        case retry(delayUs: UInt64, attempt: Int)
        /// Re-apply the session's prefs without HDR10 and rebuild as SDR (new `config_id`).
        case fallBackToSDR
        /// The budget of this window is used up; the next video attach (or a later failure outside the window)
        /// decides again.
        case giveUp
    }

    public static let windowUs: UInt64 = 60_000_000
    public static let maxRetries = 3
    public static let baseDelayUs: UInt64 = 1_000_000
    public static let maxDelayUs: UInt64 = 4_000_000

    struct Failure: Equatable, Sendable {
        var atUs: UInt64
        var kind: PipelineFailureKind
    }

    private var failures: [Failure] = []

    public init() {}

    /// Failures currently counted (inside the window as of the last decision).
    public var recentFailureCount: Int { failures.count }

    /// New session (or takeover): a fresh budget.
    public mutating func reset() { failures.removeAll() }

    /// Records a failure of a running pipeline at `nowUs` and says what to do about it. `hdr10` is whether the failed
    /// pipeline ran HDR10.
    public mutating func failed(kind: PipelineFailureKind, hdr10: Bool, nowUs: UInt64) -> Decision {
        failures.removeAll { nowUs > $0.atUs && nowUs - $0.atUs > Self.windowUs }
        let priorEncoderFailure = failures.contains { $0.kind == .encoder }
        failures.append(Failure(atUs: nowUs, kind: kind))
        if hdr10, kind == .encoder, priorEncoderFailure {
            failures.removeAll()  // the SDR pipeline starts with a fresh budget
            return .fallBackToSDR
        }
        let attempt = failures.count
        guard attempt <= Self.maxRetries else { return .giveUp }
        return .retry(delayUs: Self.delay(attempt: attempt), attempt: attempt)
    }

    /// Backoff before rebuild number `attempt` (1-based): 1 s, 2 s, then 4 s.
    public static func delay(attempt: Int) -> UInt64 {
        let shift = UInt64(min(max(attempt - 1, 0), 8))
        return min(baseDelayUs << shift, maxDelayUs)
    }
}
