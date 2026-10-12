import Foundation

/// The local cursor's acknowledgement of relative moves (decision 0036 v3, T-344, PROTOCOL.md 0x0D `rel_ack_count`).
///
/// Written by the input side after it has handled each `POINTER_REL` of the control connection (injected, or dropped by
/// the 0025 rules / the input gates), read by the cursor flow right before it samples the Mac's cursor. Rule
/// identifiers used as test-name prefixes: CUR-ACK-*.
///
/// The guarantee a `CURSOR_STATE` must give: the `x`/`y` it carries include the effect of the first `rel_ack_count`
/// messages. Two facts make a plain "read the position after the count" wrong:
/// - `CGEventPost` hands the event to WindowServer asynchronously, and `CGEvent(source: nil).location` can still show
///   the position from before it for a few milliseconds (up to the planner's 100 ms lag window under load, T-103);
/// - the order matters: the count is read FIRST (a message handled after that read can only make the position newer,
///   which the client tolerates; the other order could claim a message the position does not contain yet).
///
/// So the board also keeps the LAST POSTED LOCATION: every CGEvent the host posts that carries a cursor location (a
/// relative or absolute move, a pen point, a synthesized button up or down, a release batch) is noted with its time and
/// simply overwrites the previous one; nothing ever clears it. What the host posts is what WindowServer will apply, so
/// the last posted location always includes everything that was acknowledged. While it is recent and the live reading
/// is not at it yet, it is the reported position (`position(live:reading:)`): count and position then describe the same
/// moment by construction. Once it is older than the lag window the live reading is the truth again (a physical mouse).
public final class RelAckBoard: @unchecked Sendable {
    /// The shared board of the host process (`InputController` writes it, `CursorService` reads it).
    public static let shared = RelAckBoard()

    public struct Reading: Equatable, Sendable {
        /// `POINTER_REL` messages handled since the connection began (never goes back).
        public var count: UInt64
        /// The location of the last posted pointer-carrying event, while it is younger than the lag window; nil when
        /// nothing was posted yet or it is older.
        public var target: DisplayPoint?
        public init(count: UInt64, target: DisplayPoint?) {
            self.count = count
            self.target = target
        }
    }

    /// A live reading farther than this from the target is "WindowServer has not caught up yet" (same rule as the
    /// planner's lag ring: less than a point on both axes is the same place).
    static func near(_ a: DisplayPoint, _ b: DisplayPoint) -> Bool { abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1 }

    private let lagWindowUs: UInt64
    private let lock = NSLock()
    private var count: UInt64 = 0
    private var target: DisplayPoint?
    private var targetAtUs: UInt64 = 0
    /// Seqlock state. `writers` is above 0 while the input queue is inside `beginWrite`/`endWrite` (a message being
    /// handled, or any post): the board is mid-update then, and a sample must not use it. `generation` is bumped when a
    /// write ends and on `reset`: a sample is coherent only when it saw no write in progress and no generation change
    /// across its reads.
    private var writers = 0
    private var generation: UInt64 = 0

    public init(lagWindowUs: UInt64 = InjectionPlanner.defaultLagWindowUs) { self.lagWindowUs = lagWindowUs }

    /// A new control connection (or its end): the count restarts at 0.
    public func reset() {
        lock.lock()
        count = 0
        target = nil
        generation &+= 1
        lock.unlock()
    }

    /// The input queue starts handling something that may post events: call it BEFORE any CGEvent is posted. Nests
    /// (the message handler wraps the posts inside it). Every `beginWrite` needs its `endWrite`.
    public func beginWrite() {
        lock.lock()
        writers += 1
        lock.unlock()
    }

    /// The handling ended: count, location and generation are final together.
    public func endWrite() {
        lock.lock()
        if writers > 0 { writers -= 1 }
        if writers == 0 { generation &+= 1 }
        lock.unlock()
    }

    /// One `POINTER_REL` has been handled (injected, or dropped by the input rules or a gate): inside a write, after
    /// its events were posted and their location noted.
    public func notePointerRel() {
        lock.lock()
        count &+= 1
        lock.unlock()
    }

    /// A CGEvent that carries a cursor location was posted at `location`. Whatever its source; it overwrites the
    /// previous one. Inside a write.
    public func notePosted(_ location: DisplayPoint, nowUs: UInt64) {
        lock.lock()
        target = location
        targetAtUs = nowUs
        lock.unlock()
    }

    /// The count and the recent target. Read this BEFORE reading the cursor.
    public func read(nowUs: UInt64) -> Reading {
        lock.lock()
        defer { lock.unlock() }
        let recent = target != nil && nowUs >= targetAtUs && nowUs - targetAtUs <= lagWindowUs
        return Reading(count: count, target: recent ? target : nil)
    }

    /// One coherent (count, position) pair, seqlock style: read the board, read the live position, read the board again.
    /// A write in progress at either read (the input queue is posting or counting), or a generation change between them,
    /// means the pair could show a newer position under an older count (the client would count that move twice), so it
    /// is retried, at most `retries` times. When the retries run out there is no usable pair and the result is nil: the
    /// caller skips this sample and the next poll tries again. A count is never emitted with a position that might not
    /// include it.
    public func coherentPosition(retries: Int = 3, nowUs: () -> UInt64,
                                 locate: () -> DisplayPoint?) -> (reading: Reading, position: DisplayPoint?)? {
        for _ in 0...retries {
            let (before, busyBefore, generationBefore) = stamped(nowUs: nowUs())
            let live = locate()
            let (_, busyAfter, generationAfter) = stamped(nowUs: nowUs())
            if !busyBefore, !busyAfter, generationAfter == generationBefore {
                return (before, live.map { Self.position(live: $0, reading: before) })
            }
        }
        return nil
    }

    private func stamped(nowUs: UInt64) -> (Reading, Bool, UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let recent = target != nil && nowUs >= targetAtUs && nowUs - targetAtUs <= lagWindowUs
        return (Reading(count: count, target: recent ? target : nil), writers > 0, generation)
    }

    /// The position to report together with `reading.count`: the live one when it already shows the last relative
    /// move (or there was none to wait for), else that move's target.
    public static func position(live: DisplayPoint, reading: Reading) -> DisplayPoint {
        guard let target = reading.target, !near(target, live) else { return live }
        return target
    }
}

/// What a posted batch means for the host's bookkeeping (T-323 inject-to-frame, T-344 rel-ack): pure, so it is tested.
public struct PostSummary: Equatable, Sendable {
    /// A press edge (key down, mouse down, pen contact) was among the events that actually went out.
    public var pressEdge: Bool
    /// Where the last posted event that carries a cursor location put the cursor.
    public var lastLocation: DisplayPoint?

    public init(events: [MacEvent], failed: [MacEvent]) {
        var press = false
        var location: DisplayPoint?
        for event in events where !failed.contains(event) {
            if event.isPressEdge { press = true }
            switch event {
            case .mouse(let mouse): location = mouse.position
            case .tabletPoint(let point): location = point.position
            default: break
            }
        }
        pressEdge = press
        lastLocation = location
    }
}
