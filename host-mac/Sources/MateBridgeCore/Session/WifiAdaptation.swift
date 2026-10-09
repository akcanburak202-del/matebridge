import Foundation

/// Owner of one Wi-Fi video connection's `CongestionController` (T-328, `MATEBRIDGE_WIFI_ADAPT`): serialises its
/// inputs, turns a fresh kernel send-buffer reading into the frame admission, and keeps the books for `video ev=adapt`.
///
/// Threads and locks. `admit()` runs on the video sender (inside `SocketVideoTransport.canSend`), `frameWritten` on the
/// socket's write queue, `tick` on the driver's timer queue, the retry on a global queue. One lock guards the state; it
/// is never held across `readSendBuffer` (a `getsockopt` that takes the connection's lock) or `wake` (which re-enters
/// the transport). Lock order for callers: transport, then this object, then connection.
///
/// Admission. `admit()` reads the kernel send buffer (`tcpi_snd_sbbytes`), at most once per `sampleFreshUs` so two
/// calls in a row share one `getsockopt`, and admits while it is within `CongestionController.budgetBytes`. A failed
/// reading admits: the gate never wedges on a socket that cannot be read. A refusal arms a retry (4 ms, doubling to
/// 20 ms) that samples again and wakes the sender once the buffer has drained. So a refused admission is re-checked on
/// the socket's writable event (the transport's own wake), on every `tick` and on this timer: the writable event alone
/// would never come, because the socket stays writable while the budget is exceeded.
///
/// Queue drops. The controller treats a host queue drop as congestion, but a drop the gate itself caused (it held
/// frames and the two-frame queue overflowed) must not count, or a keyframe larger than the budget would push the
/// target down on every keyframe. So the gate's refusals are never reported, and a rise of `queueDropsTotal` is
/// reported only when the gate refused nothing in this tick window or the one before. Sustained congestion still lowers
/// the target through the controller's send buffer, queueing delay and retransmit triggers.
public final class WifiAdaptation: @unchecked Sendable {
    /// `(afterUs, fire)`: call `fire` once, `afterUs` microseconds from now.
    public typealias Scheduler = @Sendable (_ afterUs: UInt64, _ fire: @escaping @Sendable () -> Void) -> Void

    public static let sampleFreshUs: UInt64 = 2_000
    public static let retryFirstUs: UInt64 = 4_000
    public static let retryMaxUs: UInt64 = 20_000
    /// Sustained blocking (P2): the gate was closed for at least `sustainedBlockedPercent` of the last
    /// `sustainedTicks` ticks (2 s at 100 ms) and the host queue dropped frames in that span. One keyframe cannot
    /// reach this: the largest keyframes seen are 240-680 KB (T-327 trace), which drain in 0.45 s at the 12 Mbps floor
    /// and less at any higher target, and keyframes are at least a coalescing window apart; even 1 MB at the floor
    /// closes the gate for 0.67 s, 33 % of the span. 60 % of 2 s is 1.2 s of blocking, i.e. a 1.8 MB keyframe at the
    /// floor. A link that cannot carry the target keeps the gate closed for most of every second. After the decrease
    /// the evidence is cleared, so the next one needs another full span (0.7x per 2 s at most).
    static let sustainedTicks = 20
    static let sustainedBlockedPercent: UInt64 = 60
    /// Higher targets reach the encoder at most this often (every apply reconfigures the VideoToolbox session).
    public static let upApplyIntervalUs: UInt64 = 500_000

    /// Whether the encoder should be set to `target` now. A lower target always; the ceiling always (the idle
    /// recovery jump must not wait: the card wants a static screen sharp again within 5 s); any other higher one when
    /// `upApplyIntervalUs` has passed since the last higher one.
    public static func shouldApply(target: Int, applied: Int, ceiling: Int, nowUs: UInt64, lastUpApplyUs: UInt64) -> Bool {
        guard target != applied else { return false }
        if target < applied || target >= ceiling { return true }
        return elapsed(nowUs, since: lastUpApplyUs) >= upApplyIntervalUs
    }

    /// Bound of the `sbbytes` samples kept for one log window.
    static let maxWindowSamples = 2_048

    /// What one `tick` did.
    public struct TickResult: Equatable, Sendable {
        /// The encoder target after the tick, kbps.
        public var targetKbps: Int
        /// The target differs from the one before the tick: apply it to the encoder.
        public var changed: Bool
        /// Why the target went down (nil: it did not).
        public var trigger: CongestionController.Trigger?
        /// Host queue drops seen by this tick that were reported to the controller.
        public var reportedDrops: Int
    }

    /// One second of the books, for `video ev=adapt`.
    public struct LogWindow: Equatable, Sendable {
        public var targetKbps: Int
        public var sendBufferP95: UInt32
        public var srttMs: UInt32
        public var admitsBlocked: Int
        public var blockedMs: Int
        public var budgetBytes: Int
        public var retransmitPackets: UInt64
        public var queueDrops: Int
        public var downSteps: Int

        /// `target_kbps=… sbbytes_p95=… srtt_ms=… admits_blocked=… blocked_ms=… budget_bytes=… retx_pkts=…
        /// queue_drops=… down_steps=…`. Numbers only.
        public var logFields: String {
            "target_kbps=\(targetKbps) sbbytes_p95=\(sendBufferP95) srtt_ms=\(srttMs) admits_blocked=\(admitsBlocked) "
                + "blocked_ms=\(blockedMs) budget_bytes=\(budgetBytes) retx_pkts=\(retransmitPackets) "
                + "queue_drops=\(queueDrops) down_steps=\(downSteps)"
        }
    }

    private let readSendBuffer: @Sendable () -> UInt32?
    private let nowUs: @Sendable () -> UInt64
    private let schedule: Scheduler

    private let lock = NSLock()
    private var controller: CongestionController
    private var wake: (@Sendable () -> Void)?
    private var stopped = false
    private var reportedTargetKbps: Int

    // Admission state.
    private var cachedBytes: UInt32?
    private var cachedAtUs: UInt64 = 0
    private var blockedSinceUs: UInt64?
    private var retryArmed = false
    private var retryDelayUs = WifiAdaptation.retryFirstUs
    private var refusedThisWindow = false
    private var refusedLastWindow = false

    // Tick state.
    private var lastDropsTotal: Int?
    private var lastTickUs: UInt64?
    private var tickBlockedUs: UInt64 = 0
    /// The last `sustainedTicks` ticks: time blocked, time covered, queue drops.
    private var recent: [(blockedUs: UInt64, spanUs: UInt64, drops: Int)] = []

    // Log window.
    private var samples: [UInt32] = []
    private var windowBlocked = 0
    private var windowBlockedUs: UInt64 = 0
    private var windowRetx: UInt64 = 0
    private var windowDrops = 0
    private var windowDownSteps = 0
    private var latestSrttMs: UInt32 = 0

    /// - Parameters:
    ///   - readSendBuffer: `tcpi_snd_sbbytes` of the video connection; nil when it cannot be read (then admit).
    ///   - nowUs: monotone microseconds (the host clock).
    ///   - schedule: runs the retry; tests pass a manual one.
    public init(config: CongestionController.Config,
                readSendBuffer: @escaping @Sendable () -> UInt32?,
                nowUs: @escaping @Sendable () -> UInt64,
                schedule: @escaping Scheduler = WifiAdaptation.defaultScheduler) {
        controller = CongestionController(config: config)
        ceilingKbps = controller.config.ceilingKbps
        reportedTargetKbps = controller.targetKbps
        self.readSendBuffer = readSendBuffer
        self.nowUs = nowUs
        self.schedule = schedule
    }

    public static let defaultScheduler: Scheduler = { afterUs, fire in
        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + .microseconds(Int(min(afterUs, UInt64(Int32.max)))), execute: fire)
    }

    /// The sender is woken through this (the transport's ready handler) when a refused admission may pass now.
    public func setWakeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { wake = handler }
    }

    // MARK: Outputs

    public var targetKbps: Int { lock.withLock { controller.targetKbps } }
    public var budgetBytes: Int { lock.withLock { controller.budgetBytes } }
    public let ceilingKbps: Int

    // MARK: Admission

    /// Whether a new frame may be handed to the socket now. Called by the sender before it takes a frame.
    public func admit() -> Bool {
        let now = nowUs()
        let bytes = freshSendBuffer(at: now, force: false)
        var arm: UInt64?
        let admitted: Bool = lock.withLock {
            guard !stopped, let bytes else { return true }  // unreadable or stopped: do not gate
            if controller.mayWrite(sendBufferBytes: bytes) {
                closeEpisodeLocked(at: now)
                return true
            }
            if blockedSinceUs == nil {
                blockedSinceUs = now
                windowBlocked += 1
            }
            refusedThisWindow = true
            arm = armRetryLocked()
            return false
        }
        if let arm { scheduleRetry(afterUs: arm) }
        return admitted
    }

    /// A frame of `bytes` was written to the socket (the kernel took the whole record).
    public func frameWritten(bytes: Int) {
        lock.withLock { controller.frameWritten(bytes: bytes) }
    }

    /// No more retries or wakes; `admit()` admits from now on (the connection is going away).
    public func stop() {
        lock.withLock {
            stopped = true
            wake = nil
        }
    }

    // MARK: Ticks

    /// Feeds one TCP reading (every 100 ms from the driver) and the host queue's cumulative drop count. A refusal that
    /// is still open is re-checked: the sender is woken so it asks `admit()` again with the budget the tick may have
    /// changed.
    public func tick(report: TcpInfoReport, queueDropsTotal: Int) -> TickResult {
        let now = nowUs()
        var result = TickResult(targetKbps: 0, changed: false, trigger: nil, reportedDrops: 0)
        var wakeNow: (@Sendable () -> Void)?
        lock.withLock {
            let gateRefusedNow = refusedThisWindow || blockedSinceUs != nil
            let gateRefusedRecently = refusedThisWindow || refusedLastWindow
            refusedLastWindow = refusedThisWindow
            refusedThisWindow = false

            latestSrttMs = report.snapshot.srttMs
            windowRetx += report.retransmitPacketsDelta
            var trigger = controller.tick(.init(nowUs: now, report: report, gateRefused: gateRefusedNow))

            let drops = lastDropsTotal.map { max(0, queueDropsTotal - $0) } ?? 0
            lastDropsTotal = queueDropsTotal
            windowDrops += drops
            if drops > 0, !gateRefusedRecently {
                result.reportedDrops = drops
                if controller.queueDropped(nowUs: now), trigger == nil { trigger = .queueDrop }
            }

            // Sustained blocking: the suppression above stops a keyframe from lowering the target, this stops it
            // from hiding a link that cannot carry the target.
            accrueBlockedLocked(at: now)
            if let last = lastTickUs {
                recent.append((tickBlockedUs, Self.elapsed(now, since: last), drops))
                if recent.count > Self.sustainedTicks { recent.removeFirst(recent.count - Self.sustainedTicks) }
            }
            lastTickUs = max(lastTickUs ?? 0, now)
            tickBlockedUs = 0
            if sustainedBlockingLocked() {
                recent.removeAll()
                if controller.blockedTooLong(nowUs: now), trigger == nil { trigger = .blocked }
            }
            if trigger != nil { windowDownSteps += 1 }

            result.trigger = trigger
            result.targetKbps = controller.targetKbps
            result.changed = result.targetKbps != reportedTargetKbps
            reportedTargetKbps = result.targetKbps
            if blockedSinceUs != nil, !stopped { wakeNow = wake }
        }
        wakeNow?()
        return result
    }

    /// Closes the log window (call about once a second).
    public func takeLogWindow() -> LogWindow {
        let now = nowUs()
        return lock.withLock {
            accrueBlockedLocked(at: now)  // the episode still open counts up to now
            let blockedUs = windowBlockedUs
            windowBlockedUs = 0
            let sorted = samples.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, (sorted.count * 95 + 99) / 100 - 1)]
            let w = LogWindow(targetKbps: controller.targetKbps, sendBufferP95: p95, srttMs: latestSrttMs,
                              admitsBlocked: windowBlocked, blockedMs: Int(blockedUs / 1_000),
                              budgetBytes: controller.budgetBytes, retransmitPackets: windowRetx,
                              queueDrops: windowDrops, downSteps: windowDownSteps)
            samples.removeAll(keepingCapacity: true)
            windowBlocked = 0
            windowRetx = 0
            windowDrops = 0
            windowDownSteps = 0
            return w
        }
    }

    // MARK: Internals

    /// The send buffer, from the cache when it is younger than `sampleFreshUs`. The syscall runs outside the lock.
    private func freshSendBuffer(at now: UInt64, force: Bool) -> UInt32? {
        if !force {
            let cached: UInt32? = lock.withLock {
                // `now` may be older than a sample another thread took meanwhile: that sample is fresh.
                guard let c = cachedBytes, Self.elapsed(now, since: cachedAtUs) < Self.sampleFreshUs else { return nil }
                return c
            }
            if let cached { return cached }
        }
        let read = readSendBuffer()
        lock.withLock {
            guard let read else { cachedBytes = nil; return }
            cachedBytes = read
            cachedAtUs = now
            if samples.count < Self.maxWindowSamples { samples.append(read) }
        }
        return read
    }

    /// `now - since`, 0 when `since` is later: timestamps are taken on different threads before the lock, so one can
    /// be older than a value another thread stored meanwhile. A wrapped difference must never reach an accumulator.
    static func elapsed(_ now: UInt64, since: UInt64) -> UInt64 { now > since ? now - since : 0 }

    /// Must hold `lock`. Adds the time the open refusal has lasted since it was last counted to the log window and to
    /// the current tick, and moves its start to `now` (never backwards).
    private func accrueBlockedLocked(at now: UInt64) {
        guard let since = blockedSinceUs else { return }
        let e = Self.elapsed(now, since: since)
        windowBlockedUs &+= e
        tickBlockedUs &+= e
        blockedSinceUs = max(since, now)
    }

    /// Must hold `lock`. The refusal ended: the time it lasted goes into the window.
    private func closeEpisodeLocked(at now: UInt64) {
        if blockedSinceUs != nil {
            accrueBlockedLocked(at: now)
            blockedSinceUs = nil
        }
        retryDelayUs = Self.retryFirstUs
    }

    /// Must hold `lock`. Whether the last `sustainedTicks` ticks show the gate closed for most of the time while the
    /// host queue was dropping frames.
    private func sustainedBlockingLocked() -> Bool {
        guard recent.count >= Self.sustainedTicks else { return false }
        var blocked: UInt64 = 0, span: UInt64 = 0, drops = 0
        for r in recent { blocked &+= r.blockedUs; span &+= r.spanUs; drops += r.drops }
        return drops > 0 && span > 0 && blocked * 100 >= span * Self.sustainedBlockedPercent
    }

    /// Must hold `lock`. The delay to arm the retry with; nil when one is armed already or the object is stopped.
    private func armRetryLocked() -> UInt64? {
        guard !retryArmed, !stopped else { return nil }
        retryArmed = true
        let delay = retryDelayUs
        retryDelayUs = min(retryDelayUs * 2, Self.retryMaxUs)
        return delay
    }

    private func scheduleRetry(afterUs: UInt64) {
        schedule(afterUs) { [weak self] in self?.retryFired() }
    }

    /// Retry timer: samples again; wakes the sender when the buffer has drained, re-arms while it has not.
    private func retryFired() {
        let now = nowUs()
        lock.withLock { retryArmed = false }
        let bytes = freshSendBuffer(at: now, force: true)
        var arm: UInt64?
        var wakeNow: (@Sendable () -> Void)?
        lock.withLock {
            guard !stopped, blockedSinceUs != nil else { return }
            if let bytes, !controller.mayWrite(sendBufferBytes: bytes) {
                arm = armRetryLocked()
            } else {
                wakeNow = wake  // admission would pass: the sender asks again and closes the episode
            }
        }
        if let arm { scheduleRetry(afterUs: arm) }
        wakeNow?()
    }
}
