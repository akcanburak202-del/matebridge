import Foundation

/// One reading of the video connection's TCP state (T-088). `sendQueueBytes` is the kernel send buffer byte count
/// (`tcpi_snd_sbbytes`): data handed to the kernel but not yet acknowledged by the tablet. Every sample comes from
/// `getsockopt(TCP_CONNECTION_INFO)`, so all fields are always set (the Network.framework fallback went with T-186).
public struct TcpSample: Equatable, Sendable {
    public var sendQueueBytes: UInt64
    /// Smoothed RTT and its variance in milliseconds (`tcpi_srtt`, `tcpi_rttvar`).
    public var srttMs: UInt32
    public var rttVarMs: UInt32
    /// Cumulative retransmitted packets of the connection (`tcpi_txretransmitpackets`).
    public var retransmitPackets: UInt64
    /// Congestion window and peer receive window in bytes (`tcpi_snd_cwnd`, `tcpi_snd_wnd`).
    public var congestionWindowBytes: UInt32
    public var sendWindowBytes: UInt32

    public init(sendQueueBytes: UInt64, srttMs: UInt32, rttVarMs: UInt32,
                retransmitPackets: UInt64, congestionWindowBytes: UInt32,
                sendWindowBytes: UInt32) {
        self.sendQueueBytes = sendQueueBytes
        self.srttMs = srttMs
        self.rttVarMs = rttVarMs
        self.retransmitPackets = retransmitPackets
        self.congestionWindowBytes = congestionWindowBytes
        self.sendWindowBytes = sendWindowBytes
    }
}

/// One second of send-queue samples, for `component=video ev=sendq`.
public struct SendQueueWindow: Equatable, Sendable {
    public var samples: Int
    /// Samples beyond `SendQueueMeter.maxSamples` (counted, not kept).
    public var overflow: Int
    public var p50Bytes: UInt64
    public var p95Bytes: UInt64
    public var maxBytes: UInt64
    /// From the latest sample of the window.
    public var srttMs: UInt32
    public var rttVarMs: UInt32
    public var congestionWindowBytes: UInt32
    public var sendWindowBytes: UInt32
    /// Retransmitted packets during the window.
    public var retransmitPackets: UInt64

    /// `key=value` pairs. Numbers only.
    public var logFields: String {
        func kb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / 1024) }
        // `source=tcp_info` is constant since T-186 and stays so log parsers keep working.
        var out = "samples=\(samples) sendq_kb_p50_95_max=\(kb(p50Bytes))/\(kb(p95Bytes))/\(kb(maxBytes)) "
            + "rtt_ms=\(srttMs) rttvar_ms=\(rttVarMs) retx_pkts=\(retransmitPackets) "
            + "cwnd_kb=\(kb(UInt64(congestionWindowBytes))) snd_wnd_kb=\(kb(UInt64(sendWindowBytes))) source=tcp_info"
        if overflow > 0 { out += " overflow=\(overflow)" }
        return out
    }
}

/// Collects send-queue samples (one per frame write) and closes a window about once a second. Pure and bounded; the
/// host owns one under a lock.
public struct SendQueueMeter: Sendable {
    /// At 144 fps one second is 144 samples; the cap only guards against a runaway caller.
    public static let maxSamples = 2048

    private var queueBytes: [UInt64] = []
    private var overflow = 0
    private var latest: TcpSample?
    /// Cumulative retransmit count at the end of the previous window (or at the first sample).
    private var retransmitBase: UInt64?

    public init() {}

    public mutating func record(_ sample: TcpSample) {
        if queueBytes.count < Self.maxSamples { queueBytes.append(sample.sendQueueBytes) } else { overflow += 1 }
        latest = sample
        if retransmitBase == nil { retransmitBase = sample.retransmitPackets }
    }

    /// Closes the window: nil when nothing was sampled since the last call.
    public mutating func take() -> SendQueueWindow? {
        guard let last = latest, !queueBytes.isEmpty else { return nil }
        let now = last.retransmitPackets
        let base = retransmitBase ?? now
        let retx = now >= base ? now - base : 0  // a smaller cumulative value means a new socket: count nothing
        retransmitBase = now
        let w = SendQueueWindow(
            samples: queueBytes.count + overflow, overflow: overflow,
            p50Bytes: CadenceWindow.percentile(queueBytes, 50), p95Bytes: CadenceWindow.percentile(queueBytes, 95),
            maxBytes: queueBytes.max() ?? 0, srttMs: last.srttMs, rttVarMs: last.rttVarMs,
            congestionWindowBytes: last.congestionWindowBytes, sendWindowBytes: last.sendWindowBytes,
            retransmitPackets: retx)
        queueBytes.removeAll(keepingCapacity: true)
        overflow = 0
        latest = nil
        return w
    }
}
