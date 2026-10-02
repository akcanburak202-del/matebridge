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
public struct KeyframeRequestCoalescer: Sendable {
    /// RTT + the bytes still in the socket buffer + IDR decode on the tablet; see the T-122 plan.
    public static let defaultWindowUs: UInt64 = 250_000
    /// A pending keyframe older than this no longer absorbs requests (safety net; the encoder keeps its force flag
    /// until a frame is submitted and re-arms it after a failed encode, so this should not trigger).
    public static let defaultPendingTimeoutUs: UInt64 = 1_000_000

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

    public let windowUs: UInt64
    public let pendingTimeoutUs: UInt64
    private var pending: Pending?
    private var lastWrittenUs: UInt64?
    private var window = Window()
    public private(set) var coalescedTotal = 0

    public init(windowUs: UInt64 = defaultWindowUs, pendingTimeoutUs: UInt64 = defaultPendingTimeoutUs) {
        self.windowUs = windowUs
        self.pendingTimeoutUs = pendingTimeoutUs
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
        return Decision(action: .forced, forceKeyframe: true, sinceIdrUs: since)
    }

    /// The host forced a keyframe on its own (queue overflow, refused frame, new consumer). Always forced by the
    /// caller; recorded so that client requests caused by the same hiccup coalesce with it.
    public mutating func internalForce(nowUs: UInt64, keyframesPushed: UInt64) {
        pending = Pending(sinceUs: nowUs, keyframesPushed: keyframesPushed)
    }

    /// A new consumer attached: earlier writes went to another connection.
    public mutating func reset(nowUs: UInt64, keyframesPushed: UInt64) {
        lastWrittenUs = nil
        pending = Pending(sinceUs: nowUs, keyframesPushed: keyframesPushed)
    }

    /// The write of a keyframe (any origin) completed.
    public mutating func keyframeWritten(nowUs: UInt64, bytes: Int) {
        pending = nil
        lastWrittenUs = nowUs
        window.count += 1
        window.bytesMax = max(window.bytesMax, bytes)
    }

    /// Keyframes written since the previous call (for the per-second stats line).
    public mutating func takeWindow() -> Window {
        defer { window = Window() }
        return window
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
