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

    public init(store: PairKeyStore,
                queue: DispatchQueue = DispatchQueue(label: "dev.matebridge.keychain", qos: .userInitiated)) {
        self.store = store
        self.queue = queue
    }

    public func lookup(_ device: DeviceID, completion: @escaping @Sendable (SecretBytes?) -> Void) {
        queue.async { [store] in completion(store.key(for: device)) }
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

    /// `error` is a description only (never key material).
    public func removeAll(completion: @escaping @Sendable (_ error: String?) -> Void = { _ in }) {
        queue.async { [store] in
            do { try store.removeAll(); completion(nil) } catch { completion("\(error)") }
        }
    }
}
