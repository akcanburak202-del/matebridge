import CryptoKit
import Foundation

/// Keys of the control connection, one per direction (PROTOCOL.md 9).
public struct ControlKeys: Equatable, Sendable {
    public let c2h: SecretBytes
    public let h2c: SecretBytes
}

/// Keys of one video connection, derived from the session `prk` and that connection's `video_nonce`.
public struct VideoKeys: Equatable, Sendable {
    public let c2h: SecretBytes
    public let h2c: SecretBytes
}

/// The per-connection ephemeral P-256 key pair.
public struct EphemeralKeyPair: @unchecked Sendable {
    private let key: P256.KeyAgreement.PrivateKey

    public init() { key = P256.KeyAgreement.PrivateKey() }

    /// Deterministic key for test vectors (a raw 32-byte scalar).
    public init(rawPrivateKey: [UInt8]) throws {
        guard let k = try? P256.KeyAgreement.PrivateKey(rawRepresentation: Data(rawPrivateKey)) else {
            throw CryptoError.invalidKeyLength
        }
        key = k
    }

    /// Uncompressed point, 65 bytes (`04 || X || Y`).
    public var publicKeyBytes: [UInt8] { Array(key.publicKey.x963Representation) }

    /// ECDH shared secret: the X coordinate, 32 bytes. A malformed or off-curve peer key is `invalidPublicKey`.
    public func sharedSecret(withPeerPublicKey peer: [UInt8]) throws -> [UInt8] {
        guard peer.count == ProtocolConstants.publicKeySize, peer[0] == 0x04,
              let publicKey = try? P256.KeyAgreement.PublicKey(x963Representation: Data(peer)),
              let secret = try? key.sharedSecretFromKeyAgreement(with: publicKey) else {
            throw CryptoError.invalidPublicKey
        }
        return secret.withUnsafeBytes { Array($0) }
    }
}

/// HKDF-SHA256 (RFC 5869) over CryptoKit.
enum KDF {
    static func extract(salt: [UInt8], ikm: [UInt8]) -> [UInt8] {
        HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt).withUnsafeBytes { Array($0) }
    }

    static func expand(prk: [UInt8], info: String, extra: [UInt8] = [], count: Int) -> [UInt8] {
        HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data(info.utf8) + Data(extra), outputByteCount: count)
            .withUnsafeBytes { Array($0) }
    }
}

/// Everything derived from one handshake (PROTOCOL.md 9). The `prk` lives in a `SessionSecret` the owner wipes
/// when the session ends; the direction keys are plain values handed to the record layer.
public struct SessionKeySchedule: Sendable {
    public static let keySize = 32

    /// `.paired` or `.pairing`.
    public let mode: KeyMode
    public let control: ControlKeys
    /// PAIRING only.
    public let pairingCode: PairingCode?
    /// PAIRING only: the key both sides store once the user confirmed the codes.
    public let newPairKey: SecretBytes?
    /// SHA-256(HELLO payload || first HELLO_ACK payload).
    public let transcriptHash: [UInt8]
    let secret: SessionSecret

    /// - Parameters:
    ///   - ecdh: the P-256 shared secret (32 bytes).
    ///   - pairKey: the stored pair key for PAIRED, nil for PAIRING.
    ///   - helloPayload, ackPayload: the two payloads as they were on the wire (no frame header).
    public static func derive(ecdh: [UInt8], pairKey: SecretBytes?, helloPayload: [UInt8],
                              ackPayload: [UInt8]) throws -> SessionKeySchedule {
        guard ecdh.count == keySize, pairKey.map({ $0.bytes.count == keySize }) ?? true else {
            throw CryptoError.invalidKeyLength
        }
        let ikm = (pairKey?.bytes ?? []) + ecdh
        let transcript = Array(SHA256.hash(data: Data(helloPayload + ackPayload)))
        let prk = KDF.extract(salt: transcript, ikm: ikm)
        let control = ControlKeys(
            c2h: SecretBytes(KDF.expand(prk: prk, info: "MB1 control c2h", count: keySize)),
            h2c: SecretBytes(KDF.expand(prk: prk, info: "MB1 control h2c", count: keySize)))
        var code: PairingCode?
        var newKey: SecretBytes?
        if pairKey == nil {
            let sas = KDF.expand(prk: prk, info: "MB1 sas", count: 4)
            let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(sas[$1]) << (8 * UInt32($1)) } % 1_000_000
            code = PairingCode(digits: String(format: "%06u", value))
            newKey = SecretBytes(KDF.expand(prk: prk, info: "MB1 pair", count: keySize))
        }
        return SessionKeySchedule(mode: pairKey == nil ? .pairing : .paired, control: control, pairingCode: code,
                                  newPairKey: newKey, transcriptHash: transcript, secret: SessionSecret(prk))
    }

    /// Keys for one video connection. nil after `wipe()` or for a nonce that is not 16 bytes.
    public func videoKeys(nonce: [UInt8]) -> VideoKeys? {
        guard nonce.count == ProtocolConstants.nonceSize, let prk = secret.bytes else { return nil }
        return VideoKeys(
            c2h: SecretBytes(KDF.expand(prk: prk, info: "MB1 video c2h", extra: nonce, count: Self.keySize)),
            h2c: SecretBytes(KDF.expand(prk: prk, info: "MB1 video h2c", extra: nonce, count: Self.keySize)))
    }

    /// Zeroes the `prk`. Video keys can no longer be derived; already handed-out keys are unaffected.
    public func wipe() { secret.wipe() }

    var prkBytes: [UInt8]? { secret.bytes }
}
