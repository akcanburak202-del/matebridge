import Foundation

// Building blocks of the session encryption (docs/PROTOCOL.md section 9, decision 0010).
// Nothing here ever prints key material: secret-bearing types describe themselves as "<redacted>".

/// A failure of the cryptographic channel. Distinct from `ProtocolError`: after one of these the peer is not
/// trusted, so the receiver closes the connection without sending BYE (PROTOCOL.md 9).
public enum CryptoError: Error, Equatable, Sendable {
    /// The peer's ephemeral public key is not a valid uncompressed P-256 point.
    case invalidPublicKey
    case invalidKeyLength
    /// The GCM tag did not verify (a flipped bit, a wrong key, a replayed or reordered record).
    case authenticationFailed
    /// `length < 17` or above the connection's payload limit + 17, checked as soon as the 4 bytes are in.
    case invalidRecordLength(UInt32)
    /// The 64-bit record counter reached 2^63.
    case counterExhausted
    /// The decoder already failed; the connection must be closed.
    case decoderFailed
    case bufferOverflow
    case chunkTooLarge
    /// Switching to encrypted records while plaintext bytes were still buffered.
    case unexpectedPlaintext
}

/// Key material. Equatable so actions can be compared in tests; never prints its content.
public struct SecretBytes: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let bytes: [UInt8]
    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}

/// The six-digit pairing code (`sas`). Shown in the approval window only; never logged.
public struct PairingCode: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let digits: String
    public init(digits: String) { self.digits = digits }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}

/// Heap cell for the session's `prk` so it can be zeroed when the session ends (PROTOCOL.md 9).
/// Best effort: copies the optimizer or the runtime made earlier are out of reach.
public final class SessionSecret: @unchecked Sendable {
    private var storage: [UInt8]
    public private(set) var isWiped = false

    init(_ bytes: [UInt8]) { storage = bytes }

    /// nil after `wipe()`.
    var bytes: [UInt8]? { isWiped ? nil : storage }
    /// Test hook: what the cell holds right now (all zero after `wipe()`).
    var rawStorage: [UInt8] { storage }

    public func wipe() {
        storage.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { _ = memset_s(base, raw.count, 0, raw.count) }
        }
        isWiped = true
    }

    deinit { wipe() }
}

/// Storage for per-device pair keys (macOS Keychain in the app, a fake in tests).
public protocol PairKeyStore: Sendable {
    func key(for device: DeviceID) -> SecretBytes?
    func save(_ key: SecretBytes, for device: DeviceID) throws
    func remove(_ device: DeviceID) throws
    /// "Onaylı cihazları unut": every pair key goes.
    func removeAll() throws
}

/// In-memory `PairKeyStore` for tests and as the default of a machine that has no store.
public final class InMemoryPairKeyStore: PairKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [DeviceID: SecretBytes] = [:]
    /// Test hook: make `save` fail.
    public var failSaves = false

    public init(keys: [DeviceID: SecretBytes] = [:]) { self.keys = keys }

    public func key(for device: DeviceID) -> SecretBytes? {
        lock.lock(); defer { lock.unlock() }
        return keys[device]
    }

    public func save(_ key: SecretBytes, for device: DeviceID) throws {
        lock.lock(); defer { lock.unlock() }
        if failSaves { throw CocoaError(.fileWriteUnknown) }
        keys[device] = key
    }

    public func remove(_ device: DeviceID) throws {
        lock.lock(); defer { lock.unlock() }
        keys[device] = nil
    }

    public func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        keys.removeAll()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return keys.count
    }
}
