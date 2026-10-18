// Bounded output of the camera connection (T-357 r4, Codex P2). The only host-to-tablet traffic after the ACK is
// `CAM_KEYFRAME_REQUEST`. The socket's outbound buffer has no bound of its own, so a proven client that stops reading
// must not make requests pile up: a request is written only when nothing is still pending, and a connection whose output
// has not drained for `stallLimitUs` is closed.

public struct CameraOutputStallPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case send
        /// Something is still pending: this request is dropped (the gate repeats it later if still needed).
        case skip
        /// Output has been stuck too long: close the camera connection.
        case close
    }

    public static let defaultStallLimitUs: UInt64 = 5_000_000

    public var stallLimitUs: UInt64
    private var stuckSince: UInt64?

    public init(stallLimitUs: UInt64 = defaultStallLimitUs) { self.stallLimitUs = stallLimitUs }

    public mutating func request(pendingBytes: Int, now: UInt64) -> Decision {
        guard pendingBytes > 0 else {
            stuckSince = nil
            return .send
        }
        let since = stuckSince ?? now
        stuckSince = since
        return now >= since + stallLimitUs ? .close : .skip
    }

    /// Decides first, seals only when the request is sent: a skipped or dropped request must not consume a sealer
    /// counter, or the next record would not be the one the peer's opener expects (T-357 r5).
    public mutating func sealRequest(_ message: Message, with sealer: inout RecordSealer, pendingBytes: Int,
                                     now: UInt64) -> (decision: Decision, record: [UInt8]?) {
        let decision = request(pendingBytes: pendingBytes, now: now)
        guard decision == .send, let record = try? message.sealed(using: &sealer) else { return (decision, nil) }
        return (decision, record)
    }

    /// A new connection starts clean.
    public mutating func reset() { stuckSince = nil }
}
