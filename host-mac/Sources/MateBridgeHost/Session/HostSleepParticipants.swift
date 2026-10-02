import Foundation

/// Components that must be quiet before the Mac sleeps (T-132), independent of the session queue: the input
/// controller releases everything held, the audio tap stops its capture. `SessionServer`'s power handler starts every
/// registered participant at once on `will_sleep` and waits for them within `HostSleep.budgetUs`, next to (not
/// behind) the session teardown, so a stalled session queue cannot leave input held or the tap running over a sleep.
/// Each participant's work must be idempotent with its normal session-end path and call `done` when finished (extra
/// calls are ignored). Registration is process-wide because these components are wired together only in the app
/// entry point.
final class HostSleepParticipants: @unchecked Sendable {
    typealias Work = @Sendable (_ done: @escaping @Sendable () -> Void) -> Void

    static let shared = HostSleepParticipants()

    private let lock = NSLock()
    private var entries: [(owner: ObjectIdentifier, name: String, work: Work)] = []

    /// Registers (or replaces) `owner`'s work. `work` should capture `owner` weakly.
    func register(_ owner: AnyObject, name: String, work: @escaping Work) {
        let id = ObjectIdentifier(owner)
        lock.withLock {
            entries.removeAll { $0.owner == id }
            entries.append((id, name, work))
        }
    }

    /// Call from the owner's `deinit` (its identifier may be reused afterwards).
    func unregister(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        lock.withLock { entries.removeAll { $0.owner == id } }
    }

    /// The registered participants, in registration order.
    func snapshot() -> [(name: String, work: Work)] {
        lock.withLock { entries.map { ($0.name, $0.work) } }
    }
}
