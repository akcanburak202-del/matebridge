/// `CURSOR_PREFS` waiting for the cursor queue: at most one (the newest wins, the planner only needs the last wish) and
/// at most one live wake-up, however many arrive. Scoped to the session boundary: a wake-up belongs to the boundary it
/// was scheduled in (its token), so one that survives a session start or end is stale; it finds the mailbox taken
/// over by the new session's own wake-up and leaves the message to it. Not thread safe: the owner holds a lock.
public struct CursorPrefsMailbox: Sendable {
    private var pending: (session: UInt32, enabled: Bool)?
    /// Changes at every session boundary (`clear`).
    private var boundary = 0
    /// The boundary of the wake-up that is scheduled; nil when none is.
    private var wakeBoundary: Int?

    public init() {}

    /// A prefs message of `session`. Returns the token of a wake-up the caller must schedule (and later pass to `take`),
    /// or nil when a wake-up of this session boundary is already on its way.
    public mutating func post(session: UInt32, enabled: Bool) -> Int? {
        pending = (session, enabled)
        guard wakeBoundary != boundary else { return nil }
        wakeBoundary = boundary
        return boundary
    }

    /// The newest message, for the wake-up with `token`. A stale wake-up (scheduled before the last boundary) gets
    /// nothing and spends nothing: the message belongs to the wake-up of the boundary it was posted in.
    public mutating func take(token: Int) -> (session: UInt32, enabled: Bool)? {
        guard token == boundary else { return nil }
        wakeBoundary = nil
        defer { pending = nil }
        return pending
    }

    /// A session started or ended: what was posted before is void, and wake-ups scheduled so far are stale.
    public mutating func clear() {
        boundary += 1
        pending = nil
    }
}
