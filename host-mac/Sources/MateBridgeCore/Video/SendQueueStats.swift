import Foundation

/// One reading of the video connection's TCP state (T-088). `sendQueueBytes` is the kernel send buffer byte count
/// (`tcpi_snd_sbbytes`): data handed to the kernel but not yet acknowledged by the tablet. The other fields are nil
/// when only the Network.framework metadata was readable.
public struct TcpSample: Equatable, Sendable {
    public var sendQueueBytes: UInt64
    /// Smoothed RTT and its variance in milliseconds (`tcpi_srtt`, `tcpi_rttvar`).
    public var srttMs: UInt32?
    public var rttVarMs: UInt32?
    /// Cumulative retransmitted packets of the connection (`tcpi_txretransmitpackets`).
    public var retransmitPackets: UInt64?
    /// Congestion window and peer receive window in bytes (`tcpi_snd_cwnd`, `tcpi_snd_wnd`).
    public var congestionWindowBytes: UInt32?
    public var sendWindowBytes: UInt32?

    public init(sendQueueBytes: UInt64, srttMs: UInt32? = nil, rttVarMs: UInt32? = nil,
                retransmitPackets: UInt64? = nil, congestionWindowBytes: UInt32? = nil,
                sendWindowBytes: UInt32? = nil) {
        self.sendQueueBytes = sendQueueBytes
        self.srttMs = srttMs
        self.rttVarMs = rttVarMs
        self.retransmitPackets = retransmitPackets
        self.congestionWindowBytes = congestionWindowBytes
        self.sendWindowBytes = sendWindowBytes
    }
}

/// Where a `TcpSample` came from.
public enum SendQueueSource: String, Equatable, Sendable {
    /// `getsockopt(TCP_CONNECTION_INFO)` on the connection's socket: every field.
    case tcpInfo = "tcp_info"
    /// `NWProtocolTCP.Metadata.availableSendBuffer`: the queue only.
    case nwMetadata = "nw_metadata"
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
    public var srttMs: UInt32?
    public var rttVarMs: UInt32?
    public var congestionWindowBytes: UInt32?
    public var sendWindowBytes: UInt32?
    /// Retransmitted packets during the window (nil without `tcp_info`).
    public var retransmitPackets: UInt64?
    public var source: SendQueueSource

    /// `key=value` pairs. Numbers only.
    public var logFields: String {
        func kb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / 1024) }
        func opt<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "na" }
        var out = "samples=\(samples) sendq_kb_p50_95_max=\(kb(p50Bytes))/\(kb(p95Bytes))/\(kb(maxBytes)) "
            + "rtt_ms=\(opt(srttMs)) rttvar_ms=\(opt(rttVarMs)) retx_pkts=\(opt(retransmitPackets)) "
            + "cwnd_kb=\(congestionWindowBytes.map { kb(UInt64($0)) } ?? "na") "
            + "snd_wnd_kb=\(sendWindowBytes.map { kb(UInt64($0)) } ?? "na") source=\(source.rawValue)"
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
    private var latestSource = SendQueueSource.tcpInfo
    /// Cumulative retransmit count at the end of the previous window (or at the first sample).
    private var retransmitBase: UInt64?

    public init() {}

    public mutating func record(_ sample: TcpSample, source: SendQueueSource) {
        if queueBytes.count < Self.maxSamples { queueBytes.append(sample.sendQueueBytes) } else { overflow += 1 }
        latest = sample
        latestSource = source
        if retransmitBase == nil { retransmitBase = sample.retransmitPackets }
    }

    /// Closes the window: nil when nothing was sampled since the last call.
    public mutating func take() -> SendQueueWindow? {
        guard let last = latest, !queueBytes.isEmpty else { return nil }
        var retx: UInt64?
        if let now = last.retransmitPackets {
            let base = retransmitBase ?? now
            retx = now >= base ? now - base : 0  // a smaller cumulative value means a new socket: count nothing
            retransmitBase = now
        }
        let w = SendQueueWindow(
            samples: queueBytes.count + overflow, overflow: overflow,
            p50Bytes: CadenceWindow.percentile(queueBytes, 50), p95Bytes: CadenceWindow.percentile(queueBytes, 95),
            maxBytes: queueBytes.max() ?? 0, srttMs: last.srttMs, rttVarMs: last.rttVarMs,
            congestionWindowBytes: last.congestionWindowBytes, sendWindowBytes: last.sendWindowBytes,
            retransmitPackets: retx, source: latestSource)
        queueBytes.removeAll(keepingCapacity: true)
        overflow = 0
        latest = nil
        return w
    }
}
