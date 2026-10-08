import Foundation

/// Latest-value coalescing for state updates that must not cross a session boundary (T-136). Producers `offer`
/// values tagged with the current epoch (bumped at every session start/end); only the newest value of an epoch is
/// kept, and a drain is scheduled only for the first value of a burst. A drain created for an epoch takes only that
/// epoch's value, so a value from an ended session can never be applied after the session boundary. Teardown events
/// are not routed through here: they are always queued, never coalesced or dropped. Pure; callers add the lock.
///
/// This is the one latest-value mailbox of the host (T-313): the files info (`TabletFilesBridge`), `CURSOR_PREFS`
/// (`CursorService`, a session boundary bumps the epoch) and the incoming clipboard (`ClipboardBridge`, one constant
/// epoch) all use it.
public struct EpochCoalescer<Value: Sendable>: Sendable {
    private var pending: (epoch: UInt64, value: Value)?

    public init() {}

    /// Stores `value`. Returns true when the caller must schedule a drain for `epoch` (none is pending for it).
    public mutating func offer(_ value: Value, epoch: UInt64) -> Bool {
        let needsDrain = pending?.epoch != epoch
        pending = (epoch, value)
        return needsDrain
    }

    /// The newest value of `epoch`, removed; nil when there is none (already taken, or a newer epoch replaced it).
    public mutating func take(epoch: UInt64) -> Value? {
        guard let p = pending, p.epoch == epoch else { return nil }
        pending = nil
        return p.value
    }

    /// Drops what waits (a session boundary: the caller also moves on to a new epoch, so a drain already scheduled
    /// finds nothing and the next value schedules its own).
    public mutating func clear() { pending = nil }
}
