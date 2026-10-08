import CryptoKit
import Foundation

// Encrypted record layer (PROTOCOL.md 9): `length u32 LE || AES-256-GCM(type || payload) || tag`,
// nonce = 00 00 00 00 || counter u64 LE, AAD = the 4 length bytes. One counter per connection and direction.

private func recordNonce(_ counter: UInt64) -> AES.GCM.Nonce {
    var bytes = Data(count: 12)
    for i in 0..<8 { bytes[4 + i] = UInt8(truncatingIfNeeded: counter >> (8 * UInt64(i))) }
    return try! AES.GCM.Nonce(data: bytes)  // 12 bytes by construction
}

private func lengthBytes(_ length: UInt32) -> Data {
    Data((0..<4).map { UInt8(truncatingIfNeeded: length >> (8 * UInt32($0))) })
}

/// Outbound half of one connection direction.
public struct RecordSealer: Sendable {
    /// PROTOCOL.md 9: the counter never reaches 2^63.
    public static let counterLimit: UInt64 = 1 << 63

    private let key: SymmetricKey
    private let maxPayload: Int
    /// The counter the next record uses.
    public private(set) var counter: UInt64

    public init(key: SecretBytes, maxPayload: Int) {
        self.init(key: key, maxPayload: maxPayload, startingCounter: 0)
    }

    init(key: SecretBytes, maxPayload: Int, startingCounter: UInt64) {
        self.key = SymmetricKey(data: key.bytes)
        self.maxPayload = maxPayload
        self.counter = startingCounter
    }

    /// One complete record, ready to write. The counter advances only on success.
    public mutating func seal(type: UInt8, payload: [UInt8]) throws -> [UInt8] {
        guard counter < Self.counterLimit else { throw CryptoError.counterExhausted }
        guard payload.count <= maxPayload else {
            throw ProtocolError.payloadTooLarge(length: UInt32(clamping: payload.count), limit: maxPayload)
        }
        var plain = Data(capacity: 1 + payload.count)
        plain.append(type)
        plain.append(contentsOf: payload)
        let length = UInt32(plain.count + ProtocolConstants.recordTagSize)
        let header = lengthBytes(length)
        let box = try AES.GCM.seal(plain, using: key, nonce: recordNonce(counter), authenticating: header)
        counter += 1
        var out = [UInt8]()
        out.reserveCapacity(4 + Int(length))
        out.append(contentsOf: header)
        out.append(contentsOf: box.ciphertext)
        out.append(contentsOf: box.tag)
        return out
    }
}

extension Message {
    /// The message as one encrypted record (same validation as `encode()`).
    public func sealed(using sealer: inout RecordSealer) throws -> [UInt8] {
        try sealer.seal(type: type.rawValue, payload: checkedPayload())
    }
}

/// Inbound half: feed received bytes, pull authenticated messages.
///
/// The length is checked the moment its 4 bytes are buffered; total buffering is bounded like `FrameDecoder`.
/// Any crypto failure (`CryptoError`) or protocol violation inside an authenticated record (`ProtocolError`)
/// fails the decoder for good. Unknown message types are skipped.
public struct RecordDecoder: Sendable {
    public let connection: FrameDecoder.Connection
    private let key: SymmetricKey
    /// The counter the next record must carry.
    public private(set) var counter: UInt64 = 0
    private var buffer: [UInt8] = []
    private var start = 0
    private var failed = false
    private var pendingError: CryptoError?

    private let payloadLimit: Int

    /// - Parameter maxPayload: tighter limit than the connection's (the video proof accepts one tiny PING).
    public init(key: SecretBytes, connection: FrameDecoder.Connection, maxPayload: Int? = nil) {
        self.key = SymmetricKey(data: key.bytes)
        self.connection = connection
        self.payloadLimit = min(maxPayload ?? connection.maxPayload, connection.maxPayload)
    }

    init(key: SecretBytes, connection: FrameDecoder.Connection, startingCounter: UInt64) {
        self.init(key: key, connection: connection)
        counter = startingCounter
    }

    public var bufferedCount: Int { buffer.count - start }

    private var maxLength: Int { payloadLimit + ProtocolConstants.recordOverhead }

    public mutating func append(_ bytes: [UInt8]) {
        guard !failed else { return }
        guard bytes.count <= FrameDecoder.maxReadChunk else {
            fail(.chunkTooLarge)
            return
        }
        buffer.append(contentsOf: bytes)
        if bufferedCount > 4 + maxLength + FrameDecoder.maxReadChunk { fail(.bufferOverflow) }
    }

    private mutating func fail(_ error: CryptoError) {
        failed = true
        pendingError = error
        buffer.removeAll()
        start = 0
    }

    /// Next authenticated message, or nil when more bytes are needed.
    public mutating func nextMessage() throws -> Message? {
        if let e = pendingError { pendingError = nil; throw e }
        if failed { throw CryptoError.decoderFailed }
        do {
            while true {
                guard bufferedCount >= 4 else { compact(); return nil }
                var length: UInt32 = 0
                for i in 0..<4 { length |= UInt32(buffer[start + i]) << (8 * UInt32(i)) }
                guard Int(length) >= ProtocolConstants.recordOverhead, Int(length) <= maxLength else {
                    throw CryptoError.invalidRecordLength(length)
                }
                let total = 4 + Int(length)
                guard bufferedCount >= total else { compact(); return nil }
                guard counter < RecordSealer.counterLimit else { throw CryptoError.counterExhausted }
                let cipherEnd = start + total - ProtocolConstants.recordTagSize
                let plain: Data
                do {
                    let box = try AES.GCM.SealedBox(nonce: recordNonce(counter),
                                                    ciphertext: buffer[(start + 4)..<cipherEnd],
                                                    tag: buffer[cipherEnd..<(start + total)])
                    plain = try AES.GCM.open(box, using: key, authenticating: lengthBytes(length))
                } catch {
                    throw CryptoError.authenticationFailed
                }
                counter += 1
                start += total
                let type = plain[plain.startIndex]
                if let message = try Message.decode(type: type, payload: Array(plain.dropFirst())) {
                    compact()
                    return message
                }
            }
        } catch {
            failed = true
            buffer.removeAll()
            start = 0
            throw error
        }
    }

    private mutating func compact() {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 4096 && start * 2 > buffer.count {
            buffer.removeFirst(start)
            start = 0
        }
    }
}

/// Inbound side of the control connection: plain frames until the first HELLO_ACK went out, records afterwards.
public struct ControlInbound: Sendable {
    private var plain: FrameDecoder? = FrameDecoder(connection: .control)
    private var secure: RecordDecoder?

    public init() {}

    /// Plaintext bytes received but not yet consumed (always 0 once encrypted).
    public var bufferedPlaintextCount: Int { plain?.bufferedCount ?? 0 }

    /// Records accepted so far (the next expected counter); 0 while plain.
    public var recordCounter: UInt64 { secure?.counter ?? 0 }

    public mutating func append(_ bytes: [UInt8]) {
        plain?.append(bytes)
        secure?.append(bytes)
    }

    /// Throws `ProtocolError` (plain mode, or a malformed payload in an authenticated record) or `CryptoError`.
    public mutating func nextMessage() throws -> Message? {
        if secure != nil { return try secure!.nextMessage() }
        return try plain!.nextMessage()
    }

    /// From now on every inbound byte is an encrypted record. Fails when plaintext is still buffered: a client
    /// sends nothing before the first HELLO_ACK, so leftover bytes mean a misbehaving peer.
    public mutating func enableEncryption(key: SecretBytes) throws {
        guard secure == nil else { return }
        guard plain?.bufferedCount == 0 else { throw CryptoError.unexpectedPlaintext }
        plain = nil
        secure = RecordDecoder(key: key, connection: .control)
    }
}
