import Foundation

/// Stall detector of the stream coordinator's event loop (T-325). Pure state machine; the coordinator brackets every
/// event with `begin`/`end`, a timer on a separate queue calls `poll`.
///
/// Escalation, each step at most once per event:
/// - `warn` after `warnUs`: `E ev=coordinator_stall event=<kind> ms=`.
/// - `endSessions` after `recoverUs`: every session is ended (input released, BYE), so a stuck host never keeps a held
///   key or pen contact.
/// - `restart` after `restartUs`: the process relaunches itself (or exits), the last resort.
///
/// Intentional sleeps (pipeline retry back-off) call `pause`/`resume`: the paused time does not count.
public struct CoordinatorWatchdog: Sendable {
    public enum Action: Equatable, Sendable {
        case warn(kind: String, ms: UInt64)
        case endSessions(kind: String, ms: UInt64)
        case restart(kind: String, ms: UInt64)
    }

    public static let warnUs: UInt64 = 3_000_000
    public static let recoverUs: UInt64 = 10_000_000
    public static let restartUs: UInt64 = 30_000_000

    public let warnAfterUs: UInt64
    public let recoverAfterUs: UInt64
    public let restartAfterUs: UInt64

    private struct Current {
        var kind: String
        var startedUs: UInt64
        var pausedAtUs: UInt64?
        var stage = 0  // 0 none, 1 warned, 2 sessions ended, 3 restart requested
    }
    private var current: Current?

    /// New sessions are refused: set by the `endSessions` step, kept by the restart. Lives in this state machine so
    /// that raising and clearing it are ordered by the one lock the coordinator holds around every transition (a late
    /// poll can never refuse again after the event it saw has finished).
    public private(set) var refusing = false
    /// A restart was requested (by the 30 s step or by the abandoned stops): the refusal never lifts again.
    public private(set) var restartRequested = false

    public init(warnAfterUs: UInt64 = warnUs, recoverAfterUs: UInt64 = recoverUs,
                restartAfterUs: UInt64 = restartUs) {
        self.warnAfterUs = warnAfterUs
        self.recoverAfterUs = recoverAfterUs
        self.restartAfterUs = restartAfterUs
    }

    public var isBusy: Bool { current != nil }

    public mutating func begin(kind: String, nowUs: UInt64) {
        current = Current(kind: kind, startedUs: nowUs)
    }

    /// The event finished. Returns `(kind, ms)` when a stall had been reported for it (for `ev=coordinator_stall_over`).
    @discardableResult
    public mutating func end(nowUs: UInt64) -> (kind: String, ms: UInt64)? {
        defer { current = nil }
        guard let c = current, c.stage > 0 else { return nil }
        return (c.kind, Self.elapsedMs(c, nowUs: nowUs))
    }

    /// A restart is wanted for another reason (abandoned stops). True only the first time, for any reason.
    public mutating func requestRestart() -> Bool {
        defer { restartRequested = true; refusing = true }
        return !restartRequested
    }

    /// Any healthy event completion lifts the refusal, unless a restart is under way. True when it was lifted.
    public mutating func liftRefusal() -> Bool {
        guard refusing, !restartRequested else { return false }
        refusing = false
        return true
    }

    public mutating func pause(nowUs: UInt64) {
        guard var c = current, c.pausedAtUs == nil else { return }
        c.pausedAtUs = nowUs
        current = c
    }

    public mutating func resume(nowUs: UInt64) {
        guard var c = current, let p = c.pausedAtUs else { return }
        c.startedUs &+= nowUs &- p  // the paused time does not count
        c.pausedAtUs = nil
        current = c
    }

    /// Actions due now (in escalation order; a long gap between polls can return several).
    public mutating func poll(nowUs: UInt64) -> [Action] {
        guard var c = current, c.pausedAtUs == nil else { return [] }
        let elapsed = nowUs &- c.startedUs
        let ms = elapsed / 1_000
        var out: [Action] = []
        if c.stage < 1, elapsed >= warnAfterUs { c.stage = 1; out.append(.warn(kind: c.kind, ms: ms)) }
        if c.stage < 2, elapsed >= recoverAfterUs {
            c.stage = 2
            refusing = true
            out.append(.endSessions(kind: c.kind, ms: ms))
        }
        if c.stage < 3, elapsed >= restartAfterUs {
            c.stage = 3
            refusing = true
            if !restartRequested { restartRequested = true; out.append(.restart(kind: c.kind, ms: ms)) }
        }
        current = c
        return out
    }

    private static func elapsedMs(_ c: Current, nowUs: UInt64) -> UInt64 {
        let end = c.pausedAtUs ?? nowUs
        return (end &- c.startedUs) / 1_000
    }
}
