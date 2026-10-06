// Local cursor (decision 0036, docs/PROTOCOL.md 0x0B-0x0D and section 5), the pure half on the Mac: what to send and in
// which order. Nothing here reads the cursor, posts anything or touches the capture; the host shell does that and
// reports back. Rule identifiers used as test-name prefixes: CUR-PLAN-* planner, CUR-CACHE-* shape cache,
// CUR-BOX-* outbox, CUR-GEO-* geometry, CUR-SHAPE-* shape layout, CUR-STAT-* counters.

/// What the host sampled: the hotspot on the video surface, whether the cursor is visible, and the id of its shape.
public struct CursorSnapshot: Equatable, Sendable {
    public var x: UInt16
    public var y: UInt16
    public var visible: Bool
    /// `CURSOR_SHAPE.shape_id`; `0` = no shape known (the client draws its built-in arrow).
    public var shapeID: UInt32

    public init(x: UInt16, y: UInt16, visible: Bool, shapeID: UInt32) {
        self.x = x
        self.y = y
        self.visible = visible
        self.shapeID = shapeID
    }
}

/// The state machine of one session's `CURSOR_PREFS` / `CURSOR_STATE` flow:
///
/// - `CURSOR_PREFS(1)`: tracking starts and the first sample goes out (the host sends the shape it needs and a state),
///   and only then is the cursor taken out of the video. `CURSOR_PREFS(0)` puts the cursor back into the video first
///   and only then stops sending (PROTOCOL.md 0x0B). Both video changes are asynchronous (ScreenCaptureKit), so the
///   planner waits for their result before it moves on, and a request that arrives meanwhile is applied afterwards.
/// - A video cursor that cannot be changed leaves the cursor in the video and `CURSOR_*` stops (PROTOCOL.md 0x0B
///   "Host uygulayamazsa"); the planner then forgets the request, because the tablet asks again by itself after its
///   timeout.
/// - While on, a sample that differs from the last sent one goes out when `minIntervalUs` has passed since that send
///   (the newest sample always wins: nothing is queued here), and an unchanged one goes out every `keepAliveUs`.
///
/// A value type for one context (the host's cursor queue); every time is the host clock in microseconds.
public struct CursorStreamPlanner: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// At most one `CURSOR_STATE` per this interval for changes (PROTOCOL.md 0x0D: about 8 ms).
        public var minIntervalUs: UInt64 = 8_000
        /// At least one `CURSOR_STATE` per this interval, changed or not (PROTOCOL.md 0x0D, decision 0036: 500 ms).
        public var keepAliveUs: UInt64 = 500_000
        public init() {}
    }

    public enum Phase: Equatable, Sendable {
        /// Nothing is sent and the video shows the cursor.
        case off
        /// Tracking runs; the first sample has not gone out yet (the video still shows the cursor).
        case enabling
        /// The first state is out; the cursor is being taken out of the video.
        case applyingHide
        case on
        /// The cursor is being put back into the video; states still flow until it is done.
        case applyingShow
    }

    /// What the host shell must do, in order.
    public enum Command: Equatable, Sendable {
        /// Start polling and take the first sample now.
        case startTracking
        case stopTracking
        /// Change the capture; answer with `videoCursorResult(ok:)`.
        case setVideoCursor(shows: Bool)
    }

    /// The answer to one sample.
    public struct Observation: Equatable, Sendable {
        /// The snapshot to send now, if any.
        public var send: CursorSnapshot?
        public var commands: [Command]
        /// A changed sample was held back by the interval: sample again at this host time (no sooner is useful).
        public var retryAtUs: UInt64?
    }

    public let configuration: Configuration
    public private(set) var phase: Phase = .off
    /// The tablet's last request (`CURSOR_PREFS`), until it is honored or fails.
    public private(set) var wanted = false
    private var lastSent: CursorSnapshot?
    private var lastSentAtUs: UInt64 = 0

    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }

    /// Samples are wanted (the tracker should poll) in every phase but `off`.
    public var isTracking: Bool { phase != .off }

    /// `CURSOR_PREFS`. Returns what to do now; the rest follows from `observe` and `videoCursorResult`.
    public mutating func prefs(enabled: Bool) -> [Command] {
        wanted = enabled
        return advance()
    }

    /// One sample of the cursor at host time `nowUs`.
    public mutating func observe(_ snapshot: CursorSnapshot, nowUs: UInt64) -> Observation {
        switch phase {
        case .off:
            return Observation(send: nil, commands: [], retryAtUs: nil)
        case .enabling:
            // Shape and state first, the video change after them (PROTOCOL.md 0x0B).
            phase = .applyingHide
            markSent(snapshot, nowUs: nowUs)
            return Observation(send: snapshot, commands: [.setVideoCursor(shows: false)], retryAtUs: nil)
        case .applyingHide, .on, .applyingShow:
            let elapsed = nowUs >= lastSentAtUs ? nowUs - lastSentAtUs : 0
            if snapshot != lastSent {
                guard elapsed >= configuration.minIntervalUs else {
                    return Observation(send: nil, commands: [], retryAtUs: lastSentAtUs + configuration.minIntervalUs)
                }
            } else if elapsed < configuration.keepAliveUs {
                return Observation(send: nil, commands: [], retryAtUs: nil)
            }
            markSent(snapshot, nowUs: nowUs)
            return Observation(send: snapshot, commands: [], retryAtUs: nil)
        }
    }

    /// The capture change asked for by `setVideoCursor` finished (`ok` false: it could not be done).
    public mutating func videoCursorResult(ok: Bool) -> [Command] {
        switch phase {
        case .applyingHide:
            if ok {
                phase = .on
                return advance()
            }
            // The cursor stays in the video and nothing is sent: the tablet times out and asks again later.
            wanted = false
            phase = .off
            lastSent = nil
            return [.stopTracking]
        case .applyingShow:
            // The flow stops either way. A refused show is not given up: `VideoCursorWish` keeps the wish on "cursor in
            // the video" and the host retries it (bounded backoff) and applies it to every capture that (re)starts.
            phase = .off
            lastSent = nil
            return [.stopTracking] + advance()
        case .off, .enabling, .on:
            return []  // stale
        }
    }

    /// The session is over: forget everything. The host puts the video cursor back by itself.
    public mutating func reset() {
        phase = .off
        wanted = false
        lastSent = nil
        lastSentAtUs = 0
    }

    private mutating func advance() -> [Command] {
        switch phase {
        case .off:
            guard wanted else { return [] }
            phase = .enabling
            return [.startTracking]
        case .enabling:
            guard !wanted else { return [] }
            phase = .off  // nothing was sent and the video was not touched
            return [.stopTracking]
        case .on:
            guard !wanted else { return [] }
            phase = .applyingShow
            return [.setVideoCursor(shows: true)]
        case .applyingHide, .applyingShow:
            return []  // the answer to the running change decides
        }
    }

    private mutating func markSent(_ snapshot: CursorSnapshot, nowUs: UInt64) {
        lastSent = snapshot
        lastSentAtUs = nowUs
    }
}
