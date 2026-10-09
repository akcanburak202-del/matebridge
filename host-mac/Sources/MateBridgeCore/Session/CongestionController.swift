/// Wi-Fi congestion controller for the video connection (T-327, decision 0023 branch (c); design of T-195).
///
/// Pure value type: no I/O, no clock reads, no logging, no Dispatch. Time comes in as microseconds from any monotone
/// clock. The owner (T-328) serialises calls and decides which drops and snapshots to report.
///
/// Inputs
/// - `frameWritten(bytes:)`: one completed frame write; keeps an average frame size.
/// - `tick(_:)`: a TCP snapshot of the video connection (1 s on the wire today, finer is fine).
/// - `queueDropped(nowUs:)`: the host dropped a frame because its send queue was full.
///
/// Outputs
/// - `mayWrite(sendBufferBytes:)` / `budgetBytes`: admission, from the kernel send buffer (`tcpi_snd_sbbytes`; never
///   `TcpConnectionSnapshot.unackedBytesEstimate`, which degenerates to sbbytes when cwnd is in the MB range).
/// - `targetKbps`: encoder bit rate in `[floorKbps, ceilingKbps]`. The ceiling is the session's configured bit rate
///   (`STREAM_CONFIG.bitrate_kbps`); the controller only goes below it.
///
/// Behaviour: fast down, slow up. Any trigger (retransmits, queueing delay, send buffer over budget, host queue drop)
/// multiplies the target by `downFactor` (`mildDownFactor` for a few retransmitted packets), at most once per
/// `max(srtt, minDownIntervalMs)`. After `quietMs` without a trigger the target climbs by `upFractionPerSecond` of the ceiling per second back to the ceiling.
public struct CongestionController: Equatable, Sendable {
    // MARK: Constants. Source: the 2026-10-09 Oyun session (T-327 replay trace) and the T-127/NOTES 2026-10-02
    // measurements (100-450 KB in the air, control srtt 20 -> 60-100 ms behind video bursts).

    /// Lowest target. It must still carry a keyframe: the Oyun keyframes were 240-680 KB, which 12 Mbps drains in
    /// 0.15-0.45 s; and it stays well under the 30 Mbps that was clean on the congested 2026-10-08/09 WLAN hop.
    public static let defaultFloorKbps = 12_000
    /// Multiplicative decrease.
    public static let downFactor = 0.7
    /// A handful of retransmitted packets in a window is ordinary Wi-Fi tail loss, not congestion: the Oyun trace has a
    /// lone 1-3 packet retransmit every 10-20 s at healthy RTT, and a 385-packet burst when the game started. Fewer
    /// than `mildRetransmitPackets` packets (per window of about a second) decrease by `mildDownFactor` only.
    public static let mildRetransmitPackets: UInt64 = 4
    public static let mildDownFactor = 0.9
    /// Two decreases are at least `max(srtt, this)` apart. The kernel needs about one round trip to show the effect
    /// of a decrease; the lower bound keeps 100 ms ticks at a small srtt from compounding to the floor in a second.
    public static let minDownIntervalMs: UInt32 = 250
    /// No trigger for this long before the target may climb.
    public static let quietMs: UInt32 = 2_000
    /// Additive increase per second of quiet, as a fraction of the ceiling (5 %).
    public static let upFractionPerSecond = 0.05
    /// Queueing delay trigger: smoothed RTT this far above the windowed minimum RTT. 20 ms is also the queue-delay
    /// the budget is sized for. The Oyun trace has srtt 4-15 ms in clean minutes and 43-75 ms while congested.
    public static let srttExcessTriggerMs: UInt32 = 20
    /// The in-flight budget is this much queue delay at the current target.
    public static let budgetDelayMs = 20
    /// A send buffer above this multiple of the budget is a decrease trigger (the budget itself only refuses writes;
    /// the Oyun trace sits at 40-170 KB against a 150 KB budget at 60 Mbps when healthy).
    public static let sendBufferTriggerFactor = 3
    /// Window of the minimum-RTT baseline. 30 s, not 10 s: the congested start of the Oyun session lasted 9 s, which
    /// a short window would absorb into the baseline.
    public static let baselineWindowSeconds = 30
    /// Output granularity of `targetKbps`, so the owner does not reconfigure the encoder for noise.
    public static let quantumKbps = 250
    /// Weight of the newest frame in the average frame size.
    public static let frameAverageWeight = 0.0625

    public struct Config: Equatable, Sendable {
        public var ceilingKbps: Int
        public var floorKbps: Int
        public var framesPerSecond: Int

        /// `floorKbps` is clamped to the ceiling: a session configured below the floor is never controlled.
        public init(ceilingKbps: Int, floorKbps: Int = CongestionController.defaultFloorKbps, framesPerSecond: Int = 60) {
            self.ceilingKbps = max(1, ceilingKbps)
            self.floorKbps = min(max(1, floorKbps), self.ceilingKbps)
            self.framesPerSecond = max(1, framesPerSecond)
        }
    }

    /// One TCP reading of the video connection.
    public struct Tick: Equatable, Sendable {
        public var nowUs: UInt64
        /// `tcpi_srtt` in ms (1 ms resolution); 0 means no sample.
        public var srttMs: UInt32
        /// `tcpi_snd_sbbytes`.
        public var sendBufferBytes: UInt32
        /// Retransmitted packets since the previous tick.
        public var retransmitPacketsDelta: UInt64

        public init(nowUs: UInt64, srttMs: UInt32, sendBufferBytes: UInt32, retransmitPacketsDelta: UInt64) {
            self.nowUs = nowUs
            self.srttMs = srttMs
            self.sendBufferBytes = sendBufferBytes
            self.retransmitPacketsDelta = retransmitPacketsDelta
        }

        public init(nowUs: UInt64, report: TcpInfoReport) {
            self.init(nowUs: nowUs, srttMs: report.snapshot.srttMs, sendBufferBytes: report.snapshot.sendBufferBytes,
                      retransmitPacketsDelta: report.retransmitPacketsDelta)
        }
    }

    /// Why the target went down; for the owner's log line.
    public enum Trigger: String, Equatable, Sendable {
        case queueDrop = "queue_drop"
        case retransmit
        case queueDelay = "queue_delay"
        case sendBuffer = "send_buffer"
        /// The owner's gate stayed closed for most of a long window while frames kept dropping (T-328).
        case blocked
    }

    public let config: Config

    private var exactKbps: Double
    private var averageFrameBytes: Double
    private var lastTriggerUs: UInt64?
    private var lastDownUs: UInt64?
    private var lastUpdateUs: UInt64 = 0
    private var latestSrttMs: UInt32 = 0
    /// One minimum-RTT bucket per second of the baseline window.
    private var bucketSecond = [UInt64](repeating: .max, count: CongestionController.baselineWindowSeconds)
    private var bucketMinMs = [UInt32](repeating: .max, count: CongestionController.baselineWindowSeconds)

    public init(config: Config) {
        self.config = config
        exactKbps = Double(config.ceilingKbps)
        averageFrameBytes = Double(config.ceilingKbps) * 125.0 / Double(config.framesPerSecond)
    }

    // MARK: Outputs

    /// Encoder target in kbps, within `[floorKbps, ceilingKbps]`, in steps of `quantumKbps`.
    public var targetKbps: Int {
        let q = Self.quantumKbps
        let stepped = (Int(exactKbps.rounded()) + q / 2) / q * q
        return min(config.ceilingKbps, max(config.floorKbps, stepped))
    }

    /// Windowed minimum smoothed RTT in ms; nil before the first sample.
    public var baselineSrttMs: UInt32? {
        let m = bucketMinMs.min() ?? .max
        return m == .max ? nil : m
    }

    /// In-flight budget in bytes: `budgetDelayMs` of the current target, never below one average frame, so a single
    /// frame can always go.
    public var budgetBytes: Int {
        let byDelay = Double(targetKbps) * 125.0 * Double(Self.budgetDelayMs) / 1_000.0
        return Int(max(byDelay, averageFrameBytes).rounded(.up))
    }

    /// Whether a new frame may be written now, given the kernel send buffer.
    public func mayWrite(sendBufferBytes: UInt32) -> Bool {
        Int(sendBufferBytes) <= budgetBytes
    }

    // MARK: Inputs

    public mutating func frameWritten(bytes: Int) {
        guard bytes > 0 else { return }
        averageFrameBytes += (Double(bytes) - averageFrameBytes) * Self.frameAverageWeight
    }

    /// A host-side frame drop. Which drops to report (for instance not the ones the admission gate itself caused) is
    /// the owner's decision. Returns true when the target went down.
    @discardableResult
    public mutating func queueDropped(nowUs: UInt64) -> Bool {
        advance(to: nowUs)
        return trigger(.queueDrop, factor: Self.downFactor, nowUs: max(nowUs, lastUpdateUs)) != nil
    }

    /// The owner's admission gate was closed for most of a long window with host queue drops throughout, and no other
    /// trigger fired (T-328 `WifiAdaptation`: a link slower than the target keeps the send buffer between one and
    /// three budgets, so neither the buffer, the RTT nor the retransmit trigger sees it). Same decrease and
    /// minimum interval as any trigger. Returns true when the target went down.
    @discardableResult
    public mutating func blockedTooLong(nowUs: UInt64) -> Bool {
        advance(to: nowUs)
        return trigger(.blocked, factor: Self.downFactor, nowUs: max(nowUs, lastUpdateUs)) != nil
    }

    /// Feeds one TCP reading. Returns the trigger that lowered the target, nil when it did not go down (no trigger,
    /// or a trigger within the minimum interval of the previous decrease).
    @discardableResult
    public mutating func tick(_ t: Tick) -> Trigger? {
        let now = max(t.nowUs, lastUpdateUs)
        advance(to: now)
        if t.srttMs > 0 {
            latestSrttMs = t.srttMs
            note(srttMs: t.srttMs, nowUs: now)
        }
        // The strongest signal wins: its trigger name and its decrease factor.
        var hit: (Trigger, Double)?
        func offer(_ trigger: Trigger, _ factor: Double) {
            if hit == nil || factor < hit!.1 { hit = (trigger, factor) }
        }
        if t.retransmitPacketsDelta > 0 {
            offer(.retransmit, t.retransmitPacketsDelta < Self.mildRetransmitPackets ? Self.mildDownFactor : Self.downFactor)
        }
        if let base = baselineSrttMs, t.srttMs > 0, t.srttMs >= base &+ Self.srttExcessTriggerMs {
            offer(.queueDelay, Self.downFactor)
        }
        if Int(t.sendBufferBytes) > Self.sendBufferTriggerFactor * budgetBytes {
            offer(.sendBuffer, Self.downFactor)
        }
        guard let (reason, factor) = hit else { return nil }
        return trigger(reason, factor: factor, nowUs: now)
    }

    // MARK: Internals

    /// Applies the slow climb up to `nowUs`. Only time after the quiet period counts.
    private mutating func advance(to nowUs: UInt64) {
        defer { lastUpdateUs = max(lastUpdateUs, nowUs) }
        guard nowUs > lastUpdateUs else { return }
        let quietEndUs = (lastTriggerUs ?? 0) &+ UInt64(Self.quietMs) * 1_000
        let from = lastTriggerUs == nil ? lastUpdateUs : max(lastUpdateUs, quietEndUs)
        guard nowUs > from, exactKbps < Double(config.ceilingKbps) else { return }
        let seconds = Double(nowUs - from) / 1_000_000.0
        exactKbps = min(Double(config.ceilingKbps), exactKbps + Double(config.ceilingKbps) * Self.upFractionPerSecond * seconds)
    }

    private mutating func trigger(_ reason: Trigger, factor: Double, nowUs: UInt64) -> Trigger? {
        lastTriggerUs = nowUs
        let interval = UInt64(max(latestSrttMs, Self.minDownIntervalMs)) * 1_000
        if let last = lastDownUs, nowUs < last &+ interval { return nil }
        lastDownUs = nowUs
        exactKbps = max(Double(config.floorKbps), exactKbps * factor)
        return reason
    }

    private mutating func note(srttMs: UInt32, nowUs: UInt64) {
        let second = nowUs / 1_000_000
        let slot = Int(second % UInt64(Self.baselineWindowSeconds))
        if bucketSecond[slot] != second {
            bucketSecond[slot] = second
            bucketMinMs[slot] = .max
        }
        bucketMinMs[slot] = min(bucketMinMs[slot], srttMs)
        // Buckets older than the window are stale: a slot still holding an older second is expired.
        for i in 0..<bucketSecond.count where bucketSecond[i] != .max && bucketSecond[i] + UInt64(Self.baselineWindowSeconds) <= second {
            bucketSecond[i] = .max
            bucketMinMs[i] = .max
        }
    }
}
