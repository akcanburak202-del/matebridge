/// `CURSOR_PREFS` waiting for the cursor queue: at most one (the newest wins, the planner only needs the last wish) and
/// at most one wake-up scheduled, however many arrive; scoped to a session, so one that was posted before a session
/// boundary is never applied after it. Not thread safe: the owner holds a lock around it.
public struct CursorPrefsMailbox: Sendable {
    private var pending: (session: UInt32, enabled: Bool)?
    private var wakeScheduled = false

    public init() {}

    /// A prefs message of `session`. True when the caller must schedule one wake-up that calls `take()`.
    public mutating func post(session: UInt32, enabled: Bool) -> Bool {
        pending = (session, enabled)
        guard !wakeScheduled else { return false }
        wakeScheduled = true
        return true
    }

    /// The newest message; the wake-up is spent.
    public mutating func take() -> (session: UInt32, enabled: Bool)? {
        wakeScheduled = false
        defer { pending = nil }
        return pending
    }

    /// A session started or ended: what was posted before is void. A wake-up already scheduled stays (it finds nothing).
    public mutating func clear() { pending = nil }
}
