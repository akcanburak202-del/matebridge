/// Incremental stream decoder: feed arbitrary byte chunks, pull complete messages.
///
/// Unknown message types are skipped. After any `ProtocolError` the decoder is failed for good
/// (the caller closes the connection per PROTOCOL.md 2); later calls throw `.decoderFailed`.
public struct FrameDecoder: Sendable {
    public enum Connection: Sendable {
        case control, video

        public var maxPayload: Int {
            switch self {
            case .control: ProtocolConstants.maxControlPayload
            case .video: ProtocolConstants.maxVideoPayload
            }
        }
    }

    public let connection: Connection
    private var buffer: [UInt8] = []
    private var start = 0
    private var failed = false
    private var overflowed = false

    public init(connection: Connection) { self.connection = connection }

    /// Bytes buffered and not yet consumed.
    public var bufferedCount: Int { buffer.count - start }

    /// Feed received bytes, then drain with `nextMessage()` until it returns nil. Buffered bytes stay below
    /// `headerSize + maxPayload` when drained; a caller that keeps appending without draining fails the decoder.
    public mutating func append(_ bytes: [UInt8]) { append(bytes[...]) }

    /// Slices are honored by their own indices (`startIndex` need not be 0).
    public mutating func append(_ bytes: ArraySlice<UInt8>) {
        guard !failed else { return }
        if bufferedCount > ProtocolConstants.headerSize + connection.maxPayload {
            failed = true
            overflowed = true
            buffer.removeAll()
            start = 0
            return
        }
        buffer.append(contentsOf: bytes)
    }

    /// Next complete known message, or nil when more bytes are needed.
    public mutating func nextMessage() throws -> Message? {
        if overflowed { overflowed = false; throw ProtocolError.bufferOverflow }
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
