/// The S (stall) signal of the Wi-Fi video controller (T-379, decision 0023 addendum 2026-10-25). Pure value type: no
/// clock reads, no I/O.
///
/// What it measures. Work is outstanding while a video record is being written (its first byte was handed to the
/// socket but the kernel has not taken all of it) or a frame waits at the head of the send queue. The kernel takes
/// bytes only as acknowledgements free its send buffer, so on a link that stopped carrying data the byte counter the
/// sender hands to the kernel stops. A stall is outstanding work that has seen no progress for `thresholdUs`.
///
/// - A large keyframe that is being written makes progress on every observation: not a stall, however long it takes.
/// - The grace is the threshold itself plus the observation interval (the owner observes every 100 ms): a stall is
///   reported at the first observation at least `thresholdUs` after the last progress or after the work appeared,
///   i.e. 150-250 ms into it.
/// - One stall is one event, however long it lasts; `activeUs` keeps growing until progress resumes.
public struct SendStallDetector: Equatable, Sendable {
    /// Idle time of outstanding work that makes a stall.
    public static let thresholdUs: UInt64 = 150_000

    public struct Observation: Equatable, Sendable {
        public var nowUs: UInt64
        /// Cumulative bytes the kernel has accepted from this connection's video writes (monotone).
        public var progressBytes: UInt64
        /// When the oldest outstanding work appeared (write start or queue head enqueue time); nil: nothing waits.
        public var outstandingSinceUs: UInt64?

        public init(nowUs: UInt64, progressBytes: UInt64, outstandingSinceUs: UInt64?) {
            self.nowUs = nowUs
            self.progressBytes = progressBytes
            self.outstandingSinceUs = outstandingSinceUs
        }
    }

    public struct Result: Equatable, Sendable {
        /// A stall started (crossed the threshold) at this observation.
        public var newEvent: Bool
        /// How long the current stall has lasted, measured from the last progress; 0 when there is none.
        public var activeUs: UInt64
    }

    private var lastProgressBytes: UInt64?
    private var lastProgressUs: UInt64 = 0
    private var stallStartUs: UInt64?

    public init() {}

    public mutating func observe(_ o: Observation) -> Result {
        let progressed = lastProgressBytes.map { o.progressBytes > $0 } ?? false
        if lastProgressBytes == nil || progressed {
            lastProgressUs = o.nowUs
            stallStartUs = nil
        }
        lastProgressBytes = o.progressBytes
        guard let since = o.outstandingSinceUs else {
            stallStartUs = nil
            return Result(newEvent: false, activeUs: 0)
        }
        let reference = max(lastProgressUs, since)
        let idle = o.nowUs > reference ? o.nowUs - reference : 0
        guard idle >= Self.thresholdUs else {
            stallStartUs = nil
            return Result(newEvent: false, activeUs: 0)
        }
        let isNew = stallStartUs == nil
        if isNew { stallStartUs = reference }
        return Result(newEvent: isNew, activeUs: o.nowUs > (stallStartUs ?? reference) ? o.nowUs - (stallStartUs ?? reference) : 0)
    }
}
