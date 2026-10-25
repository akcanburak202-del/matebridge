/// Writer-side timing of byte progress on one connection (T-379). Pure value type; the connection owns one under its
/// lock and feeds it the clock (monotone nanoseconds) at the moments bytes move.
///
/// Why here. A poll every 100 ms cannot tell when bytes last moved: a write that progresses at 1 ms, blocks until
/// 221 ms and finishes between two polls would leave no trace. The writer stamps the progress itself, so a no-progress
/// span of at least `thresholdNs` while a record was pending is counted when it ends (`longGapsEnded`), whatever the
/// polls saw, and a still open one is measured exactly (`openGapNs`).
public struct WriteGapMeter: Sendable {
    public static let thresholdNs: UInt64 = 150_000_000

    public struct Snapshot: Equatable, Sendable {
        /// Cumulative bytes the kernel accepted.
        public var acceptedBytes: UInt64
        /// Bytes still queued in user space, read in the same critical section as every other field.
        public var pendingBytes: Int
        /// A record is waiting to be written.
        public var busy: Bool
        /// Time since the last progress (or since the work appeared) while `busy`; 0 otherwise.
        public var openGapNs: UInt64
        /// Time since the last byte progress, busy or not (0 before the first one).
        public var sinceProgressNs: UInt64
        /// Gaps of at least `thresholdNs` that ended in progress, cumulative; `lastLongGapNs` is the latest one's length.
        public var longGapsEnded: UInt64
        public var lastLongGapNs: UInt64
    }

    private var acceptedBytes: UInt64 = 0
    private var lastProgressNs: UInt64?
    private var busy = false
    private var longGapsEnded: UInt64 = 0
    private var lastLongGapNs: UInt64 = 0

    public init() {}

    /// A record was queued. `wasIdle`: nothing was pending before it, so the no-progress clock starts now.
    public mutating func workQueued(nowNs: UInt64, wasIdle: Bool) {
        guard wasIdle else { return }
        busy = true
        lastProgressNs = nowNs
    }

    /// The kernel accepted `bytes` at `nowNs`.
    public mutating func progress(nowNs: UInt64, bytes: Int) {
        guard bytes > 0 else { return }
        if busy, let last = lastProgressNs, nowNs > last, nowNs - last >= Self.thresholdNs {
            longGapsEnded += 1
            lastLongGapNs = nowNs - last
        }
        lastProgressNs = nowNs
        acceptedBytes &+= UInt64(bytes)
    }

    /// Nothing is pending any more.
    public mutating func idle() { busy = false }

    public func snapshot(nowNs: UInt64, pendingBytes: Int) -> Snapshot {
        let since = lastProgressNs.map { nowNs > $0 ? nowNs - $0 : 0 } ?? 0
        return Snapshot(acceptedBytes: acceptedBytes, pendingBytes: pendingBytes, busy: busy,
                        openGapNs: busy ? since : 0, sinceProgressNs: since,
                        longGapsEnded: longGapsEnded, lastLongGapNs: lastLongGapNs)
    }
}
