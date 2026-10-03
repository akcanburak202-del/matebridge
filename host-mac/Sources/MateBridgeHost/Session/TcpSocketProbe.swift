import Darwin
import Foundation
import MateBridgeCore

/// Read-only view of the kernel TCP state behind a control or video connection (T-088): send-queue bytes, RTT,
/// retransmits. A `BsdTcpConnection` (T-091) owns its descriptor, so it is read directly with
/// `getsockopt(TCP_CONNECTION_INFO)` (`source=tcp_info`). The Network.framework variant (descriptor search plus
/// `NWProtocolTCP.Metadata` fallback) went with the `nw` socket stack in T-186.
///
/// Not thread-safe; the owner serialises calls.
final class TcpSocketProbe {
    enum Failure: String, Error {
        /// The descriptor is closed or `getsockopt` failed.
        case unavailable
    }

    private let socket: BsdTcpConnection

    init(socket: BsdTcpConnection) {
        self.socket = socket
    }

    /// One sample, or why none could be taken.
    func sample() -> Result<(TcpSample, SendQueueSource), Failure> {
        connectionInfo().map { (Self.tcpSample($0), .tcpInfo) }
    }

    /// One full `getsockopt(TCP_CONNECTION_INFO)` reading (T-126).
    func connectionInfo() -> Result<tcp_connection_info, Failure> {
        // The connection checks under its lock that the descriptor is still open.
        guard let info = socket.connectionInfo() else { return .failure(.unavailable) }
        return .success(info)
    }

    /// Bytes still queued in user space.
    var userPendingBytes: Int { socket.pendingBytes }

    private static func tcpSample(_ info: tcp_connection_info) -> TcpSample {
        TcpSample(sendQueueBytes: UInt64(info.tcpi_snd_sbbytes), srttMs: info.tcpi_srtt, rttVarMs: info.tcpi_rttvar,
                  retransmitPackets: info.tcpi_txretransmitpackets, congestionWindowBytes: info.tcpi_snd_cwnd,
                  sendWindowBytes: info.tcpi_snd_wnd)
    }
}

/// Thread-safe send-queue sampler of one video connection: a probe plus a `SendQueueMeter`.
final class SendQueueSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let probe: TcpSocketProbe
    private var meter = SendQueueMeter()
    private var failure: TcpSocketProbe.Failure?
    private var failureReported = false

    init(socket: BsdTcpConnection) { probe = TcpSocketProbe(socket: socket) }

    /// Takes one sample (call right before a frame is written: the queue this frame waits behind).
    func sample() {
        lock.withLock {
            switch probe.sample() {
            case .success(let (s, source)):
                meter.record(s, source: source)
                failure = nil
            case .failure(let f):
                failure = f
            }
        }
    }

    enum Report {
        case window(SendQueueWindow)
        /// No sample could be taken; reported once per connection.
        case unavailable(String)
    }

    /// Closes the window (about once a second).
    func take() -> Report? {
        lock.withLock {
            if let w = meter.take() { return .window(w) }
            if let failure, !failureReported {
                failureReported = true
                return .unavailable(failure.rawValue)
            }
            return nil
        }
    }
}

/// Per-second TCP state of one control or video connection (T-126, `net ev=tcp`): a probe plus a `TcpInfoMeter`.
/// Separate from the per-frame `SendQueueSampler` (`ev=sendq`); both only read the socket. Not thread-safe: the
/// session server uses it on its queue only.
final class TcpInfoSampler {
    let role: TcpConnectionRole
    private let probe: TcpSocketProbe
    private var meter = TcpInfoMeter()
    private var failureReported = false

    init(role: TcpConnectionRole, socket: BsdTcpConnection) {
        self.role = role
        probe = TcpSocketProbe(socket: socket)
    }

    enum Report {
        case reading(TcpInfoReport)
        /// No reading could be taken; reported once per connection.
        case unavailable(String)
    }

    /// One reading. `closeWindow`: the per-second line (moves the delta base); otherwise a snapshot between windows.
    /// nil when the reading failed and that was already reported.
    func read(closeWindow: Bool) -> Report? {
        switch probe.connectionInfo() {
        case .success(let info):
            let snapshot = TcpConnectionSnapshot(info, userPendingBytes: probe.userPendingBytes)
            return .reading(closeWindow ? meter.take(snapshot) : meter.peek(snapshot))
        case .failure(let failure):
            guard !failureReported else { return nil }
            failureReported = true
            return .unavailable(failure.rawValue)
        }
    }
}
