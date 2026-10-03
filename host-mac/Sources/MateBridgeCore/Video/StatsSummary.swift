import Foundation

/// Human-readable form of a client `STATS` message, for the menu and `host.log`. Contains numbers only.
public struct StatsSummary: Equatable, Sendable {
    public var fps: Double
    public var bitrateKbps: Double
    /// Tablet capture->decode: wire capture stamp to decoder output (T-168), not to the screen; nil when the client
    /// could not estimate it (reported as 0).
    public var latencyMs: Double?
    public var decodeMs: Double
    public var framesDropped: Int

    public init(_ s: Stats) {
        let seconds = Double(s.intervalMs) / 1000
        fps = seconds > 0 ? Double(s.framesRendered) / seconds : 0
        bitrateKbps = seconds > 0 ? Double(s.bytesReceived) * 8 / 1000 / seconds : 0
        latencyMs = s.latencyAvgUs == 0 ? nil : Double(s.latencyAvgUs) / 1000
        decodeMs = Double(s.decodeTimeAvgUs) / 1000
        framesDropped = Int(s.framesDropped)
    }

    public var menuText: String {
        var t = String(format: "%.0f fps · %.1f Mbit/s", fps, bitrateKbps / 1000)
        if let latencyMs { t += String(format: " · yak→çöz %.0f ms", latencyMs) }
        return t
    }

    /// `key=value` pairs for a log line. `cap_dec_ms` is the tablet capture->decode time; `latency_ms` is the same
    /// value under its old name, kept for one release (T-170) so existing log scripts keep working.
    public var logFields: String {
        let latency = latencyMs.map { String(format: "%.1f", $0) } ?? "unknown"
        return String(format: "fps=%.1f kbps=%.0f decode_ms=%.1f dropped=%d", fps, bitrateKbps, decodeMs, framesDropped)
            + " cap_dec_ms=\(latency) latency_ms=\(latency)"
    }
}
