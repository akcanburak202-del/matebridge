/// Why the video pipeline lost its display in a way that waking the Mac's displays can fix (T-081).
///
/// Measured (NOTES 2026-10-01 ~14:10): while the displays sleep, the running SCStream stops with -3815 and every new
/// `CGVirtualDisplay` comes back nil; a user-activity declaration brings the displays back and the next retry works.
public enum DisplayWakeReason: String, Sendable, Equatable {
    /// SCStream stopped or failed to start with `SCStreamErrorNoCaptureSource` (-3815).
    case captureSourceLost = "capture_source_lost"
    /// `CGVirtualDisplay initWithDescriptor:` returned nil.
    case displayCreateNil = "display_create_nil"

    /// `SCStreamErrorCode.noCaptureSource`.
    public static let screenCaptureNoCaptureSourceCode = -3815

    /// Classifies an error code from `SCStreamErrorDomain` (the caller checks the domain). Other SCK errors (permission,
    /// internal errors) are not caused by display sleep and never wake the display.
    public static func fromScreenCaptureError(code: Int) -> DisplayWakeReason? {
        code == screenCaptureNoCaptureSourceCode ? .captureSourceLost : nil
    }
}

/// Decides when the host declares user activity to wake the displays (T-081). Pure; the IOKit call is elsewhere.
///
/// Only a display loss with a recognised cause during an accepted (encrypted) tablet session wakes, at most once per
/// `minIntervalUs`. Nothing here keeps the display awake: each wake is a one-off "the user is active" declaration that
/// the system honours up to its own display sleep setting. An "episode" runs from the first loss to `recovered()` or
/// `sessionEnded()`; the log line is rate-limited per episode (first wake, a changed reason, or every `logIntervalUs`).
public struct DisplayWakePolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case skip
        /// Declare user activity now; `log` tells whether to write `ev=wake_display` (with `wakes` = count so far).
        case wake(log: Bool, wakes: Int)
    }

    public static let defaultMinIntervalUs: UInt64 = 1_000_000
    public static let defaultLogIntervalUs: UInt64 = 10_000_000

    public let minIntervalUs: UInt64
    public let logIntervalUs: UInt64

    private var lastWakeUs: UInt64?
    private var lastLogUs: UInt64?
    private var lastLoggedReason: DisplayWakeReason?
    /// Wakes in the current episode.
    public private(set) var wakes = 0

    public init(minIntervalUs: UInt64 = DisplayWakePolicy.defaultMinIntervalUs,
                logIntervalUs: UInt64 = DisplayWakePolicy.defaultLogIntervalUs) {
        self.minIntervalUs = minIntervalUs
        self.logIntervalUs = logIntervalUs
    }

    /// The pipeline lost its display (or could not create one). `reason` is nil for causes display sleep does not
    /// explain; `sessionActive` is true only for an accepted session (never for a pending PAIRING or no session).
    public mutating func displayLost(_ reason: DisplayWakeReason?, sessionActive: Bool, now: UInt64) -> Decision {
        guard let reason, sessionActive else { return .skip }
        if let last = lastWakeUs, now >= last, now - last < minIntervalUs { return .skip }
        lastWakeUs = now
        wakes += 1
        let log: Bool
        if lastLoggedReason != reason { log = true }
        else if let at = lastLogUs, now >= at, now - at < logIntervalUs { log = false }
        else { log = true }
        if log {
            lastLoggedReason = reason
            lastLogUs = now
        }
        return .wake(log: log, wakes: wakes)
    }

    /// The display is back (a pipeline started). The next loss starts a new episode and logs again; the rate limit
    /// still applies, so a display that keeps dying cannot cause more than one wake per interval.
    public mutating func recovered() {
        wakes = 0
        lastLoggedReason = nil
        lastLogUs = nil
    }

    /// The session ended (or the host shuts down): the episode is over. The rate limit is kept, so quick session
    /// churn cannot wake more than once per interval either.
    public mutating func sessionEnded() { recovered() }
}
