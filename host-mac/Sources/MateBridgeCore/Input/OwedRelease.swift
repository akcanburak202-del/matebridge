// Closing events the Mac may not have received, kept until they have been delivered (T-023 review round).
//
// The planner clears its own view of what is held the moment it produces a release. That is right for the state
// machine, but the release can still fail to reach the Mac:
//   - Accessibility permission was revoked: macOS drops every posted event silently, so a button-up produced now is
//     gone, and the Mac keeps the button down. Nothing can be posted until the permission is back (an honest limit);
//     the releases are remembered and replayed first thing when it returns, at the next session start and at shutdown.
//   - The poster could not build the event (or the permission check failed at the last moment): the failed closing
//     events are remembered and retried.
// The store is a fixed set of slots (pen up, each button up, pen leave, scroll end), so it cannot grow. Retries are
// bounded: a slot is tried at most `maxAttempts` times, at least `retryIntervalUs` apart, then given up (and counted,
// so the host can log it). Waiting for a missing permission costs no attempts.

public struct OwedRelease: Equatable, Sendable {
    public static let maxAttempts = 6
    public static let retryIntervalUs: UInt64 = 250_000

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
    /// otherwise it is forgotten by the next `replay`.
    private var lastReplay: [Slot: Entry] = [:]
    /// How many slots were given up on since the start.
    public private(set) var gaveUp = 0

    public init() {}

    /// Nothing is owed.
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// The closing events owed, in replay order (for tests and diagnostics).
    var owedEvents: [MacEvent] {
        entries.sorted { $0.key.order < $1.key.order }.map(\.value.event)
    }

    /// Remembers closing events that may not have reached the Mac. Other events are ignored.
    /// - Parameter countsAsAttempt: true when the poster failed to post them (they will be retried, at most
    ///   `maxAttempts` times, `retryIntervalUs` apart); false when they could not be posted for lack of permission
    ///   (no attempt is used up, they wait for the permission).
    public mutating func owe(_ events: [MacEvent], now: UInt64, countsAsAttempt: Bool) {
        for event in events where event.isClosing {
            guard let slot = Slot(event) else { continue }
            var entry: Entry
            if let existing = entries[slot] {
                entry = existing
                entry.event = event
            } else if var replayed = lastReplay[slot] {
                // A replay of this slot failed: its attempt only counts if the failure was the poster's.
                if !countsAsAttempt { replayed.attempts = Swift.max(0, replayed.attempts - 1) }
                replayed.event = event
                entry = replayed
            } else {
                entry = Entry(event: event)
            }
            lastReplay[slot] = nil
            entry.notBefore = countsAsAttempt ? now &+ Self.retryIntervalUs : 0
            entries[slot] = entry
        }
    }

    /// The owed events that are due, in release order, ready to post, positioned on `geometry` when there is one.
    /// They are removed from the store; if posting them fails the caller must `owe` them again. `force` ignores the
    /// retry interval (a release trigger, a session start, shutdown).
    public mutating func replay(now: UInt64, force: Bool, geometry: DisplayGeometry?) -> (events: [MacEvent], gaveUp: Int) {
        lastReplay.removeAll()  // what the previous replay handed out, unreported, was posted
        var due: [(order: Int, event: MacEvent)] = []
        var dropped = 0
        for (slot, var entry) in entries where force || now >= entry.notBefore {
            entries[slot] = nil
            if entry.attempts >= Self.maxAttempts {
                dropped += 1
                gaveUp += 1
                continue
            }
            entry.attempts += 1
            lastReplay[slot] = entry
            due.append((slot.order, entry.event.placed(on: geometry)))
        }
        due.sort { $0.order < $1.order }
        return (due.map(\.event), dropped)
    }
}
