/// The S (stall) signal of the Wi-Fi video controller (T-379, decision 0023 addendum 2026-10-25). Pure value type: no
/// clock reads, no I/O.
///
/// What it measures. The kernel takes bytes only as acknowledgements free its send buffer, so on a link that stopped
/// carrying data the byte counter the writer hands to the kernel stops. A stall is outstanding work that has seen no
/// byte progress for `thresholdUs`. Two kinds of outstanding work:
/// - A record waiting in the connection's user-space queue. The writer times its own progress (`WriteGapMeter`), so
///   the span is exact: an open gap is measured to the microsecond, and a gap of at least the threshold that ended
///   between two polls is still reported (`writerLongGapsEnded`). Sampling phase does not matter.
/// - A frame at the head of the send queue while no record is pending (the sender is held back by the socket's
///   low-water mark). Its age is exact too; the last progress comes from the writer (`sinceProgressUs`). When the
///   frame is finally written, the sender hands the wait to the connection (`WriteGapMeter.headWaitEnded`), which
///   counts it as an ended gap, so a head-of-queue stall that ended between two polls is found too.
///
/// - A large keyframe that is being written makes progress all the time: not a stall, however long it takes.
/// - One stall is one event, however long it lasts; `activeUs` keeps growing until progress resumes.
public struct SendStallDetector: Equatable, Sendable {
    /// Idle time of outstanding work that makes a stall.
    public static let thresholdUs: UInt64 = 150_000

    public struct Observation: Equatable, Sendable {
        public var writerBusy: Bool
        /// Writer: time since the last progress while a record is pending (0 when not busy).
        public var writerOpenGapUs: UInt64
        /// Writer: gaps of at least the threshold that ended (cumulative) and the latest one's length.
        public var writerLongGapsEnded: UInt64
        public var writerLastLongGapUs: UInt64
        /// Time since the last byte progress, busy or not.
        public var sinceProgressUs: UInt64
        /// Age of the frame at the head of the send queue; nil when the queue is empty.
        public var headAgeUs: UInt64?

        public init(writerBusy: Bool = false, writerOpenGapUs: UInt64 = 0, writerLongGapsEnded: UInt64 = 0,
                    writerLastLongGapUs: UInt64 = 0, sinceProgressUs: UInt64 = 0, headAgeUs: UInt64? = nil) {
            self.writerBusy = writerBusy
            self.writerOpenGapUs = writerOpenGapUs
            self.writerLongGapsEnded = writerLongGapsEnded
            self.writerLastLongGapUs = writerLastLongGapUs
            self.sinceProgressUs = sinceProgressUs
            self.headAgeUs = headAgeUs
        }

        /// From a writer snapshot (nanoseconds) and the head frame's age.
        public init(_ s: WriteGapMeter.Snapshot, headAgeUs: UInt64?) {
            self.init(writerBusy: s.busy, writerOpenGapUs: s.openGapNs / 1_000, writerLongGapsEnded: s.longGapsEnded,
                      writerLastLongGapUs: s.lastLongGapNs / 1_000, sinceProgressUs: s.sinceProgressNs / 1_000,
                      headAgeUs: headAgeUs)
        }
    }

    public struct Result: Equatable, Sendable {
        /// A stall was found at this observation (one that started, or one that ended since the last observation).
        public var newEvent: Bool
        /// How long the stall still open has lasted; 0 when there is none.
        public var activeUs: UInt64
        /// Length of the longest stall that ended since the last observation; 0 when none.
        public var endedUs: UInt64

        public init(newEvent: Bool, activeUs: UInt64, endedUs: UInt64 = 0) {
            self.newEvent = newEvent
            self.activeUs = activeUs
            self.endedUs = endedUs
        }
    }

    private var lastEnded: UInt64 = 0
    private var writerOpenCounted = false
    private var headOpenCounted = false

    public init() {}

    public mutating func observe(_ o: Observation) -> Result {
        var events = 0
        var ended: UInt64 = 0
        var active: UInt64 = 0

        // Writer: gaps that ended since the last observation (the one we already counted as open is not counted twice).
        if o.writerLongGapsEnded > lastEnded {
            var n = Int(min(o.writerLongGapsEnded - lastEnded, 1_000))
            // A stall that was open (counted) at an earlier observation is the one that ended: not counted twice.
            if writerOpenCounted || headOpenCounted { n -= 1; writerOpenCounted = false; headOpenCounted = false }
            events += max(0, n)
            ended = o.writerLastLongGapUs
        }
        lastEnded = o.writerLongGapsEnded
        if o.writerBusy, o.writerOpenGapUs >= Self.thresholdUs {
            if !writerOpenCounted { events += 1; writerOpenCounted = true }
            active = o.writerOpenGapUs
        } else {
            writerOpenCounted = false
        }

        // Head of the queue, only while nothing is being written (otherwise the writer's view covers it).
        if !o.writerBusy, let age = o.headAgeUs {
            let idle = min(age, o.sinceProgressUs)
            if idle >= Self.thresholdUs {
                if !headOpenCounted { events += 1; headOpenCounted = true }
                active = max(active, idle)
            } else {
                headOpenCounted = false
            }
        } else {
            headOpenCounted = false
        }
        return Result(newEvent: events > 0, activeUs: active, endedUs: ended)
    }
}
