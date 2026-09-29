/// A violation of docs/PROTOCOL.md by the peer. Carries no payload content (privacy).
public enum ProtocolError: Error, Equatable, Sendable {
    /// Known message type whose payload is shorter than its fixed layout.
    case payloadTooShort(type: UInt8)
    /// Header length exceeds the per-connection limit.
    case payloadTooLarge(length: UInt32, limit: Int)
    /// A field holds a value the protocol declares invalid (tool, action, count, ...).
    case invalidField(String)
    /// An f32 field is NaN or infinite.
    case nonFiniteFloat(String)
    /// PEN samples with a decreasing dt_us.
    case decreasingSampleTime
    /// Bytes were fed without draining: buffered data exceeded header + max payload.
    case bufferOverflow
    /// The stream decoder already failed; the connection must be closed.
    case decoderFailed
}
