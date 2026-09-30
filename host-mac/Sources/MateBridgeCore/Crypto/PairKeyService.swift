import Foundation

/// All pair-key storage access (Keychain in the app) on ONE serial queue, always asynchronous.
///
/// The Keychain can block (access prompt, locked keychain). Nothing that releases input or ends a session may wait
/// for it, so callers enqueue and get the answer back through a completion. Because the queue is serial, operations
/// run in the order they were enqueued: a "forget everything" enqueued before a later pairing save can never delete
/// that fresh key, and a save's completion means the key is stored.
///
/// Completions run on the keychain queue: hop to your own queue immediately and do no blocking work in them.
public final class PairKeyService: @unchecked Sendable {
    private let store: PairKeyStore
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pendingLookups = 0

    /// Lookups waiting for (or inside) the store. A stuck Keychain must not let unauthenticated connections pile up
    /// work behind it: beyond this the caller closes the connection instead.
    public static let maxPendingLookups = 8

    public init(store: PairKeyStore,
                queue: DispatchQueue = DispatchQueue(label: "dev.matebridge.keychain", qos: .userInitiated)) {
        self.store = store
        self.queue = queue
    }

    /// Enqueues a lookup. Returns false (nothing enqueued, `completion` never called) when `maxPendingLookups` are
    /// already waiting: the caller closes that connection. `isCurrent` is checked when the job reaches the front of the
    /// queue; a lookup whose connection has gone or expired is skipped without touching the store and without calling
    /// `completion`. It runs on the keychain queue, so it must be thread safe and quick.
    @discardableResult
    public func lookup(_ device: DeviceID, isCurrent: @escaping @Sendable () -> Bool = { true },
                       completion: @escaping @Sendable (SecretBytes?) -> Void) -> Bool {
        let accepted = lock.withLock { () -> Bool in
            guard pendingLookups < Self.maxPendingLookups else { return false }
            pendingLookups += 1
            return true
        }
        guard accepted else { return false }
        queue.async { [store, self] in
            let current = isCurrent()
            let key = current ? store.key(for: device) : nil
            lock.withLock { pendingLookups -= 1 }
            if current { completion(key) }
        }
        return true
    }

    public func save(_ key: SecretBytes, for device: DeviceID, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [store] in
            do { try store.save(key, for: device); completion(true) } catch { completion(false) }
        }
    }

    public func remove(_ device: DeviceID, completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        queue.async { [store] in
            do { try store.remove(device); completion(true) } catch { completion(false) }
        }
    }

    /// Compare-and-delete: removes the device's key only if it is still exactly `key` (the one the caller stored).
    /// Runs on the serial queue, so a newer key saved for the same device (enqueued earlier or later) is never
    /// deleted by a stale cleanup.
    public func remove(_ device: DeviceID, ifEquals key: SecretBytes, completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        queue.async { [store] in
            guard store.key(for: device) == key else { completion(true); return }
            do { try store.remove(device); completion(true) } catch { completion(false) }
        }
    }

    /// `error` is a description only (never key material).
    public func removeAll(completion: @escaping @Sendable (_ error: String?) -> Void = { _ in }) {
        queue.async { [store] in
            do { try store.removeAll(); completion(nil) } catch { completion("\(error)") }
        }
    }
}
