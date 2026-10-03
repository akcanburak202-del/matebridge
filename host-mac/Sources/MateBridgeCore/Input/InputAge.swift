// Input age at delivery (T-171): diagnostics only. Nothing here changes how input is applied.
//
// The host sends PING every 500 ms on the active control connection (`SessionMachine`); the client's PONG carries its
// own clock (`responder_time_us`, `System.nanoTime()/1000`), which shares its base with the input times on the wire
// (`MotionEvent.eventTime`, CLOCK_MONOTONIC, 1 ms resolution). From PONG the host estimates the client − host clock
// offset, and every PEN sample and KEY / POINTER / SCROLL / PINCH message gets an age at delivery:
//
//     age = host_receive − (client_time − offset)
//
// Uncertainty: ±(best RTT / 2 + 1 ms). Every value that comes from the client is untrusted: the arithmetic wraps and
// never traps. Ages are kept signed; a negative age is counted (`neg`), never clamped.

/// Client − host clock offset from PONG, mirroring the client's `ClockSync` (`client/stream/ClockSync.kt`):
/// `rtt = received − echo`, `offset = responder − (echo + rtt / 2)`; the lowest-RTT sample of the last `window`
/// samples wins. A sample whose echo lies in the host's future (`rtt < 0`) is ignored.
///
/// PONG rides the same client FIFO as input, so its RTT inflates under congestion; the min-RTT window keeps the
/// estimate on the quiet samples. A jump of the client clock is forgotten once the window has rolled over.
public struct ClockOffsetEstimator: Sendable {
    public static let defaultWindow = 8

    private var rtts: [UInt64]
    private var offsets: [Int64]
    private var count = 0
    private var next = 0
    /// Samples accepted since the last `reset()`.
    public private(set) var accepted = 0

    public init(window: Int = ClockOffsetEstimator.defaultWindow) {
        precondition(window > 0)
        rtts = [UInt64](repeating: 0, count: window)
        offsets = [Int64](repeating: 0, count: window)
    }

    /// One PONG. `echoUs` is the PING's host send time, `responderUs` the client's clock when it answered, `receivedUs`
    /// the host clock now. Returns false when the sample was ignored.
    @discardableResult
    public mutating func add(echoUs: UInt64, responderUs: UInt64, receivedUs: UInt64) -> Bool {
        guard receivedUs >= echoUs else { return false }  // bogus echo, or the host clock went backwards
        let rtt = receivedUs - echoUs
        let half = Int64(truncatingIfNeeded: rtt / 2)
        let offset = Int64(truncatingIfNeeded: responderUs) &- (Int64(truncatingIfNeeded: echoUs) &+ half)
        rtts[next] = rtt
        offsets[next] = offset
        next = (next + 1) % rtts.count
        count = min(count + 1, rtts.count)
        accepted += 1
        return true
    }

    private var bestIndex: Int? {
        guard count > 0 else { return nil }
        var best = 0
        for i in 1..<count where rtts[i] < rtts[best] { best = i }
        return best
    }

    /// Client clock minus host clock, or nil before the first sample.
    public var offsetUs: Int64? { bestIndex.map { offsets[$0] } }

    /// RTT of the sample the offset comes from.
    public var bestRttUs: UInt64? { bestIndex.map { rtts[$0] } }

    public mutating func reset() {
        count = 0
        next = 0
        accepted = 0
    }
}

/// Fixed-size signed histogram of microsecond values: 16 sub-buckets per power of two (≤ 6.25 % error) from 0 to
/// 2^31 µs, an overflow bucket, and the same buckets mirrored for negative values. Storage is allocated once;
/// recording and `reset()` never allocate.
public struct AgeHistogram: Sendable {
    static let subBits = 4
    static let subCount = 1 << subBits
    static let maxExponent = 31
    /// Buckets per sign, overflow included.
    static let bucketsPerSign = subCount + (maxExponent - subBits) * subCount + 1

    /// `[0, bucketsPerSign)`: non-negative values; `[bucketsPerSign, 2 * bucketsPerSign)`: magnitudes of negative ones.
    private var buckets: [UInt64]
    public private(set) var count: UInt64 = 0
    public private(set) var negative: UInt64 = 0
    /// Exact largest value recorded (nil when empty).
    public private(set) var max: Int64?

    public init() {
        buckets = [UInt64](repeating: 0, count: 2 * Self.bucketsPerSign)
    }

    /// Test hook: the bucket storage never grows.
    var storageCountForTesting: Int { buckets.count }

    static func bucket(magnitude m: UInt64) -> Int {
        if m < UInt64(subCount) { return Int(m) }
        let e = 63 - m.leadingZeroBitCount
        if e >= maxExponent { return bucketsPerSign - 1 }
        let sub = Int((m >> UInt64(e - subBits)) & UInt64(subCount - 1))
        return subCount + (e - subBits) * subCount + sub
    }

    /// Smallest magnitude of a bucket.
    static func lowerBound(_ index: Int) -> UInt64 {
        if index < subCount { return UInt64(index) }
        if index >= bucketsPerSign - 1 { return UInt64(1) << UInt64(maxExponent) }
        let k = index - subCount
        let e = k / subCount + subBits
        return UInt64(subCount + k % subCount) << UInt64(e - subBits)
    }

    /// Largest magnitude of a bucket.
    static func upperBound(_ index: Int) -> UInt64 {
        if index < subCount { return UInt64(index) }
        if index >= bucketsPerSign - 1 { return UInt64.max }
        let k = index - subCount
        let e = k / subCount + subBits
        return lowerBound(index) + (UInt64(1) << UInt64(e - subBits)) - 1
    }

    public mutating func record(_ value: Int64) {
        if value < 0 {
            buckets[Self.bucketsPerSign + Self.bucket(magnitude: value.magnitude)] += 1
            negative += 1
        } else {
            buckets[Self.bucket(magnitude: UInt64(value))] += 1
        }
        count += 1
        max = Swift.max(max ?? value, value)
    }

    /// The value at `permille` / 1000 (rank `ceil(n · p)`), as the largest value of its bucket (so the true
    /// percentile is at most the result), capped at the exact `max`. nil when empty.
    public func percentile(permille: Int) -> Int64? {
        guard count > 0, let max else { return nil }
        let p = UInt64(Swift.min(Swift.max(permille, 1), 1000))
        let rank = Swift.max(1, (count * p + 999) / 1000)
        var seen: UInt64 = 0
        // Negative values first, the largest magnitude (smallest value) first.
        for i in stride(from: Self.bucketsPerSign - 1, through: 0, by: -1) {
            seen += buckets[Self.bucketsPerSign + i]
            if seen >= rank {
                let lo = Self.lowerBound(i)
                let value = lo > UInt64(Int64.max) ? Int64.min : -Int64(lo)
                return Swift.min(value, max)
            }
        }
        for i in 0..<Self.bucketsPerSign {
            seen += buckets[i]
            if seen >= rank {
                let hi = Self.upperBound(i)
                return hi > UInt64(Int64.max) ? max : Swift.min(Int64(hi), max)
            }
        }
        return max
    }

    public mutating func reset() {
        for i in buckets.indices { buckets[i] = 0 }
        count = 0
        negative = 0
        max = nil
    }
}

/// Which age distribution an input message belongs to.
public enum InputAgeClass: Int, CaseIterable, Sendable {
    /// One age per PEN sample (`base_time_us + dt_us`).
    case pen
    /// POINTER_REL and POINTER_ABS.
    case pointer
    case key
    /// SCROLL and PINCH.
    case scroll

    var logName: String {
        switch self {
        case .pen: "pen"
        case .pointer: "pointer"
        case .key: "key"
        case .scroll: "scroll"
        }
    }
}

/// Ages of delivered input per class, in a 1 s reporting window (`ev=input_age`) and for the whole session
/// (`input_session_end`). Confined to one serial context (the input queue). Logs counts and times only: never keys,
/// characters or coordinates.
public struct InputAgeTracker: Sendable {
    public struct Counters: Equatable, Sendable {
        /// Ages above `lateThresholdUs`.
        public var late = 0
        /// Negative ages (also part of the distribution).
        public var negative = 0
        /// Inputs that arrived before the first clock sample: no age, not in the distribution.
        public var noOffset = 0
    }

    public let reportIntervalUs: UInt64
    public let lateThresholdUs: Int64
    public private(set) var estimator = ClockOffsetEstimator()
    private var window: [AgeHistogram]
    private var session: [AgeHistogram]
    public private(set) var windowCounters = Counters()
    public private(set) var sessionCounters = Counters()
    /// First sample of the open window; nil while no input has flowed since the last report.
    public private(set) var windowStartUs: UInt64?

    public init(reportIntervalUs: UInt64 = 1_000_000, lateThresholdUs: Int64 = 250_000) {
        self.reportIntervalUs = reportIntervalUs
        self.lateThresholdUs = lateThresholdUs
        window = InputAgeClass.allCases.map { _ in AgeHistogram() }
        session = window
    }

    /// A new session: no offset, no samples, no open window.
    public mutating func reset() {
        estimator.reset()
        for i in window.indices {
            window[i].reset()
            session[i].reset()
        }
        windowCounters = Counters()
        sessionCounters = Counters()
        windowStartUs = nil
    }

    /// A PONG matched to a host PING (`SessionMachine` checked seq and echo), received at `receivedUs` (host clock).
    public mutating func clockSample(_ pong: Pong, receivedUs: UInt64) {
        estimator.add(echoUs: pong.echoTimeUs, responderUs: pong.responderTimeUs, receivedUs: receivedUs)
    }

    /// The age of a client time stamp received at `receivedUs`, or nil before the first clock sample.
    public func age(clientTimeUs: UInt64, receivedUs: UInt64) -> Int64? {
        guard let offset = estimator.offsetUs else { return nil }
        return Int64(truncatingIfNeeded: receivedUs)
            &- (Int64(truncatingIfNeeded: clientTimeUs) &- offset)
    }

    /// Records the age of one delivered message (PEN: every sample). Other messages are ignored.
    public mutating func record(_ message: Message, receivedUs: UInt64) {
        switch message {
        case .pen(let batch):
            for s in batch.samples {
                record(.pen, clientTimeUs: batch.baseTimeUs &+ UInt64(s.dtUs), receivedUs: receivedUs)
            }
        case .key(let k): record(.key, clientTimeUs: k.timeUs, receivedUs: receivedUs)
        case .pointerRel(let p): record(.pointer, clientTimeUs: p.timeUs, receivedUs: receivedUs)
        case .pointerAbs(let p): record(.pointer, clientTimeUs: p.timeUs, receivedUs: receivedUs)
        case .scroll(let s): record(.scroll, clientTimeUs: s.timeUs, receivedUs: receivedUs)
        case .pinch(let p): record(.scroll, clientTimeUs: p.timeUs, receivedUs: receivedUs)
        default: break
        }
    }

    public mutating func record(_ cls: InputAgeClass, clientTimeUs: UInt64, receivedUs: UInt64) {
        if windowStartUs == nil { windowStartUs = receivedUs }
        guard let age = age(clientTimeUs: clientTimeUs, receivedUs: receivedUs) else {
            windowCounters.noOffset += 1
            sessionCounters.noOffset += 1
            return
        }
        window[cls.rawValue].record(age)
        session[cls.rawValue].record(age)
        if age < 0 {
            windowCounters.negative += 1
            sessionCounters.negative += 1
        }
        if age > lateThresholdUs {
            windowCounters.late += 1
            sessionCounters.late += 1
        }
    }

    /// The `ev=input_age` fields once the open window is at least `reportIntervalUs` old (`force`: any open window,
    /// at session end), then a new window starts with the next sample. nil while no input flowed.
    public mutating func takeReport(now: UInt64, force: Bool = false) -> String? {
        guard let start = windowStartUs else { return nil }
        let elapsed = now >= start ? now - start : 0
        guard force || elapsed >= reportIntervalUs else { return nil }
        var fields = "interval_ms=\(elapsed / 1_000)"
        fields += Self.classFields(window, prefix: "")
        fields += Self.counterFields(windowCounters, estimator: estimator, prefix: "")
        for i in window.indices { window[i].reset() }
        windowCounters = Counters()
        windowStartUs = nil
        return fields
    }

    /// Session totals for `input_session_end` (fields start with a space, prefixed `age_`).
    public var sessionFields: String {
        Self.classFields(session, prefix: "age_")
            + Self.counterFields(sessionCounters, estimator: estimator, prefix: "age_")
            + " age_pongs=\(estimator.accepted)"
    }

    private static func classFields(_ histograms: [AgeHistogram], prefix: String) -> String {
        var s = ""
        for cls in InputAgeClass.allCases {
            let h = histograms[cls.rawValue]
            let name = prefix + cls.logName
            s += " \(name)_n=\(h.count)"
            guard h.count > 0 else { continue }
            s += " \(name)_p50_us=\(h.percentile(permille: 500) ?? 0)"
                + " \(name)_p95_us=\(h.percentile(permille: 950) ?? 0)"
                + " \(name)_p99_us=\(h.percentile(permille: 990) ?? 0)"
                + " \(name)_max_us=\(h.max ?? 0)"
        }
        return s
    }

    private static func counterFields(_ c: Counters, estimator: ClockOffsetEstimator, prefix: String) -> String {
        let rtt = estimator.bestRttUs
        return " \(prefix)late_250ms=\(c.late) \(prefix)neg=\(c.negative) \(prefix)no_offset=\(c.noOffset)"
            + " \(prefix)offset_rtt_us=\(rtt.map(String.init) ?? "none")"
            + " \(prefix)clock_unc_us=\(rtt.map { String($0 / 2) } ?? "none")"
    }
}
