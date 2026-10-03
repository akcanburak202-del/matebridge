/// Coalesces client `KEYFRAME_REQUEST`s (T-122): a request that arrives while a keyframe is already on its way, or
/// shortly after one was written, does not force another one.
///
/// Measured on the device (2026-10-02): 4–6 requests within 100–300 ms each forced a full 2800×1840 IDR (hundreds of
/// KB to ~1 MB). The link filled up (38 Mbps in that second) and audio fell behind. The later requests only meant that
/// the client had not seen the first IDR yet, so another IDR could not help.
///
/// Pure state (the caller passes the clock in microseconds and the queue's keyframe push count), no locking: the
/// owner serialises access.
///
/// Rules:
/// - `FRAMES_DROPPED`: coalesced while a keyframe is pending (forced, not yet written) for less than
///   `pendingTimeoutUs`, or written less than `windowUs` ago. Otherwise a keyframe is forced.
/// - `STARTUP` / `DECODE_ERROR` (and unknown reasons): the client rebuilt its decoder, so the codec config is always
///   re-sent and anything written before it is of no use. A keyframe is not forced only when the pending one is still
///   inside the encoder (not yet pushed to the queue): the caller's resync puts the config in front of it. This is
///   decided from `keyframesPushed`, read under the queue lock together with the resync; a mismatch can only cause an
///   extra keyframe, never a missing one.
/// - Nothing is swallowed forever: a coalesced request is covered by a keyframe on its way (at most
///   `pendingTimeoutUs`; after that the next request forces again) or by one written within the last `windowUs`.
///
/// Host-side queue drops (T-176, `hostDrop` / `checkDeferred`): a dropped delta breaks the reference chain and the
/// queue refuses deltas until a keyframe is pushed (see `BoundedFrameQueue`). Forcing that keyframe at once while
/// another one was still on its way put a second IDR on a link that was already backed up, which caused more drops
/// and more IDRs. Now the force is deferred while a keyframe is still in the encoder, queued, or being written, or was
/// written less than `windowUs` ago; it is issued when that window expires. The deferral never outlives
/// `pendingTimeoutUs`: then a keyframe is forced regardless, and it is watched again in the same way until the queue
/// stops awaiting a keyframe. So the queue is never left awaiting a keyframe with none on its way and no force due.
public struct KeyframeRequestCoalescer: Sendable {
    /// RTT + the bytes still in the socket buffer + IDR decode on the tablet; see the T-122 plan.
    public static let defaultWindowUs: UInt64 = 250_000
    /// A pending keyframe older than this no longer absorbs requests (safety net; the encoder keeps its force flag
    /// until a frame is submitted and re-arms it after a failed encode, so this should not trigger).
    public static let defaultPendingTimeoutUs: UInt64 = 1_000_000
    /// Re-check interval for a deferred host-side keyframe while one is on its way but its write has not completed.
    public static let defaultPollUs: UInt64 = 50_000

    public enum Action: String, Sendable {
        case forced
        case coalesced
        case configResent = "config_resent"
    }

    public struct Decision: Equatable, Sendable {
        public var action: Action
        /// The caller must force a keyframe from the encoder (after any resync).
        public var forceKeyframe: Bool
        /// Time since the last keyframe write completed, nil when none was written yet.
        public var sinceIdrUs: UInt64?

        public init(action: Action, forceKeyframe: Bool, sinceIdrUs: UInt64?) {
            self.action = action
            self.forceKeyframe = forceKeyframe
            self.sinceIdrUs = sinceIdrUs
        }

        /// `action=… idr_forced=0|1 since_idr_ms=<n>|-` (LOGGING.md).
        public var logFields: String {
            let since = sinceIdrUs.map { String($0 / 1000) } ?? "-"
            return "action=\(action.rawValue) idr_forced=\(forceKeyframe ? 1 : 0) since_idr_ms=\(since)"
        }
    }

    /// Keyframes whose write completed since the last `takeWindow()`.
    public struct Window: Equatable, Sendable {
        public var count = 0
        public var bytesMax = 0
        public init(count: Int = 0, bytesMax: Int = 0) { self.count = count; self.bytesMax = bytesMax }
        /// `idr=<n> idr_bytes_max=<n>`.
        public var logFields: String { "idr=\(count) idr_bytes_max=\(bytesMax)" }
    }

    private struct Pending: Sendable {
        var sinceUs: UInt64
        /// Queue push count when the keyframe was forced: unchanged means the keyframe is still in the encoder.
        var keyframesPushed: UInt64
    }

    /// Outcome of `hostDrop` / `checkDeferred` (T-176).
    public struct HostDecision: Equatable, Sendable {
        /// The caller forces a keyframe from the encoder now.
        public var forceKeyframe: Bool
        /// Call `checkDeferred` at this time (host clock, µs). nil: nothing to watch (the queue does not await a
        /// keyframe).
        public var recheckAtUs: UInt64?

        public init(forceKeyframe: Bool, recheckAtUs: UInt64?) {
            self.forceKeyframe = forceKeyframe
            self.recheckAtUs = recheckAtUs
        }

        public static let idle = HostDecision(forceKeyframe: false, recheckAtUs: nil)
    }

    /// The queue awaits a keyframe after a host-side drop.
    private struct HostDeferral: Sendable {
        /// The drop, or the last keyframe force since then: the hard bound runs from here.
        var sinceUs: UInt64
        /// Queue push count at the drop: a later push means that drop was repaired.
        var keyframesPushed: UInt64
    }

    public let windowUs: UInt64
    public let pendingTimeoutUs: UInt64
    private var pending: Pending?
    private var lastWrittenUs: UInt64?
    private var window = Window()
    public private(set) var coalescedTotal = 0
    public let pollUs: UInt64
    private var hostDeferral: HostDeferral?
    /// A keyframe was seen queued (by `hostDrop` / `checkDeferred`) and its write has not completed yet.
    private var keyframeAheadSinceUs: UInt64?
    /// Host-side drops that forced a keyframe (at once or deferred), and drops that were deferred.
    public private(set) var hostForcedTotal = 0
    public private(set) var hostDeferredTotal = 0

    public init(windowUs: UInt64 = defaultWindowUs, pendingTimeoutUs: UInt64 = defaultPendingTimeoutUs,
                pollUs: UInt64 = defaultPollUs) {
        self.windowUs = windowUs
        self.pendingTimeoutUs = pendingTimeoutUs
        self.pollUs = max(1, pollUs)
    }

    /// A client request. `keyframesPushed`: the queue's keyframe push count, read before the caller forces anything;
    /// for a config reason it must be the value read under the queue lock together with the resync.
    /// `configResent`: the resync queued a config (false when no parameter sets exist yet).
    public mutating func request(_ reason: KeyframeReason, nowUs: UInt64, keyframesPushed: UInt64,
                                 configResent: Bool = false) -> Decision {
        let since = sinceIdrUs(nowUs: nowUs)
        if reason.resendsCodecConfig {
            // Only a keyframe that will be queued after the resync reaches the rebuilt decoder behind the config.
            let stillInEncoder = livePending(nowUs: nowUs).map { $0.keyframesPushed == keyframesPushed } ?? false
            if stillInEncoder { coalescedTotal += 1 } else {
                pending = Pending(sinceUs: nowUs, keyframesPushed: keyframesPushed)
                noteForce(nowUs: nowUs)
            }
            return Decision(action: configResent ? .configResent : (stillInEncoder ? .coalesced : .forced),
                            forceKeyframe: !stillInEncoder, sinceIdrUs: since)
        }
        let onItsWay = livePending(nowUs: nowUs) != nil
        let recentlyWritten = since.map { $0 < windowUs } ?? false
        if onItsWay || recentlyWritten {
            coalescedTotal += 1
            return Decision(action: .coalesced, forceKeyframe: false, sinceIdrUs: since)
        }
        pending = Pending(sinceUs: nowUs, keyframesPushed: keyframesPushed)
        noteForce(nowUs: nowUs)
        return Decision(action: .forced, forceKeyframe: true, sinceIdrUs: since)
    }

    /// The host forced a keyframe on its own, outside `hostDrop` (the sender's transport refused a frame). Always
    /// forced by the caller; recorded so that client requests caused by the same hiccup coalesce with it.
    public mutating func internalForce(nowUs: UInt64, keyframesPushed: UInt64) {
        pending = Pending(sinceUs: nowUs, keyframesPushed: keyframesPushed)
        noteForce(nowUs: nowUs)
    }

    /// The bounded queue dropped a delta and now awaits a keyframe (T-176). Forces one only when none is on its way
    /// (inside the encoder, queued, or being written) and none was written within `windowUs`; otherwise the force is
    /// deferred and the caller re-checks at `recheckAtUs` with `checkDeferred`. `queue`: read after the drop
    /// (`VideoFrameQueue.keyframeState`).
    public mutating func hostDrop(nowUs: UInt64, queue: KeyframeQueueState) -> HostDecision {
        guard queue.awaitingKeyframe else { return evaluateHost(nowUs: nowUs, queue: queue) }
        // A keyframe pushed since the previous deferral began repaired that drop: this one starts its own deferral.
        if hostDeferral.map({ $0.keyframesPushed != queue.keyframesPushed }) ?? true {
            hostDeferral = HostDeferral(sinceUs: nowUs, keyframesPushed: queue.keyframesPushed)
        }
        let d = evaluateHost(nowUs: nowUs, queue: queue)
        if !d.forceKeyframe { hostDeferredTotal += 1 }
        return d
    }

    /// Re-check of a deferred host-side keyframe (at or after `recheckAtUs`; an early call is harmless).
    public mutating func checkDeferred(nowUs: UInt64, queue: KeyframeQueueState) -> HostDecision {
        evaluateHost(nowUs: nowUs, queue: queue)
    }

    /// A new consumer attached: earlier writes went to another connection, and the caller forces a keyframe for it.
    public mutating func reset(nowUs: UInt64, keyframesPushed: UInt64) {
        lastWrittenUs = nil
        pending = Pending(sinceUs: nowUs, keyframesPushed: keyframesPushed)
        hostDeferral = nil
        keyframeAheadSinceUs = nil
    }

    /// The write of a keyframe (any origin) completed.
    public mutating func keyframeWritten(nowUs: UInt64, bytes: Int) {
        pending = nil
        keyframeAheadSinceUs = nil
        lastWrittenUs = nowUs
        window.count += 1
        window.bytesMax = max(window.bytesMax, bytes)
    }

    /// Keyframes written since the previous call (for the per-second stats line).
    public mutating func takeWindow() -> Window {
        defer { window = Window() }
        return window
    }

    /// Watches the queue while it awaits a keyframe after a host-side drop: forces when nothing covers the drop, or
    /// when the deferral reached `pendingTimeoutUs` (hard bound); otherwise says when to look again.
    private mutating func evaluateHost(nowUs: UInt64, queue: KeyframeQueueState) -> HostDecision {
        guard let deferral = hostDeferral, queue.awaitingKeyframe else {
            hostDeferral = nil
            return .idle
        }
        if queue.keyframeQueued, keyframeAheadSinceUs == nil { keyframeAheadSinceUs = nowUs }
        let hardDueUs = deferral.sinceUs &+ pendingTimeoutUs
        if nowUs < hardDueUs, let untilUs = coveredUntil(nowUs: nowUs, queue: queue) {
            return HostDecision(forceKeyframe: false, recheckAtUs: min(untilUs, hardDueUs))
        }
        pending = Pending(sinceUs: nowUs, keyframesPushed: queue.keyframesPushed)
        hostDeferral = HostDeferral(sinceUs: nowUs, keyframesPushed: queue.keyframesPushed)
        hostForcedTotal += 1
        // Watched further: should this keyframe never reach the queue, it is forced again after the timeout.
        return HostDecision(forceKeyframe: true, recheckAtUs: nowUs &+ pendingTimeoutUs)
    }

    /// Until when the queue's need for a keyframe is covered by one on its way or just written; nil: nothing covers it.
    private func coveredUntil(nowUs: UInt64, queue: KeyframeQueueState) -> UInt64? {
        if let p = livePending(nowUs: nowUs) {
            // Still in the encoder: it will be pushed after the drop and restart the chain. Already pushed: it is
            // queued or being written, and the window starts once its write completes.
            return p.keyframesPushed == queue.keyframesPushed ? p.sinceUs &+ pendingTimeoutUs : nowUs &+ pollUs
        }
        let aheadLive = keyframeAheadSinceUs.map { (nowUs >= $0 ? nowUs - $0 : 0) < pendingTimeoutUs } ?? false
        if queue.keyframeQueued || aheadLive { return nowUs &+ pollUs }
        if let since = sinceIdrUs(nowUs: nowUs), since < windowUs, let written = lastWrittenUs {
            return max(written &+ windowUs, nowUs &+ 1)
        }
        return nil
    }

    /// A keyframe was forced while a host-side deferral is active: the hard bound runs from this force.
    private mutating func noteForce(nowUs: UInt64) {
        hostDeferral?.sinceUs = nowUs
    }

    private func livePending(nowUs: UInt64) -> Pending? {
        guard let p = pending else { return nil }
        let age = nowUs >= p.sinceUs ? nowUs - p.sinceUs : 0
        return age < pendingTimeoutUs ? p : nil
    }

    private func sinceIdrUs(nowUs: UInt64) -> UInt64? {
        lastWrittenUs.map { nowUs >= $0 ? nowUs - $0 : 0 }
    }
}
