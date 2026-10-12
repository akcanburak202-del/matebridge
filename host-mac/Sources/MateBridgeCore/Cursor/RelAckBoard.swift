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
/// So the board also keeps the position the last relative move was posted at (the planner's post-clamp target). While
/// that target is recent and the live reading is not at it yet, the target is the reported position
/// (`position(live:reading:)`): count and position then describe the same moment by construction. Any other
/// injection (pen, absolute pointer, ...) clears the target, so a stale one never overrides a later move.
public final class RelAckBoard: @unchecked Sendable {
    /// The shared board of the host process (`InputController` writes it, `CursorService` reads it).
    public static let shared = RelAckBoard()

    public struct Reading: Equatable, Sendable {
        /// `POINTER_REL` messages handled since the connection began (never goes back).
        public var count: UInt64
        /// Where the last handled relative move left the cursor, while that is recent; nil when it moved nothing, was
        /// superseded by another injection, or is older than the lag window.
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
    /// Bumped by every change of the board (a handled message, another injection, a reset): a sample is coherent only
    /// when it did not move between its reads.
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

    /// One `POINTER_REL` has been handled: call it AFTER the events it produced were posted (or after it was dropped).
    /// `target` is where the last posted pointer event of this message put the cursor, nil if it posted none.
    public func notePointerRel(target: DisplayPoint?, nowUs: UInt64) {
        lock.lock()
        count &+= 1
        generation &+= 1
        // A message that posted nothing (no-op, dropped) leaves the pending target, and its age, alone: wiping it would
        // let a live reading that still lags an earlier move be reported with the newer count.
        if let target {
            self.target = target
            targetAtUs = nowUs
        }
        lock.unlock()
    }

    /// An injection that SET the cursor position (a pen point, an absolute pointer move) was posted: an earlier relative
    /// target is not the truth any more. Injections that place nothing (pinch, scroll, keys) must not call this: they
    /// leave the target, its age and the generation alone.
    public func noteOtherInjection() {
        lock.lock()
        target = nil
        generation &+= 1
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
    /// If anything was handled in between (a `POINTER_REL`, another injection, a reset) the pair could show a newer
    /// position under an older count (the client would count that move twice) or a target that was just cleared, so it
    /// is retried, at most `retries` times. When the retries run out there is no usable pair and the result is nil: the
    /// caller skips this sample and the next poll tries again. A count is never emitted with a position that might not
    /// include it.
    public func coherentPosition(retries: Int = 3, nowUs: () -> UInt64,
                                 locate: () -> DisplayPoint?) -> (reading: Reading, position: DisplayPoint?)? {
        for _ in 0...retries {
            let (before, generationBefore) = stamped(nowUs: nowUs())
            let live = locate()
            let (_, generationAfter) = stamped(nowUs: nowUs())
            if generationAfter == generationBefore {
                return (before, live.map { Self.position(live: $0, reading: before) })
            }
        }
        return nil
    }

    private func stamped(nowUs: UInt64) -> (Reading, UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let recent = target != nil && nowUs >= targetAtUs && nowUs - targetAtUs <= lagWindowUs
        return (Reading(count: count, target: recent ? target : nil), generation)
    }

    /// The position to report together with `reading.count`: the live one when it already shows the last relative
    /// move (or there was none to wait for), else that move's target.
    public static func position(live: DisplayPoint, reading: Reading) -> DisplayPoint {
        guard let target = reading.target, !near(target, live) else { return live }
        return target
    }
}
