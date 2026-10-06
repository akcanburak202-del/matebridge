/// Whether the video shows the Mac's cursor (decision 0036), as a reconciler: the host states what it DESIRES and one loop
/// drives the running capture to it. Pure; the host's `VideoCursorSwitch` holds one under a lock and runs the loop.
///
/// State is only the desire, `(shows, generation)`, latest wins. Nothing queues: a change replaces the desire and the
/// loop compares it with what the capture has now (`plan`). So a capture that attaches later, a hide that failed, a reset
/// and a request from the tablet are all the same thing, a different desire or a different capture, and the answer is
/// always "do one change toward the desire, or stop".
///
/// - Default and fallback is "cursor in the video" (`shows = true`). A session end (`reset`) starts a new generation and
///   puts the desire back there; a request of an older generation is ignored (a hide still on its way from an ended
///   session can never hide the next one's cursor).
/// - A failed change is retried with a bounded backoff (0.25 s doubling to 8 s) until it works or the desire changes
///   (any change restarts the count). The desire is NOT changed by a failure: the loop keeps trying toward it, and the
///   host decides what a failure means (`failed` reports it once per desire).
public struct VideoCursorReconciler: Sendable {
    /// What happened to a desire, for the host's cursor flow.
    public struct Outcome: Equatable, Sendable {
        public var generation: Int
        /// The desire this is about.
        public var shows: Bool
        /// True: the capture has what was asked. False: ScreenCaptureKit refused (reported once per desire).
        public var ok: Bool
    }

    /// What the loop does next.
    public enum Step: Equatable, Sendable {
        /// Nothing to change (no capture, or it already has the desire): stop the loop, tell the host if it waits.
        case done(Outcome?)
        /// Change the capture to `shows`.
        case apply(shows: Bool)
    }

    public static let firstRetryDelayUs: UInt64 = 250_000
    public static let maxRetryDelayUs: UInt64 = 8_000_000

    public private(set) var desiredShows = true
    public private(set) var generation = 0
    /// A request is waiting for its outcome.
    private var awaitingOutcome = false
    private var failureReported = false
    private var failures = 0

    public init() {}

    /// The session of `generation` wants the cursor in (`true`) or out of (`false`) the video. False when that session
    /// is over (the request is ignored).
    public mutating func request(shows: Bool, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        changeDesire(shows)
        awaitingOutcome = true
        return true
    }

    /// A session ended: the cursor goes back into the video, a new generation starts, nothing waits any more.
    public mutating func reset() {
        generation += 1
        changeDesire(true)
        awaitingOutcome = false
    }

    /// The capture changed (one attached): start counting failures again.
    public mutating func captureChanged() { failures = 0 }

    /// The loop's next move, given what the current capture shows now (`nil`: no capture runs; the next one starts with
    /// the desire).
    public mutating func plan(actualShows: Bool?) -> Step {
        guard let actualShows, actualShows != desiredShows else {
            defer { awaitingOutcome = false }
            return .done(awaitingOutcome ? Outcome(generation: generation, shows: desiredShows, ok: true) : nil)
        }
        return .apply(shows: desiredShows)
    }

    /// A change to `attempted` worked.
    public mutating func succeeded() { failures = 0 }

    /// A change to `attempted` was refused. `onCurrentCapture`: the capture it was for is still the running one. Returns
    /// the outcome to report (once per desire) and how long to wait before the next try (0 when the desire moved on or
    /// the capture was replaced: the loop just plans again).
    public mutating func failed(attempted: Bool, onCurrentCapture: Bool) -> (outcome: Outcome?, delayUs: UInt64) {
        guard attempted == desiredShows, onCurrentCapture else { return (nil, 0) }
        let delay = Self.retryDelayUs(attempt: failures)
        failures += 1
        guard !failureReported else { return (nil, delay) }
        failureReported = true
        awaitingOutcome = false
        return (Outcome(generation: generation, shows: desiredShows, ok: false), delay)
    }

    /// Delay before retry number `attempt` (0 = the first): 0.25 s, 0.5 s, 1 s ... capped at 8 s.
    public static func retryDelayUs(attempt: Int) -> UInt64 {
        let shift = min(max(attempt, 0), 16)
        return min(firstRetryDelayUs << UInt64(shift), maxRetryDelayUs)
    }

    private mutating func changeDesire(_ shows: Bool) {
        desiredShows = shows
        failureReported = false
        failures = 0
    }
}
