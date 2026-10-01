import Foundation

/// Host-clock timestamps (microseconds, one clock) of one frame on its way from the screen to the socket (T-070).
/// A plain value that travels inside `EncodedVideoFrame`, so measuring needs no lookup tables and no allocation.
/// 0 means "not stamped".
public struct FrameTrace: Equatable, Sendable {
    /// ScreenCaptureKit presentation timestamp (the same value as `VIDEO_FRAME.capture_time_us`).
    public var captureUs: UInt64 = 0
    /// ScreenCaptureKit sample callback ran.
    public var deliveredUs: UInt64 = 0
    /// Handed to VideoToolbox (after any hold / decimation wait).
    public var submittedUs: UInt64 = 0
    /// VideoToolbox output callback ran.
    public var encodedUs: UInt64 = 0
    /// Pushed into the bounded send queue (after the Annex-B conversion).
    public var enqueuedUs: UInt64 = 0
    /// The sender pulled it from the queue and called the transport.
    public var writeStartUs: UInt64 = 0
    /// The transport reported the write as processed.
    public var writeDoneUs: UInt64 = 0

    public init() {}

    public var isComplete: Bool {
        captureUs != 0 && deliveredUs != 0 && submittedUs != 0 && encodedUs != 0 && enqueuedUs != 0
            && writeStartUs != 0 && writeDoneUs != 0
    }

    /// Saturating difference: a stage that appears to run backwards (clock granularity) counts as 0.
    private static func d(_ later: UInt64, _ earlier: UInt64) -> UInt64 { later >= earlier ? later - earlier : 0 }

    /// Capture timestamp -> SCK callback.
    public var sckLagUs: UInt64 { Self.d(deliveredUs, captureUs) }
    /// SCK callback -> submitted to the encoder (decimation / hold-last-frame / waiting for a free slot).
    public var holdUs: UInt64 { Self.d(submittedUs, deliveredUs) }
    /// Submitted -> encoder output callback.
    public var encUs: UInt64 { Self.d(encodedUs, submittedUs) }
    /// Encoder callback -> in the send queue (Annex-B conversion, parameter sets).
    public var convUs: UInt64 { Self.d(enqueuedUs, encodedUs) }
    /// In the send queue -> sender started the write (also covers waiting for a free socket slot).
    public var queueUs: UInt64 { Self.d(writeStartUs, enqueuedUs) }
    /// Write started -> write processed (sealing + socket).
    public var writeUs: UInt64 { Self.d(writeDoneUs, writeStartUs) }
    /// Capture timestamp -> write processed.
    public var capToSentUs: UInt64 { Self.d(writeDoneUs, captureUs) }

    public static let csvHeader =
        "capture_us,delivered_us,submitted_us,encoded_us,enqueued_us,write_start_us,write_done_us"

    public var csvLine: String {
        "\(captureUs),\(deliveredUs),\(submittedUs),\(encodedUs),\(enqueuedUs),\(writeStartUs),\(writeDoneUs)"
    }
}

/// One measurement window (about one second) of per-stage latencies. `ev=latency` fields:
/// `frames`, then for each stage `<stage>_ms_p50_95_99_max=p50/p95/p99/max`.
public struct LatencyWindow: Sendable {
    public static let maxSamples = 512
    public static let stageNames = ["sck_lag", "hold", "enc", "conv", "queue", "write", "cap_to_sent"]

    public private(set) var frames = 0
    private var stages: [[UInt64]]

    public init() {
        stages = Array(repeating: [], count: Self.stageNames.count)
        for i in stages.indices { stages[i].reserveCapacity(Self.maxSamples) }
    }

    /// Adds a finished frame; incomplete traces are ignored.
    public mutating func record(_ t: FrameTrace) {
        guard t.isComplete else { return }
        frames += 1
        guard stages[0].count < Self.maxSamples else { return }
        stages[0].append(t.sckLagUs)
        stages[1].append(t.holdUs)
        stages[2].append(t.encUs)
        stages[3].append(t.convUs)
        stages[4].append(t.queueUs)
        stages[5].append(t.writeUs)
        stages[6].append(t.capToSentUs)
    }

    public var isEmpty: Bool { frames == 0 }

    /// Samples of one stage (index into `stageNames`).
    public func samples(stage: Int) -> [UInt64] { stages[stage] }

    private static func ms(_ us: UInt64) -> String { String(format: "%.1f", Double(us) / 1000) }

    /// `key=value` pairs for `component=video ev=latency`. Numbers only.
    public var logFields: String {
        var out = "frames=\(frames)"
        for (i, name) in Self.stageNames.enumerated() {
            let s = stages[i]
            let p = [CadenceWindow.percentile(s, 50), CadenceWindow.percentile(s, 95),
                     CadenceWindow.percentile(s, 99), s.max() ?? 0]
            out += " \(name)_ms_p50_95_99_max=" + p.map(Self.ms).joined(separator: "/")
        }
        return out
    }
}

/// Thread-safe recorder around `LatencyWindow`: the sender's completion callbacks write, the coordinator tick reads.
public final class LatencyMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var window = LatencyWindow()

    public init() {}

    public func record(_ trace: FrameTrace) { lock.lock(); window.record(trace); lock.unlock() }

    /// Closes the current window and starts the next.
    public func take() -> LatencyWindow {
        lock.lock(); defer { lock.unlock() }
        let w = window
        window = LatencyWindow()
        return w
    }
}
