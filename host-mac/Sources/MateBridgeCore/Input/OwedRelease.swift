// Closing events the Mac may not have received, kept until they have been delivered (T-023 review rounds).
//
// The planner clears its own view of what is held the moment it produces a release. That is right for the state
// machine, but the release can still fail to reach the Mac:
//   - Accessibility permission was revoked: macOS drops every posted event silently, so a button-up produced now is
//     gone, and the Mac keeps the button down. Nothing can be posted until the permission is back (an honest limit);
//     the releases are remembered and replayed first thing when it returns, at the next session start and at shutdown.
//   - The poster could not build the event (or the permission check failed at the last moment): the failed closing
//     events are remembered and retried.
// The store is a fixed set of slots (pen up, each button up, pen leave, scroll end), so it cannot grow, and an entry
// never leaves it unposted: once the machine and the planner have cleared their state, this is the only thing that
// still knows the Mac holds something, so giving up would leave it held for good. An entry leaves the store only by
// being posted, or by being replaced by a newer closing event for the same slot.
//
// Retries back off instead of stopping: the first `slowAfterAttempts` replays are `retryIntervalUs` apart, later ones
// `slowIntervalUs` apart (the crossing is reported once, per slot). Waiting for a missing permission costs no attempts.
//
// While anything is owed (or a replay has been handed out and not yet confirmed), `isBlocking` is true and the
// pipeline keeps new input from opening anything on the Mac (see `InputPipeline`): a newer press must never be
// overtaken by an older release that is retried later.

public struct OwedRelease: Equatable, Sendable {
    /// Replays at the normal spacing before the retry cadence drops to `slowIntervalUs`.
    public static let slowAfterAttempts = 6
    public static let retryIntervalUs: UInt64 = 250_000
    public static let slowIntervalUs: UInt64 = 1_000_000

    /// What a closing event closes. The raw order is the order releases are replayed in (the state machine's order).
    enum Slot: Hashable, Sendable {
        case penUp
        case button(MouseButton)
        case penLeave
        case scrollEnd

        init?(_ event: MacEvent) {
            switch event {
            case .tabletPoint(let p) where p.kind == .up: self = .penUp
            case .tabletProximity(_, let entering) where !entering: self = .penLeave
            case .mouse(let m) where m.kind == .up: self = .button(m.button)
            case .scroll(let s) where s.phase == .ended || s.phase == .cancelled: self = .scrollEnd
            default: return nil
            }
        }

        /// The slot whose release undoes this OPENING event (nil for any other event).
        init?(closing opening: MacEvent) {
            switch opening {
            case .tabletProximity(_, let entering) where entering: self = .penLeave
            case .tabletPoint(let p) where p.kind == .down: self = .penUp
            case .mouse(let m) where m.kind == .down: self = .button(m.button)
            case .scroll(let s) where s.phase == .began: self = .scrollEnd
            default: return nil
            }
        }

        var order: Int {
            switch self {
            case .penUp: 0
            case .button(let b): b == .left ? 1 : 3 + Int(b.rawValue)
            case .penLeave: 2
            case .scrollEnd: 10
            }
        }
    }

    private struct Entry: Equatable, Sendable {
        var event: MacEvent
        var attempts = 0
        var notBefore: UInt64 = 0
    }

    private var entries: [Slot: Entry] = [:]
    /// What the last `replay` handed out. If the caller reports it failed (`owe`), the attempt count carries over;
    /// otherwise the next `replay` forgets it: no failure report means it was posted.
    private var lastReplay: [Slot: Entry] = [:]
    /// How many times an entry has dropped to the slow retry cadence since the start (one per slot and cycle).
    public private(set) var slowed = 0

    public init() {}

    /// Nothing is owed.
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// New input must not open anything on the Mac: something is owed, or a replay went out and nobody has confirmed
    /// yet that it was posted (the next call to `replay` confirms it by the absence of a failure report).
    public var isBlocking: Bool { !entries.isEmpty || !lastReplay.isEmpty }

    /// When `replay` will next emit something (0: an entry is waiting for the permission and is due at once when it
    /// returns), or nil when nothing is owed. Only entries `replay` would really emit count: a pen leave is withheld
    /// while a pen up is owed, so it is due no earlier than that up. A `replay` at this time therefore always attempts
    /// at least one event, and a time at which `replay` just withheld everything is always before it (the host's retry
    /// timer must never be scheduled for a moment that is already past).
    public var nextRetryAt: UInt64? {
        let upAt = entries[.penUp]?.notBefore
        return entries.map { slot, entry in
            slot == .penLeave ? Swift.max(entry.notBefore, upAt ?? 0) : entry.notBefore
        }.min()
    }

    /// A pen up is owed. A pen leave must not overtake it (the Mac would see the pen leave while it still touches).
    public var owesPenUp: Bool { entries[.penUp] != nil }

    /// The closing events owed, in replay order (for tests and diagnostics).
    var owedEvents: [MacEvent] {
        entries.sorted { $0.key.order < $1.key.order }.map(\.value.event)
    }

    /// How long to wait before the next replay of an entry that has had `attempts` replays.
    static func interval(afterAttempts attempts: Int) -> UInt64 {
        attempts >= slowAfterAttempts ? slowIntervalUs : retryIntervalUs
    }

    /// Remembers closing events that may not have reached the Mac. Other events are ignored.
    /// - Parameter countsAsAttempt: true when the poster failed to post them (they will be retried, `retryIntervalUs`
    ///   apart at first and `slowIntervalUs` apart later); false when they could not be posted for lack of permission
    ///   (no attempt is used up, they wait for the permission).
    public mutating func owe(_ events: [MacEvent], now: UInt64, countsAsAttempt: Bool) {
        for event in events where event.isClosing {
            guard let slot = Slot(event) else { continue }
            var entry: Entry
            var replayFailed = false
            if let existing = entries[slot] {
                entry = existing
                entry.event = event
            } else if var replayed = lastReplay[slot] {
                // A replay of this slot failed: its attempt only counts if the failure was the poster's.
                if !countsAsAttempt { replayed.attempts = Swift.max(0, replayed.attempts - 1) }
                replayed.event = event
                entry = replayed
                replayFailed = countsAsAttempt
            } else {
                entry = Entry(event: event)
            }
            lastReplay[slot] = nil
            // The sixth failed replay is where the cadence drops to the slow one; reported once per slot and cycle.
            if replayFailed, entry.attempts == Self.slowAfterAttempts { slowed += 1 }
            entry.notBefore = countsAsAttempt ? now &+ Self.interval(afterAttempts: entry.attempts) : 0
            entries[slot] = entry
        }
    }

    /// Everything the last `replay` handed out and nobody reported failed was posted: forget it. Every entry point of
    /// the pipeline calls this first, so the input gate reopens as soon as the owed set is empty and confirmed.
    public mutating func confirmPosted() {
        lastReplay.removeAll()
    }

    /// The owed events that are due, in release order, ready to post, positioned on `geometry` when there is one.
    /// They are handed out, not dropped: if posting them fails the caller must `owe` them again (and until it does,
    /// or until the next `replay`, `isBlocking` stays true). `force` ignores the retry spacing (a release trigger, a
    /// session start, shutdown).
    public mutating func replay(now: UInt64, force: Bool, geometry: DisplayGeometry?) -> [MacEvent] {
        confirmPosted()
        var due: [(order: Int, event: MacEvent)] = []
        // A pen leave is only due together with (or after) the pen up that precedes it.
        let leaveWaits = entries[.penUp].map { !(force || now >= $0.notBefore) } ?? false
        for (slot, var entry) in entries where (force || now >= entry.notBefore) && !(slot == .penLeave && leaveWaits) {
            entries[slot] = nil
            entry.attempts += 1
            lastReplay[slot] = entry
            due.append((slot.order, entry.event.placed(on: geometry)))
        }
        due.sort { $0.order < $1.order }
        return due.map(\.event)
    }
}
