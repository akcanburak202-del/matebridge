import Foundation

/// All pair-key storage access (Keychain in the app) on ONE serial queue, always asynchronous.
///
/// The Keychain can block (access prompt, locked keychain). Nothing that releases input or ends a session may wait
/// for it, so callers enqueue and get the answer back through a completion. Because the queue is serial, operations
/// run in the order they were enqueued: a "forget everything" enqueued before a later pairing save can never delete
/// that fresh key, and a save's completion means the key is stored.
///
/// Everything waiting for the Keychain is bounded (`maxPendingOperations` in total, `maxPendingLookups` of them
/// lookups): a stuck Keychain must not let work pile up behind it. An operation that does not fit is refused
/// (the method returns false, nothing is enqueued, the completion is never called) and the caller reacts explicitly.
/// "Forget everything" (`removeAll`) is never refused: it coalesces into a still-waiting `removeAll` when nothing else
/// was enqueued since, so at most one more than the bounded operations can ever be waiting.
///
/// Completions run on the keychain queue: hop to your own queue immediately and do no blocking work in them.
public final class PairKeyService: @unchecked Sendable {
    private let store: PairKeyStore
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pendingLookups = 0
    private var pendingOperations = 0
    /// Completions of a `removeAll` that is enqueued but has not started, and that nothing was enqueued after.
    private var coalescingRemoveAll: RemoveAllJob?

    private final class RemoveAllJob {
        var completions: [@Sendable (String?) -> Void]
        init(_ first: @escaping @Sendable (String?) -> Void) { completions = [first] }
    }

    public static let maxPendingLookups = 8
    public static let maxPendingOperations = 16

    public init(store: PairKeyStore,
                queue: DispatchQueue = DispatchQueue(label: "dev.matebridge.keychain", qos: .userInitiated)) {
        self.store = store
        self.queue = queue
    }

    /// True when one more bounded operation (save, delete, lookup) would be accepted right now.
    public var hasCapacity: Bool { lock.withLock { pendingOperations < Self.maxPendingOperations } }

    /// Reserves a slot; nothing else may have been enqueued between a coalescible `removeAll` and now.
    private func reserve(lookup: Bool = false) -> Bool {
        lock.withLock {
            guard pendingOperations < Self.maxPendingOperations,
                  !lookup || pendingLookups < Self.maxPendingLookups else { return false }
            pendingOperations += 1
            if lookup { pendingLookups += 1 }
            coalescingRemoveAll = nil  // a later operation must not be skipped past by a coalesced forget
            return true
        }
    }

    private func finish(lookup: Bool = false) {
        lock.withLock {
            pendingOperations -= 1
            if lookup { pendingLookups -= 1 }
        }
    }

    /// Enqueues a lookup; false when full (the caller closes that connection). `isCurrent` is checked when the job
    /// reaches the front of the queue; a lookup whose connection has gone or expired is skipped without touching the
    /// store and without calling `completion`. It runs on the keychain queue, so it must be thread safe and quick.
    @discardableResult
    public func lookup(_ device: DeviceID, isCurrent: @escaping @Sendable () -> Bool = { true },
                       completion: @escaping @Sendable (SecretBytes?) -> Void) -> Bool {
        guard reserve(lookup: true) else { return false }
        queue.async { [store, self] in
            let current = isCurrent()
            let key = current ? store.key(for: device) : nil
            finish(lookup: true)
            if current { completion(key) }
        }
        return true
    }

    /// False when full: nothing saved, `completion` never called.
    @discardableResult
    public func save(_ key: SecretBytes, for device: DeviceID, completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        guard reserve() else { return false }
        queue.async { [store, self] in
            let ok: Bool
            do { try store.save(key, for: device); ok = true } catch { ok = false }
            finish()
            completion(ok)
        }
        return true
    }

    @discardableResult
    public func remove(_ device: DeviceID, completion: @escaping @Sendable (Bool) -> Void = { _ in }) -> Bool {
        guard reserve() else { return false }
        queue.async { [store, self] in
            let ok: Bool
            do { try store.remove(device); ok = true } catch { ok = false }
            finish()
            completion(ok)
        }
        return true
    }

    /// Compare-and-delete: removes the device's key only if it is still exactly `key` (the one the caller stored).
    /// Runs on the serial queue, so a newer key saved for the same device (enqueued earlier or later) is never
    /// deleted by a stale cleanup. False when full (the key then stays until that device pairs again).
    @discardableResult
    public func remove(_ device: DeviceID, ifEquals key: SecretBytes,
                       completion: @escaping @Sendable (Bool) -> Void = { _ in }) -> Bool {
        guard reserve() else { return false }
        queue.async { [store, self] in
            let ok: Bool
            if store.key(for: device) == key {
                do { try store.remove(device); ok = true } catch { ok = false }
            } else {
                ok = true
            }
            finish()
            completion(ok)
        }
        return true
    }

    /// Never refused. `error` is a description only (never key material).
    public func removeAll(completion: @escaping @Sendable (_ error: String?) -> Void = { _ in }) {
        let job = lock.withLock { () -> RemoveAllJob? in
            if let pending = coalescingRemoveAll {
                pending.completions.append(completion)
                return nil
            }
            let job = RemoveAllJob(completion)
            coalescingRemoveAll = job
            return job
        }
        guard let job else { return }
        queue.async { [store, self] in
            let completions = lock.withLock { () -> [@Sendable (String?) -> Void] in
                if coalescingRemoveAll === job { coalescingRemoveAll = nil }  // started: no more joining
                return job.completions
            }
            let failure: String?
            do { try store.removeAll(); failure = nil } catch { failure = "\(error)" }
            for c in completions { c(failure) }
        }
    }
}
