import Darwin

/// Outgoing bytes of one non-blocking stream socket (T-091): whole records in FIFO order plus the write offset into
/// the first one. Pure; the socket owner holds it under its lock and passes the actual `write(2)` in.
///
/// A record is only ever written from its current offset to its end before the next one starts, so a partial write
/// can never interleave two records on the wire. Each record carries a token (its completion) that is handed back
/// once the record's last byte was accepted by the kernel, or by `removeAll()` when the socket is abandoned.
public struct SocketWriteBuffer<Token> {
    /// What one `write(2)` attempt did.
    public enum WriteResult: Equatable, Sendable {
        /// The kernel accepted this many bytes (possibly fewer than offered).
        case wrote(Int)
        /// `EAGAIN` / `EWOULDBLOCK`: the send buffer is full (or the low-water mark gate is closed).
        case wouldBlock
        /// `EINTR`: retried.
        case interrupted
        /// Any other `errno`: the socket is broken.
        case failed(Int32)

        /// Maps a `write(2)` return value and `errno`.
        public static func from(returnValue n: Int, errno e: Int32) -> WriteResult {
            if n >= 0 { return .wrote(n) }
            switch e {
            case EAGAIN, EWOULDBLOCK: return .wouldBlock
            case EINTR: return .interrupted
            default: return .failed(e)
            }
        }
    }

    public enum DrainOutcome: Equatable, Sendable {
        /// Every record was written.
        case drained
        /// Records (or part of one) remain; wait until the socket is writable.
        case wouldBlock
        /// The socket failed; the remaining records were not written (call `removeAll()`).
        case failed(Int32)
    }

    /// Consecutive `EINTR`s retried within one `drain` before it gives up for now (reports `.wouldBlock`).
    public static var maxInterrupts: Int { 16 }

    private var records: [(bytes: [UInt8], token: Token)] = []
    /// Bytes of `records[0]` already written.
    private var offset = 0

    public init() {}

    public var isEmpty: Bool { records.isEmpty }
    public var pendingRecords: Int { records.count }
    /// Bytes not yet written, over all records.
    public var pendingBytes: Int { records.reduce(0) { $0 + $1.bytes.count } - offset }

    /// Bounded-queue admission: one more record of `byteCount` bytes keeps the buffer within both limits.
    public func admits(byteCount: Int, maxRecords: Int, maxBytes: Int) -> Bool {
        records.count < maxRecords && pendingBytes + byteCount <= maxBytes
    }

    public mutating func append(_ bytes: [UInt8], token: Token) {
        records.append((bytes, token))
    }

    /// Writes as much as the socket takes. `write` gets the unwritten tail of the first record and reports what the
    /// kernel did. Returns the outcome and the tokens of the records that completed, in order.
    public mutating func drain(write: (UnsafeRawBufferPointer) -> WriteResult) -> (DrainOutcome, completed: [Token]) {
        var completed: [Token] = []
        var interrupts = 0
        while let first = records.first {
            let remaining = first.bytes.count - offset
            if remaining == 0 {  // an empty record completes without a write
                completed.append(records.removeFirst().token)
                offset = 0
                continue
            }
            let result = first.bytes.withUnsafeBytes { raw in
                write(UnsafeRawBufferPointer(rebasing: raw[offset...]))
            }
            switch result {
            case .wrote(let n):
                // 0 bytes for a non-empty write, or more than offered, never happens on a sane stream socket: treat
                // it as broken rather than spin on it.
                guard n > 0, n <= remaining else { return (.failed(EIO), completed) }
                interrupts = 0
                offset += n
                if offset == first.bytes.count {
                    completed.append(records.removeFirst().token)
                    offset = 0
                }
            case .wouldBlock:
                return (.wouldBlock, completed)
            case .interrupted:
                interrupts += 1
                if interrupts >= Self.maxInterrupts { return (.wouldBlock, completed) }
            case .failed(let e):
                return (.failed(e), completed)
            }
        }
        return (.drained, completed)
    }

    /// Drops every record (partially written or not) and returns their tokens, in order.
    public mutating func removeAll() -> [Token] {
        let tokens = records.map(\.token)
        records.removeAll()
        offset = 0
        return tokens
    }
}

extension SocketWriteBuffer: Sendable where Token: Sendable {}
