/// When and how fast the host ends its sessions for a system sleep (T-132, PROTOCOL.md section 4 `BYE` reason
/// HOST_SLEEP). Pure: the session server asks it from the power observer's queue, before the sleep is acknowledged.
///
/// Measured (NOTES 2026-10-02 ~14:45): with the session left open the TCP connections lived through the sleep, and
/// the tablet's PINGs and video reconnect attempts dark-woke the Mac over Wi-Fi every ~45 s.
public enum HostSleep {
    /// Longest time the sleep acknowledgement (`IOAllowPowerChange`) waits for the BYE to be sent and the connections
    /// to close. MateBridge never delays sleep beyond this, and acknowledges even if the flush did not finish.
    public static let budgetUs: UInt64 = 300_000
    /// Kept free at the end of the budget: a lingering control socket is cut this long before the acknowledgement, so
    /// its close (a dispatch timer, which does not run while asleep) still happens while the Mac is awake.
    public static let lingerMarginUs: UInt64 = 50_000

    /// Only `kIOMessageSystemWillSleep` ends sessions: it is final (also for `pmset sleepnow`, Apple menu > Sleep),
    /// whereas an idle sleep announced by `kIOMessageCanSystemSleep` may still be cancelled (`will_not_sleep`).
    public static func endsSessions(_ event: PowerEvent) -> Bool {
        event == .willSleep
    }

    /// The deadline of the whole sleep sequence that started at `startUs`.
    public static func deadlineUs(startUs: UInt64) -> UInt64 {
        startUs + budgetUs
    }

    /// How long a closing control socket may still linger (flush its BYE, wait for the peer's FIN) when it is closed
    /// at `nowUs`: what is left of the budget minus `lingerMarginUs`, never negative.
    public static func lingerUs(startUs: UInt64, nowUs: UInt64) -> UInt64 {
        let end = deadlineUs(startUs: startUs)
        guard nowUs < end else { return 0 }
        let left = end - nowUs
        return left > lingerMarginUs ? left - lingerMarginUs : 0
    }

    /// Time left until the deadline at `nowUs` (0 once it passed).
    public static func remainingUs(startUs: UInt64, nowUs: UInt64) -> UInt64 {
        let end = deadlineUs(startUs: startUs)
        return nowUs < end ? end - nowUs : 0
    }

    /// When control connections that are still lingering (closed earlier, or closed by the sleep and not yet done)
    /// are cut: `lingerMarginUs` before the deadline, so the cut happens while the Mac is still awake and the last
    /// stretch of the budget is left for the other participants (input release, audio teardown) to report.
    public static func cutDeadlineUs(startUs: UInt64) -> UInt64 {
        deadlineUs(startUs: startUs) - lingerMarginUs
    }

    /// Time left until the cut point at `nowUs` (0 once it passed).
    public static func remainingToCutUs(startUs: UInt64, nowUs: UInt64) -> UInt64 {
        let cut = cutDeadlineUs(startUs: startUs)
        return nowUs < cut ? cut - nowUs : 0
    }
}

/// Which host-sleep participants (input release, audio teardown) have reported done (T-132). Pure; the session
/// server keeps one per sleep under a lock and logs it with the sleep acknowledgement.
public struct HostSleepProgress: Sendable, Equatable {
    /// Participant names in registration order (stable log order).
    public let names: [String]
    public private(set) var done: Set<String> = []

    public init(names: [String]) { self.names = names }

    /// Marks `name` done. Unknown names and repeats are ignored.
    public mutating func finished(_ name: String) {
        if names.contains(name) { done.insert(name) }
    }

    public var isComplete: Bool { names.allSatisfy(done.contains) }

    /// `input=done audio=pending`, in registration order; empty without participants. A name occurring twice is
    /// listed once.
    public var logFields: String {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
            .map { "\($0)=\(done.contains($0) ? "done" : "pending")" }
            .joined(separator: " ")
    }
}
