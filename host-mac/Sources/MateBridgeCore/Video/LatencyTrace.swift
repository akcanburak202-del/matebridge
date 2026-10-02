import Foundation

/// Host-clock timestamps (microseconds, one clock) of one frame on its way from the screen to the socket (T-070).
/// A plain value that travels inside `EncodedVideoFrame`, so measuring needs no lookup tables and no allocation.
/// 0 means "not stamped".
public struct FrameTrace: Equatable, Sendable {
    /// Trace origin: the earliest of the SCK stamps (`displayUs`, `ptsUs`) and `deliveredUs` (see `origin`).
    public var captureUs: UInt64 = 0
    /// ScreenCaptureKit presentation timestamp (the same value as `VIDEO_FRAME.capture_time_us`); 0 = unknown.
    public var ptsUs: UInt64 = 0
    /// `SCStreamFrameInfo.displayTime` converted to host microseconds; 0 = SCK gave none.
    public var displayUs: UInt64 = 0
    /// Part of `holdUs` spent with both encoder slots busy (the rest is the send-rate gate); see `HEVCEncoder`.
    public var slotWaitUs: UInt64 = 0
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
    /// Metadata set by the sender (T-122): the frame is a keyframe, and its `VIDEO_FRAME` payload size.
    public var isKeyframe = false
    public var bytes = 0

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
    /// Slot-full part of the hold: the frame arrived (or waited) while `maxInFlight` frames were in the encoder.
    public var slotWaitStageUs: UInt64 { min(slotWaitUs, holdUs) }
    /// Gate part of the hold: a slot was free but the send-rate gate was closed (grid slot not yet reached).
    public var gateWaitUs: UInt64 { holdUs - slotWaitStageUs }
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

    /// The trace origin. SCK stamps that lie *after* the callback cannot be a capture time (the device showed
    /// `cap_to_sent` shorter than `enc`: both `displayTime` and the presentation timestamp lead the callback), so
    /// the origin never exceeds `deliveredUs`: `capToSentUs` is then at least the sum of the host stages. The raw
    /// stamps are reported separately and signed (`pts_vs_display`, `pts_vs_deliv`, `display_vs_deliv`).
    public static func origin(displayUs: UInt64, ptsUs: UInt64, deliveredUs: UInt64) -> UInt64 {
        var o = deliveredUs
        if displayUs != 0 { o = min(o, displayUs) }
        if ptsUs != 0 { o = min(o, ptsUs) }
        return o
    }

    /// Signed `a - b` in microseconds; nil if either stamp is unknown.
    private static func signed(_ a: UInt64, _ b: UInt64) -> Int64? {
        guard a != 0, b != 0 else { return nil }
        return Int64(bitPattern: a &- b)
    }
    /// Presentation timestamp minus display time (how far the tablet's `capture_time_us` is from the screen time).
    public var ptsVsDisplayUs: Int64? { Self.signed(ptsUs, displayUs) }
    /// Presentation timestamp minus callback time; > 0 = the stamp lies in the future of the callback.
    public var ptsVsDeliveredUs: Int64? { Self.signed(ptsUs, deliveredUs) }
    /// Display time minus callback time.
    public var displayVsDeliveredUs: Int64? { Self.signed(displayUs, deliveredUs) }

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
    public static let offsetNames = ["pts_vs_display", "pts_vs_deliv", "display_vs_deliv"]
    public static let stageNames = ["sck_lag", "hold", "gate_wait", "slot_wait", "enc", "conv", "queue", "write", "cap_to_sent"]

    public private(set) var frames = 0
    /// Frames for which SCK gave no display time.
    public private(set) var noDisplay = 0
    private var stages: [[UInt64]]
    private var offsets: [[Int64]] = Array(repeating: [], count: LatencyWindow.offsetNames.count)

    public init() {
        stages = Array(repeating: [], count: Self.stageNames.count)
        for i in stages.indices { stages[i].reserveCapacity(Self.maxSamples) }
    }

    /// Adds a finished frame; incomplete traces are ignored.
    public mutating func record(_ t: FrameTrace) {
        guard t.isComplete else { return }
        frames += 1
        if t.displayUs == 0 { noDisplay += 1 }
        guard stages[0].count < Self.maxSamples else { return }
        stages[0].append(t.sckLagUs)
        stages[1].append(t.holdUs)
        stages[2].append(t.gateWaitUs)
        stages[3].append(t.slotWaitStageUs)
        stages[4].append(t.encUs)
        stages[5].append(t.convUs)
        stages[6].append(t.queueUs)
        stages[7].append(t.writeUs)
        stages[8].append(t.capToSentUs)
        for (i, v) in [t.ptsVsDisplayUs, t.ptsVsDeliveredUs, t.displayVsDeliveredUs].enumerated() {
            if let v { offsets[i].append(v) }
        }
    }

    public var isEmpty: Bool { frames == 0 }

    /// Samples of one stage (index into `stageNames`).
    public func samples(stage: Int) -> [UInt64] { stages[stage] }

    private static func ms(_ us: UInt64) -> String { String(format: "%.1f", Double(us) / 1000) }
    private static func ms(_ us: Int64) -> String { String(format: "%.1f", Double(us) / 1000) }

    /// Nearest-rank percentile of signed samples.
    static func percentile(_ samples: [Int64], _ p: Double) -> Int64 {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    /// Samples of one signed offset (index into `offsetNames`).
    public func offsetSamples(_ i: Int) -> [Int64] { offsets[i] }

    /// `key=value` pairs for `component=video ev=latency`. Numbers only.
    public var logFields: String {
        var out = "frames=\(frames)"
        for (i, name) in Self.stageNames.enumerated() {
            let s = stages[i]
            let p = [CadenceWindow.percentile(s, 50), CadenceWindow.percentile(s, 95),
                     CadenceWindow.percentile(s, 99), s.max() ?? 0]
            out += " \(name)_ms_p50_95_99_max=" + p.map(Self.ms).joined(separator: "/")
        }
        for (i, name) in Self.offsetNames.enumerated() {
            let s = offsets[i]
            out += " \(name)_ms_p50_99=" + [Self.percentile(s, 50), Self.percentile(s, 99)].map(Self.ms).joined(separator: "/")
        }
        out += " no_display=\(noDisplay)"
        return out
    }
}

/// Mach absolute time ticks (the unit of `SCStreamFrameInfo.displayTime`) to host-clock microseconds. On Apple
/// Silicon the timebase is 125/3 (one tick = 41.67 ns), so ticks are not nanoseconds. Checked on the Mac mini with a
/// probe: `mach_timebase_info` = 125/3 and this conversion matches `CMClockGetHostTimeClock` to within the read gap.
public enum MachTime {
    public static func ticksToUs(_ ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        guard denom != 0 else { return 0 }
        let (high, low) = ticks.multipliedFullWidth(by: UInt64(numer))
        let d = UInt64(denom)
        guard high < d else { return UInt64.max / 1000 }
        let (q, _) = d.dividingFullWidth((high, low))
        return q / 1000
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
