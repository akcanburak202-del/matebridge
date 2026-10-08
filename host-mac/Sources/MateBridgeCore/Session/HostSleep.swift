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

/// The input gate that is set while the Mac is going to sleep (T-299): after the sleep release-all, nothing may OPEN
/// again (key down, mouse or pen down, pen proximity enter, scroll or pinch begin), whatever session still delivers
/// it, because a sleep acknowledged with a key held cannot be undone. Closing and moving events pass. Pure; the input
/// controller applies it to what the pipeline produced, hands `dropped` to `InputPipeline.postFailed` (the shadow state
/// forgets them) and releases again so the machine does not believe in what was never posted.
public struct HostSleepInputGate: Sendable, Equatable {
    // MARK: Gate state (pure; the clock is passed in)

    /// Awake time (monotonic uptime that does not advance while the Mac sleeps) after which a gate that never saw its
    /// wake expires on its own: the tablet is the Mac's only input, so a cancelled or missed sleep must not block it.
    /// One policy for the input gate and the audio tap.
    public static let windowNs: UInt64 = 30_000_000_000

    private var closedAtNs: UInt64?

    /// T-308: sleep generation. Bumped by every `set`, so a wake job queued for an earlier sleep can tell that a newer
    /// sleep has re-set the gate since (`wake(ifGeneration:)`).
    public private(set) var generation: UInt64 = 0

    public init() {}

    /// The gate is set (closed or not yet noticed as expired).
    public var isSet: Bool { closedAtNs != nil }

    /// Closes the gate at `awakeNs` (the sleep participant, before its release-all). Setting again restarts the window.
    public mutating func set(awakeNs: UInt64) {
        closedAtNs = awakeNs
        generation &+= 1
    }

    /// True while openings must be dropped: set, and fewer than `windowNs` of awake time have passed. A session start
    /// does NOT clear it: a paired client may still connect between the release and the real sleep.
    public func isClosed(atAwakeNs now: UInt64) -> Bool {
        guard let at = closedAtNs else { return false }
        return now &- at < Self.windowNs
    }

    /// Confirmed wake. True when the gate was set (now cleared).
    public mutating func wake() -> Bool {
        defer { closedAtNs = nil }
        return closedAtNs != nil
    }

    /// T-308: wake that belongs to the sleep numbered `generation` (read when the wake was noticed). Does nothing when a
    /// newer sleep has set the gate since: that sleep's gate stays closed. True when the gate was set and is now cleared.
    public mutating func wake(ifGeneration generation: UInt64) -> Bool {
        guard generation == self.generation else { return false }
        return wake()
    }

    /// Clears a gate whose window ran out. True when it did.
    public mutating func expireIfDue(atAwakeNs now: UInt64) -> Bool {
        guard closedAtNs != nil, !isClosed(atAwakeNs: now) else { return false }
        closedAtNs = nil
        return true
    }

    /// Awake time left until expiry at `now` (0 when not set or due).
    public func remainingNs(atAwakeNs now: UInt64) -> UInt64 {
        guard let at = closedAtNs else { return 0 }
        let used = now &- at
        return used < Self.windowNs ? Self.windowNs - used : 0
    }

    // MARK: Event classification

    /// True for the events that start something that has to be closed later.
    public static func isOpening(_ event: MacEvent) -> Bool {
        switch event {
        case .tabletProximity(_, let entering): entering
        case .tabletPoint(let p): p.kind == .down
        case .mouse(let m): m.kind == .down
        case .scroll(let s): s.phase == .began
        case .magnify(let g): g.phase == .began
        case .key(let k): k.kind == .keyDown || k.kind == .modifierDown
        case .capsLock: false
        }
    }

    /// `pass` keeps the order of the events that may go on to the poster.
    public static func split(_ events: [MacEvent]) -> (pass: [MacEvent], dropped: [MacEvent]) {
        var pass: [MacEvent] = [], dropped: [MacEvent] = []
        for e in events { if isOpening(e) { dropped.append(e) } else { pass.append(e) } }
        return (pass, dropped)
    }
}
