import Foundation

/// Backpressure decision of a kernel-socket video connection (T-091). Pure.
///
/// A new frame is taken only when none of ours is still being written from user space and the kernel holds fewer
/// unsent bytes than `TCP_NOTSENT_LOWAT` (the socket reads as writable). Otherwise the sender waits and frames pile up
/// in the 2-frame `VideoFrameQueue`, which drops the oldest delta and requests a keyframe: the same newest-frame-wins
/// path as the Network.framework link's `maxInFlight` limit, only gated on the kernel queue instead of a send count.
public enum SocketVideoGate {
    /// Records handed to the socket whose last byte the kernel has not yet accepted.
    public static let maxRecordsInFlight = 1

    public static func canSend(recordsInFlight: Int, socketBelowLowat: Bool) -> Bool {
        recordsInFlight < maxRecordsInFlight && socketBelowLowat
    }
}

/// `VideoTransport` over a `BsdTcpConnection` (T-091): every frame is one record sealed under the connection's key
/// (PROTOCOL.md section 9), exactly as on the Network.framework link. Sealing and queueing happen under one lock, so
/// record counters reach the wire in counter order.
public final class SocketVideoTransport: VideoTransport, @unchecked Sendable {
    public enum SendOutcome: Equatable, Sendable {
        case sent
        /// A record is still being written, or the kernel holds at least `TCP_NOTSENT_LOWAT` unsent bytes: nothing was
        /// sealed or sent (the same gate as `canSend`, enforced here too).
        case busy
        /// The connection refused the sealed record (closed, or its write queue is full). Its record counter is used up,
        /// so the stream cannot continue: the connection was cancelled and `completion(false)` follows.
        case writeRefused
        /// Not a valid single-fragment VIDEO_FRAME within the payload limit: nothing was sent.
        case invalid
        /// The sealer failed (e.g. the record counter is exhausted): nothing was sent, the connection cannot continue.
        case sealFailed(CryptoError)
    }

    public let connection: BsdTcpConnection
    private let lock = NSLock()
    private var sealer: RecordSealer
    private var inFlight = 0
    private var readyHandler: (@Sendable () -> Void)?

    public init(connection: BsdTcpConnection, sealer: RecordSealer) {
        self.connection = connection
        self.sealer = sealer
        connection.setWritableHandler { [weak self] in self?.fireReady() }
    }

    public var canSend: Bool {
        let inFlight = lock.withLock { self.inFlight }
        // A record of ours is still in user space: its completion wakes the sender, no need to ask the socket (which
        // would arm its writable notification).
        guard inFlight < SocketVideoGate.maxRecordsInFlight else { return false }
        return SocketVideoGate.canSend(recordsInFlight: inFlight,
                                       socketBelowLowat: connection.isWritableForNewRecord)
    }

    public func setReadyHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { readyHandler = handler }
    }

    @discardableResult
    public func send(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        sendFrame(frame, completion: completion) == .sent
    }

    /// Seals and queues one frame; see `SendOutcome`. `completion(true)` once the kernel accepted the whole record.
    public func sendFrame(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void = { _ in }) -> SendOutcome {
        let message = Message.videoFrame(frame)
        lock.lock()
        defer { lock.unlock() }
        // The full gate, before sealing: a refused frame must not use up a record counter. The socket check takes the
        // connection's lock inside ours (the same order as `write` below).
        guard inFlight < SocketVideoGate.maxRecordsInFlight,  // skip the socket check while a record is queued
              SocketVideoGate.canSend(recordsInFlight: inFlight, socketBelowLowat: connection.isWritableForNewRecord)
        else { return .busy }
        let bytes: [UInt8]
        do {
            bytes = try message.sealed(using: &sealer)
        } catch let error as CryptoError {
            return .sealFailed(error)
        } catch {
            return .invalid
        }
        inFlight += 1
        // Never calls back inside `write`, so holding `lock` here cannot deadlock.
        let queued = connection.write(bytes) { [weak self] ok in
            guard let self else { return completion(ok) }
            let ready = lock.withLock {
                inFlight -= 1
                return readyHandler
            }
            completion(ok)
            ready?()
        }
        guard queued else {
            // The sealed record never reaches the wire: the tablet would see a counter gap. End the connection.
            connection.cancel()
            return .writeRefused
        }
        return .sent
    }

    private func fireReady() {
        lock.withLock { readyHandler }?()
    }
}
