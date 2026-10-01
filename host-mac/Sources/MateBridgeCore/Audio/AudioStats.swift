import Foundation

/// One second of audio sender counters for the `component=audio ev=stats` line (decision 0011: counters and a numeric
/// level only, never content).
public struct AudioStatsWindow: Equatable, Sendable {
    public private(set) var packets = 0
    /// Packets dropped before the wire: ring overflow (oldest first) or overwritten while being read.
    public private(set) var dropped = 0
    /// AUDIO_FRAMEs the session server dropped because the control connection was backed up.
    public private(set) var wireDropped = 0
    /// Largest backlog seen by the sender, in milliseconds of audio.
    public private(set) var ringMsMax = 0
    private var callbackUs: [UInt64] = []
    private var sumSquares: Double = 0
    private var samples = 0

    public init() {}

    public var isEmpty: Bool { packets == 0 && dropped == 0 && wireDropped == 0 }

    public mutating func addPacket(frames: Int, channels: Int, sumSquares: Double, callbackUs: UInt64) {
        packets += 1
        samples += frames * channels
        self.sumSquares += sumSquares
        if callbackUs > 0 { self.callbackUs.append(callbackUs) }
    }

    public mutating func addDropped(_ n: Int) { dropped += max(0, n) }
    public mutating func addWireDropped(_ n: Int) { wireDropped += max(0, n) }

    public mutating func noteBacklog(packets: Int, packetMs: Int) {
        ringMsMax = max(ringMsMax, packets * packetMs)
    }

    /// RMS level in dBFS, floored at -120 (silence).
    public var rmsDbfs: Double {
        guard samples > 0, sumSquares > 0 else { return -120 }
        return max(-120, 10 * log10(sumSquares / Double(samples)))
    }

    /// Nearest-rank percentile of the callback durations, in milliseconds.
    public func callbackMs(percentile p: Double) -> Double {
        guard !callbackUs.isEmpty else { return 0 }
        let sorted = callbackUs.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return Double(sorted[min(max(rank, 0), sorted.count - 1)]) / 1000
    }

    /// `packets=… dropped=… ring_ms_max=… callback_ms_p50_95=a/b rms_dbfs=… wire_dropped=…`
    public var logFields: String {
        String(format: "packets=%d dropped=%d ring_ms_max=%d callback_ms_p50_95=%.2f/%.2f rms_dbfs=%.1f wire_dropped=%d",
               packets, dropped, ringMsMax, callbackMs(percentile: 0.5), callbackMs(percentile: 0.95), rmsDbfs,
               wireDropped)
    }
}
