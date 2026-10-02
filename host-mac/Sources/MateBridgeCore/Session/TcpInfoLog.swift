import Darwin
import Foundation

/// One `getsockopt(TCP_CONNECTION_INFO)` reading of a control or video connection (T-126). Cumulative counters are
/// kept raw; `TcpInfoMeter` turns them into per-window deltas.
public struct TcpConnectionSnapshot: Equatable, Sendable {
    /// Retransmit timeout, smoothed RTT, RTT variance and most recent RTT, in milliseconds.
    public var rtoMs: UInt32
    public var srttMs: UInt32
    public var rttVarMs: UInt32
    public var rttCurMs: UInt32
    /// Congestion window, peer receive window and slow-start threshold, in bytes.
    public var congestionWindowBytes: UInt32
    public var sendWindowBytes: UInt32
    public var slowStartThresholdBytes: UInt32
    /// Kernel send buffer: bytes not yet acknowledged plus bytes not yet sent (`tcpi_snd_sbbytes`).
    public var sendBufferBytes: UInt32
    /// Cumulative counters of the connection.
    public var txPackets: UInt64
    public var retransmitPackets: UInt64
    public var retransmitBytes: UInt64
    /// Received out-of-order bytes (peer -> host direction).
    public var outOfOrderBytes: UInt64
    /// `TCPCI_FLAG_LOSSRECOVERY` was set at the reading.
    public var lossRecovery: Bool
    /// Bytes still queued in user space (`BsdTcpConnection.pendingBytes`); nil when the stack cannot tell.
    public var userPendingBytes: Int?

    public init(rtoMs: UInt32 = 0, srttMs: UInt32 = 0, rttVarMs: UInt32 = 0, rttCurMs: UInt32 = 0,
                congestionWindowBytes: UInt32 = 0, sendWindowBytes: UInt32 = 0, slowStartThresholdBytes: UInt32 = 0,
                sendBufferBytes: UInt32 = 0, txPackets: UInt64 = 0, retransmitPackets: UInt64 = 0,
                retransmitBytes: UInt64 = 0, outOfOrderBytes: UInt64 = 0, lossRecovery: Bool = false,
                userPendingBytes: Int? = nil) {
        self.rtoMs = rtoMs
        self.srttMs = srttMs
        self.rttVarMs = rttVarMs
        self.rttCurMs = rttCurMs
        self.congestionWindowBytes = congestionWindowBytes
        self.sendWindowBytes = sendWindowBytes
        self.slowStartThresholdBytes = slowStartThresholdBytes
        self.sendBufferBytes = sendBufferBytes
        self.txPackets = txPackets
        self.retransmitPackets = retransmitPackets
        self.retransmitBytes = retransmitBytes
        self.outOfOrderBytes = outOfOrderBytes
        self.lossRecovery = lossRecovery
        self.userPendingBytes = userPendingBytes
    }

    public init(_ info: tcp_connection_info, userPendingBytes: Int? = nil) {
        self.init(rtoMs: info.tcpi_rto, srttMs: info.tcpi_srtt, rttVarMs: info.tcpi_rttvar, rttCurMs: info.tcpi_rttcur,
                  congestionWindowBytes: info.tcpi_snd_cwnd, sendWindowBytes: info.tcpi_snd_wnd,
                  slowStartThresholdBytes: info.tcpi_snd_ssthresh, sendBufferBytes: info.tcpi_snd_sbbytes,
                  txPackets: info.tcpi_txpackets, retransmitPackets: info.tcpi_txretransmitpackets,
                  retransmitBytes: info.tcpi_txretransmitbytes, outOfOrderBytes: info.tcpi_rxoutoforderbytes,
                  lossRecovery: info.tcpi_flags & UInt32(TCPCI_FLAG_LOSSRECOVERY) != 0,
                  userPendingBytes: userPendingBytes)
    }

    /// Estimated sent-but-unacknowledged bytes. The public API does not split the send buffer; with Nagle off
    /// everything the windows allow is on the wire, so in flight is at most `min(cwnd, snd_wnd)`.
    public var unackedBytesEstimate: UInt32 {
        min(sendBufferBytes, min(congestionWindowBytes, sendWindowBytes))
    }

    /// Estimated bytes in the kernel that were not sent yet: the send buffer beyond the estimated in-flight bytes.
    public var notSentBytesEstimate: UInt32 { sendBufferBytes - unackedBytesEstimate }
}

/// Which connection a `ev=tcp` line describes.
public enum TcpConnectionRole: String, Equatable, Sendable {
    case control
    case video
}

/// One reading with the counter deltas since the previous window, for `net ev=tcp` / `ev=tcp_snap`.
public struct TcpInfoReport: Equatable, Sendable {
    public var snapshot: TcpConnectionSnapshot
    public var retransmitPacketsDelta: UInt64
    public var retransmitBytesDelta: UInt64
    public var outOfOrderBytesDelta: UInt64
    public var txPacketsDelta: UInt64

    /// `conn=<role> conn_id=<n> retx_pkts_delta=… … loss_recovery=0|1`. Numbers only.
    public func logFields(role: TcpConnectionRole, connectionID: UInt64) -> String {
        let s = snapshot
        return "conn=\(role.rawValue) conn_id=\(connectionID) retx_pkts_delta=\(retransmitPacketsDelta) "
            + "rxmit_bytes_delta=\(retransmitBytesDelta) ooo_bytes_delta=\(outOfOrderBytesDelta) "
            + "tx_pkts_delta=\(txPacketsDelta) srtt_ms=\(s.srttMs) rttvar_ms=\(s.rttVarMs) rttcur_ms=\(s.rttCurMs) "
            + "rto_ms=\(s.rtoMs) snd_cwnd=\(s.congestionWindowBytes) snd_wnd=\(s.sendWindowBytes) "
            + "ssthresh=\(s.slowStartThresholdBytes) sndbuf_bytes=\(s.sendBufferBytes) "
            + "unacked_bytes=\(s.unackedBytesEstimate) notsent_bytes=\(s.notSentBytesEstimate) "
            + "user_pending_bytes=\(s.userPendingBytes.map { "\($0)" } ?? "na") "
            + "loss_recovery=\(s.lossRecovery ? 1 : 0)"
    }
}

/// Per-connection window over cumulative TCP counters. A meter starts at zero, so the first window counts from the
/// start of the connection. A counter that went down (a different socket) counts as zero. Pure value; the owner
/// serialises calls.
public struct TcpInfoMeter: Equatable, Sendable {
    private var retransmitPackets: UInt64 = 0
    private var retransmitBytes: UInt64 = 0
    private var outOfOrderBytes: UInt64 = 0
    private var txPackets: UInt64 = 0

    public init() {}

    /// Closes the window at this reading: deltas since the previous `take`, and the base moves to this reading.
    public mutating func take(_ s: TcpConnectionSnapshot) -> TcpInfoReport {
        let report = peek(s)
        retransmitPackets = s.retransmitPackets
        retransmitBytes = s.retransmitBytes
        outOfOrderBytes = s.outOfOrderBytes
        txPackets = s.txPackets
        return report
    }

    /// Deltas since the previous `take` without moving the base (the debug snapshot between windows).
    public func peek(_ s: TcpConnectionSnapshot) -> TcpInfoReport {
        func delta(_ now: UInt64, _ base: UInt64) -> UInt64 { now >= base ? now - base : 0 }
        return TcpInfoReport(snapshot: s, retransmitPacketsDelta: delta(s.retransmitPackets, retransmitPackets),
                             retransmitBytesDelta: delta(s.retransmitBytes, retransmitBytes),
                             outOfOrderBytesDelta: delta(s.outOfOrderBytes, outOfOrderBytes),
                             txPacketsDelta: delta(s.txPackets, txPackets))
    }
}

/// `MATEBRIDGE_TCP_LOG=0|1` (T-126): the per-second `net ev=tcp` lines of the control and video sockets.
/// - `off` (`0`): never.
/// - `on` (`1`): every session, USB included.
/// - `auto` (unset or anything else): Wi-Fi sessions; USB sessions only with `MATEBRIDGE_SENDQ_LOG=1` or
///   `MATEBRIDGE_LAT_TRACE=1` (over the adb loopback tunnel RTT and retransmits carry no information).
public enum TcpInfoLogKnob: String, Equatable, Sendable {
    case auto
    case on
    case off

    public static func parse(_ env: [String: String]) -> TcpInfoLogKnob {
        switch env["MATEBRIDGE_TCP_LOG"]?.trimmingCharacters(in: .whitespaces) {
        case "0": return .off
        case "1": return .on
        default: return .auto
        }
    }

    /// Whether a session over `transport` logs `ev=tcp`. `sendQueueLog` is `SendQueueLogKnob.isEnabled`.
    public func isEnabled(transport: SessionTransport, sendQueueLog: Bool) -> Bool {
        switch self {
        case .off: return false
        case .on: return true
        case .auto: return transport == .network || sendQueueLog
        }
    }
}
