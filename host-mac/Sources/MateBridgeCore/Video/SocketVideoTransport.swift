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
    /// Write progress for the stall signal (T-379): the record being written and the bytes of finished records.
    private let clockUs: @Sendable () -> UInt64
    private var writeStartedUs: UInt64?
    private var writeBytes = 0
    private var completedBytes: UInt64 = 0

    /// - Parameter clockUs: monotone microseconds; stamps the start of a write for `writeObservation`. The owner of
    ///   the stall detector reads the same clock.
    public init(connection: BsdTcpConnection, sealer: RecordSealer,
                clockUs: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000 }) {
        self.connection = connection
        self.sealer = sealer
        self.clockUs = clockUs
        connection.setWritableHandler { [weak self] in self?.fireReady() }
    }

    public var canSend: Bool {
        let inFlight = lock.withLock { self.inFlight }
        // A record of ours is still in user space: its completion wakes the sender, no need to ask the socket (which
        // would arm its writable notification).
        guard inFlight < SocketVideoGate.maxRecordsInFlight else { return false }
        guard SocketVideoGate.canSend(recordsInFlight: inFlight, socketBelowLowat: connection.isWritableForNewRecord)
        else { return false }
        return true
    }

    /// What the stall signal needs (T-379): bytes the kernel has accepted from this connection's video writes (a
    /// record in progress counts for what it has handed over so far) and when the record in progress started.
    public struct WriteObservation: Equatable, Sendable {
        public var progressBytes: UInt64
        public var writeStartedUs: UInt64?
    }

    public func writeObservation() -> WriteObservation {
        let (done, started, size) = lock.withLock { (completedBytes, writeStartedUs, writeBytes) }
        guard started != nil else { return WriteObservation(progressBytes: done, writeStartedUs: nil) }
        // `pendingBytes` takes the connection's lock, after ours was released. If the record finished meanwhile the
        // pending count is 0 and the sum is the true total; it never goes backwards.
        let pending = min(connection.pendingBytes, size)
        return WriteObservation(progressBytes: done + UInt64(size - pending), writeStartedUs: started)
    }

    public func setReadyHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { readyHandler = handler }
    }

    @discardableResult
    public func send(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        sendFrame(frame, completion: completion) == .sent
    }

    public func sendResult(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void) -> VideoSendResult {
        switch sendFrame(frame, completion: completion) {
        case .sent: return .accepted
        case .busy: return .busy
        case .writeRefused: return .refused(.write)
        case .invalid: return .refused(.invalid)
        case .sealFailed: return .refused(.seal)
        }
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
        writeStartedUs = clockUs()
        writeBytes = bytes.count
        let recordBytes = bytes.count
        // Never calls back inside `write`, so holding `lock` here cannot deadlock.
        let queued = connection.write(bytes) { [weak self] ok in
            guard let self else { return completion(ok) }
            let ready = lock.withLock {
                inFlight -= 1
                writeStartedUs = nil
                if ok { completedBytes += UInt64(recordBytes) }
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
