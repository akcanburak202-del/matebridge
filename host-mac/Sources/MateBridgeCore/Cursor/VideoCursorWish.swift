/// The bookkeeping behind "is the Mac's cursor in the video" (decision 0036): what the capture should do, and which
/// requests may still change it. Pure; the host's `VideoCursorSwitch` holds one under a lock and applies the tickets.
///
/// - The wish is "cursor in the video" (`wantsCursor`) unless a live session has hidden it. A capture that starts
///   later starts with the wish; a failed change never leaves the wish on "hidden": the safe state is the cursor in the
///   video, and a failed *show* is retried (`retryDelayUs`) until it works or something newer asks for something else.
/// - A request carries the *generation* of the session that made it. `reset()` (a session ended) starts a new
///   generation, so a request still on its way from the ended session (a hide waiting behind the capture's
///   `updateConfiguration`) is refused when it arrives and can never take the cursor out of the video again.
/// - Requests are applied one at a time; a ticket is only applied while it is the newest (`begin`), so a request that a
///   newer one overtook is skipped.
public struct VideoCursorWish: Sendable {
    public struct Ticket: Equatable, Sendable {
        public var epoch: Int
        public var generation: Int
        /// The cursor in the video (true) or out of it (false).
        public var shows: Bool
    }

    /// First retry of a failed show, doubling up to `maxRetryDelayUs`.
    public static let firstRetryDelayUs: UInt64 = 250_000
    public static let maxRetryDelayUs: UInt64 = 8_000_000

    public private(set) var wantsCursor = true
    public private(set) var generation = 0
    private var latestEpoch = 0

    public init() {}

    /// A request from the session of `generation`; nil when that session is over (a stale request). Pass nil for a
    /// request of the host itself (a capture that started with another setting than the wish).
    public mutating func request(shows: Bool, generation: Int?) -> Ticket? {
        if let generation, generation != self.generation { return nil }
        latestEpoch += 1
        return Ticket(epoch: latestEpoch, generation: self.generation, shows: shows)
    }

    /// A session ended: everything on its way is void, and the cursor goes back into the video (the wish is back at
    /// once; the returned ticket brings a running capture along).
    public mutating func reset() -> Ticket {
        generation += 1
        latestEpoch += 1
        wantsCursor = true
        return Ticket(epoch: latestEpoch, generation: generation, shows: true)
    }

    /// The moment a ticket is about to be applied: true when it is still the newest and of the live generation (the wish
    /// then takes its value); false when it was overtaken or its session is over.
    public mutating func begin(_ ticket: Ticket) -> Bool {
        guard ticket.epoch == latestEpoch, ticket.generation == generation else { return false }
        wantsCursor = ticket.shows
        return true
    }

    /// The capture refused the ticket's change. The wish goes back to "cursor in the video" (what the capture still
    /// shows after a failed hide, and what a failed show is still owed). True when the change is to be retried: the
    /// ticket was a show that is still the newest.
    public mutating func failed(_ ticket: Ticket) -> Bool {
        guard ticket.epoch == latestEpoch, ticket.generation == generation else { return false }
        wantsCursor = true
        return ticket.shows
    }

    /// The ticket for a retry of a failed show; nil when something newer happened meanwhile.
    public mutating func retry(after failed: Ticket) -> Ticket? {
        guard failed.shows, failed.epoch == latestEpoch, failed.generation == generation else { return nil }
        latestEpoch += 1
        return Ticket(epoch: latestEpoch, generation: generation, shows: true)
    }

    /// Delay before retry number `attempt` (0 = the first): 0.25 s, 0.5 s, 1 s ... capped at 8 s.
    public static func retryDelayUs(attempt: Int) -> UInt64 {
        let shift = min(max(attempt, 0), 16)
        return min(firstRetryDelayUs << UInt64(shift), maxRetryDelayUs)
    }
}
