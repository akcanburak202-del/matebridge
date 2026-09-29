import Foundation

/// One measurement window of the host frame cadence (T-017): where do frames go between the screen and the socket?
/// Pure value type; `CadenceMeter` wraps it with a lock for the capture/encoder threads.
public struct CadenceWindow: Sendable {
    /// Target frame interval (1 / stream fps) in microseconds; intervals above 1.5x count as late.
    public var targetIntervalUs: UInt64
    public var durationUs: UInt64 = 0

    /// Intervals between consecutive `complete` frames, by ScreenCaptureKit's own presentation timestamps.
    public private(set) var captureIntervalsUs: [UInt64] = []
    /// Same, by the time the sample handler was called (adds delivery jitter).
    public private(set) var arrivalIntervalsUs: [UInt64] = []
    /// SCK frame status name -> count (complete, idle, blank, suspended, started, stopped, unknown).
    public private(set) var statusCounts: [String: Int] = [:]
    public private(set) var encoderIn = 0
    public private(set) var encoderOut = 0
    /// Captured frames replaced in the single `pending` slot before the encoder took them (newest wins).
    public private(set) var overwritten = 0
    public private(set) var encodeTimesUs: [UInt64] = []
    public var queueDrops = 0
    public var sent = 0

    static let maxSamples = 2048

    public init(targetIntervalUs: UInt64) { self.targetIntervalUs = targetIntervalUs }

    public var captured: Int { statusCounts["complete"] ?? 0 }

    public mutating func recordStatus(_ name: String) { statusCounts[name, default: 0] += 1 }
    public mutating func recordCaptureInterval(_ us: UInt64) {
        if captureIntervalsUs.count < Self.maxSamples { captureIntervalsUs.append(us) }
    }
    public mutating func recordArrivalInterval(_ us: UInt64) {
        if arrivalIntervalsUs.count < Self.maxSamples { arrivalIntervalsUs.append(us) }
    }
    public mutating func recordEncoderIn() { encoderIn += 1 }
    public mutating func recordOverwritten() { overwritten += 1 }
    public mutating func recordEncoderOut(encodeTimeUs: UInt64) {
        encoderOut += 1
        if encodeTimesUs.count < Self.maxSamples { encodeTimesUs.append(encodeTimeUs) }
    }

    /// Adds another window (for run totals).
    public mutating func merge(_ o: CadenceWindow) {
        durationUs += o.durationUs
        captureIntervalsUs += o.captureIntervalsUs.prefix(max(0, Self.maxSamples - captureIntervalsUs.count))
        arrivalIntervalsUs += o.arrivalIntervalsUs.prefix(max(0, Self.maxSamples - arrivalIntervalsUs.count))
        for (k, v) in o.statusCounts { statusCounts[k, default: 0] += v }
        encoderIn += o.encoderIn
        encoderOut += o.encoderOut
        overwritten += o.overwritten
        encodeTimesUs += o.encodeTimesUs.prefix(max(0, Self.maxSamples - encodeTimesUs.count))
        queueDrops += o.queueDrops
        sent += o.sent
    }

    /// Nearest-rank percentile (p in 0...100) of unsorted samples; 0 for an empty set.
    public static func percentile(_ samples: [UInt64], _ p: Double) -> UInt64 {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    /// Intervals longer than 1.5x the target.
    public var lateCaptureIntervals: Int {
        captureIntervalsUs.filter { Double($0) > 1.5 * Double(targetIntervalUs) }.count
    }
    public var lateArrivalIntervals: Int {
        arrivalIntervalsUs.filter { Double($0) > 1.5 * Double(targetIntervalUs) }.count
    }

    private func perSecond(_ n: Int) -> Double {
        durationUs == 0 ? 0 : Double(n) * 1_000_000 / Double(durationUs)
    }
    public var captureFps: Double { perSecond(captured) }
    public var encoderOutFps: Double { perSecond(encoderOut) }
    public var sentFps: Double { perSecond(sent) }

    /// Nothing happened in this window (static screen, no consumer): the caller may skip logging it.
    public var isEmpty: Bool { statusCounts.isEmpty && encoderIn == 0 && encoderOut == 0 && sent == 0 }

    private static func ms(_ us: UInt64) -> String { String(format: "%.1f", Double(us) / 1000) }

    /// `key=value` pairs for `component=video ev=cadence`. Numbers only.
    public var logFields: String {
        let status = statusCounts.keys.sorted().map { "\($0)=\(statusCounts[$0]!)" }.joined(separator: ",")
        func pct(_ s: [UInt64]) -> String {
            "\(Self.ms(Self.percentile(s, 50)))/\(Self.ms(Self.percentile(s, 95)))/\(Self.ms(Self.percentile(s, 99)))"
        }
        return "target_ms=\(Self.ms(targetIntervalUs)) cap=\(captured) cap_fps=\(String(format: "%.1f", captureFps))"
            + " cap_int_ms_p50_95_99=\(pct(captureIntervalsUs)) cap_late=\(lateCaptureIntervals)"
            + " arr_int_ms_p50_95_99=\(pct(arrivalIntervalsUs)) arr_late=\(lateArrivalIntervals)"
            + " status=\(status.isEmpty ? "none" : status)"
            + " enc_in=\(encoderIn) enc_out=\(encoderOut) enc_fps=\(String(format: "%.1f", encoderOutFps))"
            + " enc_ms_p50_95=\(Self.ms(Self.percentile(encodeTimesUs, 50)))/\(Self.ms(Self.percentile(encodeTimesUs, 95)))"
            + " overwritten=\(overwritten) queue_drops=\(queueDrops) sent=\(sent) sent_fps=\(String(format: "%.1f", sentFps))"
    }

    /// Short text for the menu line.
    public var menuText: String {
        String(format: "cap %.0f / enc %.0f / sent %.0f fps", captureFps, encoderOutFps, sentFps)
    }
}

/// Thread-safe recorder around `CadenceWindow`. Capture callbacks, the encoder and the coordinator tick share it.
public final class CadenceMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var window: CadenceWindow
    private var windowStartUs: UInt64?
    private var lastCapturePtsUs: UInt64?
    private var lastArrivalUs: UInt64?
    private var lastQueueDrops = 0
    private var lastSent = 0
    private let targetIntervalUs: UInt64

    public init(fps: Int) {
        targetIntervalUs = 1_000_000 / UInt64(max(1, fps))
        window = CadenceWindow(targetIntervalUs: targetIntervalUs)
    }

    /// One sample-buffer callback from ScreenCaptureKit. Intervals are measured only between `complete` frames.
    public func recordCapture(status: String, ptsUs: UInt64, arrivalUs: UInt64) {
        lock.lock(); defer { lock.unlock() }
        window.recordStatus(status)
        guard status == "complete" else { return }
        if let last = lastCapturePtsUs, ptsUs >= last { window.recordCaptureInterval(ptsUs - last) }
        if let last = lastArrivalUs, arrivalUs >= last { window.recordArrivalInterval(arrivalUs - last) }
        lastCapturePtsUs = ptsUs
        lastArrivalUs = arrivalUs
    }

    /// Starts the clock of the first window (call when capture starts).
    public func start(nowUs: UInt64) {
        lock.lock(); windowStartUs = nowUs; lock.unlock()
    }

    public func recordEncoderIn() { lock.lock(); window.recordEncoderIn(); lock.unlock() }
    public func recordOverwritten() { lock.lock(); window.recordOverwritten(); lock.unlock() }
    public func recordEncoderOut(encodeTimeUs: UInt64) {
        lock.lock(); window.recordEncoderOut(encodeTimeUs: encodeTimeUs); lock.unlock()
    }

    /// Closes the current window and starts the next. `queueDropsTotal` and `sentTotal` are cumulative counters of
    /// the queue and the sender; the window gets their delta (a counter that went backwards was reset: use it as is).
    /// Without `start`, the first window has duration 0.
    public func take(nowUs: UInt64, queueDropsTotal: Int, sentTotal: Int) -> CadenceWindow {
        lock.lock(); defer { lock.unlock() }
        var w = window
        w.durationUs = windowStartUs.map { nowUs > $0 ? nowUs - $0 : 0 } ?? 0
        w.queueDrops = queueDropsTotal >= lastQueueDrops ? queueDropsTotal - lastQueueDrops : queueDropsTotal
        w.sent = sentTotal >= lastSent ? sentTotal - lastSent : sentTotal
        lastQueueDrops = queueDropsTotal
        lastSent = sentTotal
        window = CadenceWindow(targetIntervalUs: targetIntervalUs)
        windowStartUs = nowUs
        return w
    }
}
