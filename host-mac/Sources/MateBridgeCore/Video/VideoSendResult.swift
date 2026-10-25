import Foundation

/// Why a transport refused a frame for good (T-378). `busy` is not here: it is a temporary refusal, see
/// `VideoSendResult.busy`. The raw value is the `refusal=` log token.
public enum VideoRefusal: String, CaseIterable, Sendable {
    /// The connection took the sealed record's counter but not the record (closed, write queue full). Fatal.
    case write
    /// The sealer failed (e.g. the record counter is exhausted). Fatal for the connection.
    case seal
    /// Not a valid single-fragment VIDEO_FRAME within the payload limit.
    case invalid
    /// A transport that only reports a Bool (legacy conformances and test fakes).
    case other
}

/// Result of one `VideoTransport.sendResult` (T-378, astra review 2026-10-25 proposal 2).
///
/// A `.busy` frame was neither sealed nor sent: the sender keeps the very same encoded frame and offers it again when
/// the transport is ready, so the reference chain is intact and no keyframe is needed. Only `.refused` is a loss.
public enum VideoSendResult: Equatable, Sendable {
    case accepted
    case busy
    case refused(VideoRefusal)

    public var isAccepted: Bool { self == .accepted }
}
