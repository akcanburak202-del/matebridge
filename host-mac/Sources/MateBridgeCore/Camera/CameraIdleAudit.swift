// When to check whether an app still uses the virtual camera while the tablet camera is being written (decision 0040
// addendum 2, policy C). The check pauses the sink (a visible gap), so it is rare:
// - the Mac had no user input for `idleUs` (and then again every `idleUs` while it stays idle), or
// - the Mac goes to sleep or its display sleeps (`sleeping`).
// Pure and clock-free: the host passes `now` (monotonic microseconds) and the age of the last user input.

public struct CameraIdleAudit: Sendable {
    /// No input for this long, and the spacing of repeated checks while idle.
    public var idleUs: UInt64
    private var lastAuditAt: UInt64?

    public init(idleUs: UInt64 = 600_000_000) { self.idleUs = idleUs }

    /// True once per `idleUs` while the user is idle and a probe can start; the caller then starts the probe.
    public mutating func due(now: UInt64, canProbe: Bool, inputIdleUs: UInt64) -> Bool {
        guard canProbe, inputIdleUs >= idleUs else { return false }
        if let last = lastAuditAt, now < last + idleUs { return false }
        lastAuditAt = now
        return true
    }

    /// The Mac (or its display) is going to sleep: probe now when possible.
    public mutating func sleeping(now: UInt64, canProbe: Bool) -> Bool {
        guard canProbe else { return false }
        lastAuditAt = now
        return true
    }

    /// Earliest instant `due` can become true; nil when no probe can start (the host sets no timer then).
    public func nextDeadline(now: UInt64, canProbe: Bool, inputIdleUs: UInt64) -> UInt64? {
        guard canProbe else { return nil }
        let wake = now + (idleUs > inputIdleUs ? idleUs - inputIdleUs : 0)
        if let last = lastAuditAt { return max(wake, last + idleUs) }
        return wake
    }

    /// Writing stopped or the session changed: the next idle period starts fresh.
    public mutating func reset() { lastAuditAt = nil }
}
