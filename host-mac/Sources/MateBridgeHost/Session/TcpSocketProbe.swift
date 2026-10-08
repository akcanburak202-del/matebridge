import Darwin
import Foundation
import MateBridgeCore

/// Why a sampler could take no reading: the descriptor is closed or `getsockopt` failed.
private let tcpInfoUnavailable = "unavailable"

/// Read-only view of the kernel TCP state behind a control or video connection (T-088): send-queue bytes, RTT,
/// retransmits. A `BsdTcpConnection` (T-091) owns its descriptor, so it is read directly with
/// `getsockopt(TCP_CONNECTION_INFO)` (`source=tcp_info`); the connection checks under its lock that the descriptor is
/// still open. The Network.framework variant went with the `nw` socket stack in T-186.

/// Thread-safe send-queue sampler of one video connection: a probe plus a `SendQueueMeter`.
final class SendQueueSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let socket: BsdTcpConnection
    private var meter = SendQueueMeter()
    private var unavailable = false
    private var failureReported = false

    init(socket: BsdTcpConnection) { self.socket = socket }

    /// Takes one sample (call right before a frame is written: the queue this frame waits behind).
    func sample() {
        lock.withLock {
            if let info = socket.connectionInfo() {
                meter.record(Self.tcpSample(info))
                unavailable = false
            } else {
                unavailable = true
            }
        }
    }

    private static func tcpSample(_ info: tcp_connection_info) -> TcpSample {
        TcpSample(sendQueueBytes: UInt64(info.tcpi_snd_sbbytes), srttMs: info.tcpi_srtt, rttVarMs: info.tcpi_rttvar,
                  retransmitPackets: info.tcpi_txretransmitpackets, congestionWindowBytes: info.tcpi_snd_cwnd,
                  sendWindowBytes: info.tcpi_snd_wnd)
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
            if unavailable, !failureReported {
                failureReported = true
                return .unavailable(tcpInfoUnavailable)
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
    private let socket: BsdTcpConnection
    private var meter = TcpInfoMeter()
    private var failureReported = false

    init(role: TcpConnectionRole, socket: BsdTcpConnection) {
        self.role = role
        self.socket = socket
    }

    enum Report {
        case reading(TcpInfoReport)
        /// No reading could be taken; reported once per connection.
        case unavailable(String)
    }

    /// One reading. `closeWindow`: the per-second line (moves the delta base); otherwise a snapshot between windows.
    /// nil when the reading failed and that was already reported.
    func read(closeWindow: Bool) -> Report? {
        guard let info = socket.connectionInfo() else {
            guard !failureReported else { return nil }
            failureReported = true
            return .unavailable(tcpInfoUnavailable)
        }
        let snapshot = TcpConnectionSnapshot(info, userPendingBytes: socket.pendingBytes)
        return .reading(closeWindow ? meter.take(snapshot) : meter.peek(snapshot))
    }
}
