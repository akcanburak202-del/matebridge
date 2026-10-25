/// Wi-Fi video bit rate controller, v2 (T-379, decision 0023 addendum 2026-10-25, `MATEBRIDGE_WIFI_ADAPT=1`).
///
/// Pure value type: no I/O, no clock reads, no logging. The owner calls `tick` every 100 ms with one `Sample`. The only
/// output is a new encoder bit rate; there is no admission gate, no keyframe request and no restart. The ceiling is the
/// session's configured bit rate (a user lowering it is obeyed at once, `setCeiling`).
///
/// Signals (addendum):
/// - S (stall): the sender made no write progress for 150 ms (`SendStallDetector`, fed by the sender's own state).
/// - D (delay): smoothed RTT at least 20 ms above the baseline. The baseline is a low percentile of the RTTs seen in
///   the last 30 s while the send buffer was drained (`RttBaseline`); a persistent queue is never learned as baseline.
/// - L (loss): over the last second retransmitted packets are at least 1 % of the sent ones and at least 4.
/// - B (backlog): the kernel send buffer holds at least 20 ms of the target rate and has not fallen over the last
///   250 ms.
///
/// Law (addendum):
/// - Heavy: two distinct S events within 2 s, or one S of at least 500 ms, or 3 of the last 5 samples with D >= 50 ms
///   while B. Response x0.7, at most every 500 ms.
/// - Moderate: 3 of the last 5 samples with D >= 20 ms while B, or L while B. Response x0.85, at most every 750 ms.
/// - Fresh evidence: every step clears the evidence (S events, D/L/B history); one event is never counted twice. A
///   stall still running at a step is "consumed" until it ends.
/// - S, D or L alone never lowers the rate; it only holds the climb back for 2 s.
/// - Floor 30 Mbps (the ceiling when that is lower). The emergency floor of 20 Mbps is used only when the rate is at
///   30 and heavy evidence is seen again, 2 s or more after it was first seen there.
/// - Recovery: 3 clean seconds after a step, then +2 Mbps per second up to the ceiling. No jump to the ceiling.
public struct WifiAdaptV2Controller: Sendable {
    /// Every tunable in one place. First calibration from the 2026-10-25 traces; not verified on the device.
    public enum Constants {
        public static let tickMs = 100
        public static let normalFloorKbps = 30_000
        public static let emergencyFloorKbps = 20_000
        public static let heavyFactor = 0.7
        public static let moderateFactor = 0.85
        public static let heavyMinIntervalMs: UInt64 = 500
        public static let moderateMinIntervalMs: UInt64 = 750
        public static let stallEventWindowMs: UInt64 = 2_000
        public static let longStallMs: UInt64 = 500
        public static let delayModerateMs: UInt32 = 20
        public static let delayHeavyMs: UInt32 = 50
        /// "3 of the last 5 samples".
        public static let delaySamples = 5
        public static let delayHits = 3
        public static let lossMinPackets: UInt64 = 4
        public static let lossPercent: UInt64 = 1
        /// L window: the last second (ticks).
        public static let lossTicks = 10
        /// B: the send buffer holds at least `backlogMs` of the current target rate (never less than `backlogMinBytes`)
        /// and did not fall over `backlogTicks` ticks (300 ms >= 250 ms). The addendum names no size; 20 ms is the
        /// queueing delay it calls significant for D. A smaller buffer is ordinary pacing: the clean 2026-10-25 session
        /// sat at 60-100 KB for minutes at 60 Mbps (10-13 ms) with srtt up to 70 ms and no visible problem.
        public static let backlogMs = 20
        public static let backlogMinBytes: UInt32 = 32 * 1024
        public static let backlogTicks = 4
        /// "Drained" mark of the RTT baseline: a send buffer below this has no queue of ours.
        public static let drainedBytes: UInt32 = 32 * 1024
        /// A lone S, D or L holds the climb for this long.
        public static let singleSignalHoldMs: UInt64 = 2_000
        /// After a step, this much without signals before the climb.
        public static let stepHoldMs: UInt64 = 3_000
        public static let climbKbpsPerStep = 2_000
        public static let climbIntervalMs: UInt64 = 1_000
        /// Emergency: heavy evidence this long after it was first seen at the floor.
        public static let emergencyAfterMs: UInt64 = 2_000
        /// Output granularity.
        public static let quantumKbps = 100
    }

    /// One reading, every 100 ms.
    public struct Sample: Equatable, Sendable {
        public var nowUs: UInt64
        public var srttMs: UInt32
        public var sendBufferBytes: UInt32
        public var txPacketsDelta: UInt64
        public var retransmitPacketsDelta: UInt64
        /// A stall started at this sample (`SendStallDetector.Result.newEvent`).
        public var stallStarted: Bool
        /// Length of the stall in progress, ms (0: none).
        public var stallActiveMs: UInt32

        public init(nowUs: UInt64, srttMs: UInt32, sendBufferBytes: UInt32, txPacketsDelta: UInt64,
                    retransmitPacketsDelta: UInt64, stallStarted: Bool = false, stallActiveMs: UInt32 = 0) {
            self.nowUs = nowUs
            self.srttMs = srttMs
            self.sendBufferBytes = sendBufferBytes
            self.txPacketsDelta = txPacketsDelta
            self.retransmitPacketsDelta = retransmitPacketsDelta
            self.stallStarted = stallStarted
            self.stallActiveMs = stallActiveMs
        }
    }

    public struct Evidence: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let stall = Evidence(rawValue: 1)
        public static let delay = Evidence(rawValue: 2)
        public static let loss = Evidence(rawValue: 4)
        public static let backlog = Evidence(rawValue: 8)

        /// `S,D,L,B` subset in that order; `-` when empty.
        public var logValue: String {
            var parts: [String] = []
            if contains(.stall) { parts.append("S") }
            if contains(.delay) { parts.append("D") }
            if contains(.loss) { parts.append("L") }
            if contains(.backlog) { parts.append("B") }
            return parts.isEmpty ? "-" : parts.joined(separator: ",")
        }
    }

    public enum Reason: String, Equatable, Sendable {
        case severe
        case moderate
        case recover
        case emergency
        /// The ceiling changed (user setting).
        case ceiling
    }

    public struct Step: Equatable, Sendable {
        public var fromKbps: Int
        public var toKbps: Int
        public var reason: Reason
        public var evidence: Evidence
    }

    public struct Outcome: Equatable, Sendable {
        public var step: Step?
        /// What this tick saw (not only what a step used).
        public var evidence: Evidence
    }

    public private(set) var targetKbps: Int
    public private(set) var ceilingKbps: Int
    public var floorKbps: Int { min(Constants.normalFloorKbps, ceilingKbps) }

    private var baseline = RttBaseline()
    /// The RTT baseline now, for the log; nil while there are too few drained samples.
    public var baselineMs: UInt32? { baseline.baselineMs }
    private var delayRing: [(over20: Bool, over50: Bool)] = []
    private var lossRing: [(retx: UInt64, tx: UInt64)] = []
    private var backlogRing: [UInt32] = []
    private var stallEventsUs: [UInt64] = []
    /// The stall running at the last step was used for it; it cannot count again.
    private var stallConsumed = false
    private var lastStepUs: UInt64?
    private var holdUntilUs: UInt64 = 0
    private var lastClimbUs: UInt64 = 0
    private var floorHeavyFirstUs: UInt64?
    private var floorHeavyLastUs: UInt64 = 0

    public init(ceilingKbps: Int) {
        let c = max(1, ceilingKbps)
        self.ceilingKbps = c
        targetKbps = c
    }

    /// The video connection changed (a new socket, a different network): the RTT baseline and all evidence start over.
    public mutating func connectionChanged() {
        baseline = RttBaseline()
        clearEvidence()
        stallConsumed = false
        floorHeavyFirstUs = nil
    }

    /// The configured bit rate changed. Lower: obeyed at once. Higher: a controller that sat at the old ceiling moves
    /// to the new one; one that was below it keeps its rate and climbs.
    public mutating func setCeiling(_ kbps: Int) -> Step? {
        let old = ceilingKbps
        ceilingKbps = max(1, kbps)
        var next = targetKbps
        if ceilingKbps < targetKbps { next = ceilingKbps }
        else if targetKbps >= old { next = ceilingKbps }
        next = max(next, floorKbps)
        guard next != targetKbps else { return nil }
        let step = Step(fromKbps: targetKbps, toKbps: next, reason: .ceiling, evidence: [])
        targetKbps = next
        if targetKbps > floorKbps { floorHeavyFirstUs = nil }
        return step
    }

    public mutating func tick(_ s: Sample) -> Outcome {
        let now = s.nowUs
        let nowMs = now / 1_000

        // Rings.
        baseline.add(nowUs: now, srttMs: s.srttMs, drained: s.sendBufferBytes < Constants.drainedBytes)
        let base = baseline.baselineMs
        var excess: UInt32 = 0
        if let base, s.srttMs > base { excess = s.srttMs - base }
        push(&delayRing, (excess >= Constants.delayModerateMs, excess >= Constants.delayHeavyMs), keep: Constants.delaySamples)
        push(&lossRing, (s.retransmitPacketsDelta, s.txPacketsDelta), keep: Constants.lossTicks)
        push(&backlogRing, s.sendBufferBytes, keep: Constants.backlogTicks)
        if s.stallStarted { stallEventsUs.append(now) }
        stallEventsUs.removeAll { now > $0 && now - $0 > Constants.stallEventWindowMs * 1_000 }
        if s.stallActiveMs == 0 { stallConsumed = false }

        // Signals.
        let stallNow = s.stallStarted || s.stallActiveMs > 0
        let d20 = delayRing.filter(\.over20).count >= Constants.delayHits
        let d50 = delayRing.filter(\.over50).count >= Constants.delayHits
        let retx = lossRing.reduce(0) { $0 + $1.retx }
        let tx = lossRing.reduce(0) { $0 + $1.tx }
        let loss = retx >= Constants.lossMinPackets && retx * 100 >= tx * Constants.lossPercent
        let backlog = backlogRing.count >= Constants.backlogTicks
            && backlogRing.allSatisfy { $0 >= backlogThreshold }
            && backlogRing.last! >= backlogRing.first!

        var seen: Evidence = []
        if stallNow { seen.insert(.stall) }
        if delayRing.last?.over20 == true { seen.insert(.delay) }
        if s.retransmitPacketsDelta > 0 && loss { seen.insert(.loss) }
        if backlog { seen.insert(.backlog) }
        if stallNow || delayRing.last?.over20 == true || loss {
            holdUntilUs = max(holdUntilUs, now + Constants.singleSignalHoldMs * 1_000)
        }

        // Verdict.
        let freshStalls = stallEventsUs.count
        let longStall = !stallConsumed && s.stallActiveMs >= UInt32(Constants.longStallMs)
        let heavyStall = freshStalls >= 2 || longStall
        let heavy = heavyStall || (d50 && backlog)
        let moderate = (d20 && backlog) || (loss && backlog)
        var used: Evidence = []
        if heavy {
            if heavyStall { used.insert(.stall) }
            if d50 && backlog { used.formUnion([.delay, .backlog]) }
        } else if moderate {
            if d20 && backlog { used.formUnion([.delay, .backlog]) }
            if loss && backlog { used.formUnion([.loss, .backlog]) }
        }

        func since(_ t: UInt64?) -> UInt64 { t.map { nowMs - min(nowMs, $0 / 1_000) } ?? UInt64.max }
        // Emergency needs evidence that arrived at this tick, not a leftover pair still inside its 2 s window.
        let heavyIsNew = s.stallStarted || longStall || (d50 && backlog)
        var step: Step?
        let atNormalFloor = targetKbps <= floorKbps && floorKbps == Constants.normalFloorKbps
        if heavy, atNormalFloor {
            if floorHeavyFirstUs == nil || now - floorHeavyLastUs > Constants.emergencyAfterMs * 1_000 {
                floorHeavyFirstUs = now
            }
            floorHeavyLastUs = now
        }
        if heavy, targetKbps > floorKbps, since(lastStepUs) >= Constants.heavyMinIntervalMs {
            step = lower(to: scaled(targetKbps, Constants.heavyFactor), reason: .severe, used: used, now: now)
        } else if heavy, heavyIsNew, atNormalFloor, let first = floorHeavyFirstUs,
                  now - first >= Constants.emergencyAfterMs * 1_000, since(lastStepUs) >= Constants.heavyMinIntervalMs {
            step = lower(to: Constants.emergencyFloorKbps, reason: .emergency, used: used, now: now)
        } else if !heavy, moderate, targetKbps > floorKbps, since(lastStepUs) >= Constants.moderateMinIntervalMs {
            step = lower(to: scaled(targetKbps, Constants.moderateFactor), reason: .moderate, used: used, now: now)
        } else if targetKbps < ceilingKbps, now >= holdUntilUs,
                  nowMs - min(nowMs, lastClimbUs / 1_000) >= Constants.climbIntervalMs {
            let to = min(ceilingKbps, targetKbps + Constants.climbKbpsPerStep)
            step = Step(fromKbps: targetKbps, toKbps: to, reason: .recover, evidence: [])
            targetKbps = to
            lastClimbUs = now
            lastStepUs = now
        }
        return Outcome(step: step, evidence: seen)
    }

    // MARK: Internals

    private mutating func lower(to proposed: Int, reason: Reason, used: Evidence, now: UInt64) -> Step? {
        let floor = reason == .emergency ? min(Constants.emergencyFloorKbps, ceilingKbps) : floorKbps
        let to = max(floor, proposed)
        guard to < targetKbps else { return nil }
        let step = Step(fromKbps: targetKbps, toKbps: to, reason: reason, evidence: used)
        targetKbps = to
        lastStepUs = now
        holdUntilUs = max(holdUntilUs, now + Constants.stepHoldMs * 1_000)
        clearEvidence()
        stallConsumed = true  // a running stall was part of the evidence; it ends before it can count again
        floorHeavyFirstUs = nil  // at the floor, the 2 s count from the next heavy evidence
        return step
    }

    private mutating func clearEvidence() {
        delayRing.removeAll()
        lossRing.removeAll()
        backlogRing.removeAll()
        stallEventsUs.removeAll()
    }

    /// Send buffer size that counts as a backlog at the current target rate.
    private var backlogThreshold: UInt32 {
        let atRate = UInt64(targetKbps) * 1_000 / 8 * UInt64(Constants.backlogMs) / 1_000
        return max(Constants.backlogMinBytes, UInt32(min(atRate, UInt64(UInt32.max))))
    }

    private func scaled(_ kbps: Int, _ factor: Double) -> Int {
        let v = Int((Double(kbps) * factor).rounded(.down))
        return v / Constants.quantumKbps * Constants.quantumKbps
    }

    private func push<T>(_ ring: inout [T], _ v: T, keep: Int) {
        ring.append(v)
        if ring.count > keep { ring.removeFirst(ring.count - keep) }
    }
}

/// Low percentile of the RTTs seen in the last 30 s with the send buffer drained (no queue of our own). Pure.
/// A session that never drains has no baseline (D never fires), which fails safe.
public struct RttBaseline: Sendable {
    public static let windowUs: UInt64 = 30_000_000
    /// 10th percentile.
    public static let percent = 10
    /// Fewer drained samples than this (2 s at 100 ms) know no baseline.
    public static let minSamples = 20

    private var samples: [(atUs: UInt64, srttMs: UInt32)] = []

    public init() {}

    public mutating func add(nowUs: UInt64, srttMs: UInt32, drained: Bool) {
        if drained, srttMs > 0 { samples.append((nowUs, srttMs)) }
        samples.removeAll { nowUs > $0.atUs && nowUs - $0.atUs > Self.windowUs }
    }

    public var baselineMs: UInt32? {
        guard samples.count >= Self.minSamples else { return nil }
        let sorted = samples.map(\.srttMs).sorted()
        return sorted[(sorted.count - 1) * Self.percent / 100]
    }
}
