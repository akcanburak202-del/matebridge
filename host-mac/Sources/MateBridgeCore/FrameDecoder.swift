/// Incremental stream decoder: feed arbitrary byte chunks, pull complete messages.
///
/// Unknown message types are skipped. After any `ProtocolError` the decoder is failed for good
/// (the caller closes the connection per PROTOCOL.md 2); later calls throw `.decoderFailed`.
public struct FrameDecoder: Sendable {
    public enum Connection: Sendable {
        /// `.files`: a Wi-Fi file connection (decision 0035); the same payload limit as the control connection.
        case control, video, files

        public var maxPayload: Int {
            switch self {
            case .control, .files: ProtocolConstants.maxControlPayload
            case .video: ProtocolConstants.maxVideoPayload
            }
        }
    }

    public let connection: Connection
    private var buffer: [UInt8] = []
    private var start = 0
    private var failed = false
    private var pendingError: ProtocolError?

    public init(connection: Connection) { self.connection = connection }

    /// Bytes buffered and not yet consumed.
    public var bufferedCount: Int { buffer.count - start }

    /// Largest input accepted per `append` call, and the slack the total-buffer cap allows on top of
    /// `headerSize + maxPayload`. Larger calls are a caller error (`.chunkTooLarge`).
    public static let maxReadChunk = 65_536

    // Append-time frame scanner: validates each header the moment its 5 bytes are buffered.
    private var scanHeaderFill = 0
    private var scanPayloadRemaining = 0
    private var scanStopped = false  // an oversized header is buffered; nothing after it is kept

    /// Feed received bytes, then drain with `nextMessage()` until it returns nil.
    /// Each header is checked as soon as it is complete, so an oversized length never causes its payload
    /// to be buffered. Total buffered bytes are capped at `headerSize + maxPayload + maxReadChunk`; beyond
    /// that (counting only bytes not yet returned by `nextMessage()`) the next `nextMessage()` throws `.bufferOverflow`.
    public mutating func append(_ bytes: [UInt8]) { append(bytes[...]) }

    /// Slices are honored by their own indices (`startIndex` need not be 0).
    public mutating func append(_ bytes: ArraySlice<UInt8>) {
        guard !failed, !scanStopped else { return }
        guard bytes.count <= Self.maxReadChunk else {
            failed = true
            pendingError = .chunkTooLarge
            buffer.removeAll()
            start = 0
            return
        }
        var i = bytes.startIndex
        while i < bytes.endIndex {
            if scanPayloadRemaining > 0 {
                let n = min(scanPayloadRemaining, bytes.endIndex - i)
                buffer.append(contentsOf: bytes[i..<i + n])
                scanPayloadRemaining -= n
                i += n
            } else {
                buffer.append(bytes[i])
                i += 1
                scanHeaderFill += 1
                if scanHeaderFill == ProtocolConstants.headerSize {
                    scanHeaderFill = 0
                    var length: UInt32 = 0
                    for k in 0..<4 { length |= UInt32(buffer[buffer.count - 4 + k]) << (8 * UInt32(k)) }
                    if Int(length) > connection.maxPayload {
                        scanStopped = true  // header stays buffered; nextMessage() reports it
                        return
                    }
                    scanPayloadRemaining = Int(length)
                }
            }
            if bufferedCount > ProtocolConstants.headerSize + connection.maxPayload + Self.maxReadChunk {
                failed = true
                pendingError = .bufferOverflow
                buffer.removeAll()
                start = 0
                return
            }
        }
    }

    /// Next complete known message, or nil when more bytes are needed.
    public mutating func nextMessage() throws -> Message? {
        if let e = pendingError { pendingError = nil; throw e }
        if failed { throw ProtocolError.decoderFailed }
        do {
            while true {
                guard bufferedCount >= ProtocolConstants.headerSize else { compact(); return nil }
                let type = buffer[start]
                var length: UInt32 = 0
                for i in 0..<4 { length |= UInt32(buffer[start + 1 + i]) << (8 * UInt32(i)) }
                guard Int(length) <= connection.maxPayload else {
                    throw ProtocolError.payloadTooLarge(length: length, limit: connection.maxPayload)
                }
                let total = ProtocolConstants.headerSize + Int(length)
                guard bufferedCount >= total else { compact(); return nil }
                let payload = Array(buffer[(start + ProtocolConstants.headerSize)..<(start + total)])
                start += total
                if let message = try Message.decode(type: type, payload: payload) {
                    compact()
                    return message
                }
                // Unknown type: skipped, keep scanning.
            }
        } catch {
            failed = true
            buffer.removeAll()
            start = 0
            throw error
        }
    }

    /// Drop consumed bytes once they dominate the buffer, keeping appends amortized O(1).
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
