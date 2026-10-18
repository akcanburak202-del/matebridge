// Bounded decode queue rules of the camera stream (docs/PROTOCOL.md section 5 "Kamera"). Pure and clock-free: the
// owner (the camera connection service, one serial queue) feeds events with `now` in microseconds and acts on the
// returned decisions. The gate only counts; the frames themselves travel on the owner's decode queue, and the
// `epoch` lets queued work that was thrown away be recognised and skipped.

public struct CameraStreamGate: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Hand the frame to the decoder queue with this epoch.
        case submit(epoch: UInt64)
        /// Not decodable now (no keyframe yet): dropped without a request of its own.
        case dropAwaitingKeyframe
        /// More than `maxPending` frames waited: all waiting work is void (epoch advanced), this frame is dropped and
        /// the next keyframe is wanted.
        case overflow(request: CamKeyframeReason?)
    }

    /// Frames handed to the decoder and not yet finished.
    public static let defaultMaxPending = 2
    /// One request, then silence for this long (PROTOCOL.md 0x63).
    public static let requestIntervalUs: UInt64 = 500_000
    /// While a keyframe is still missing the request repeats at this interval.
    public static let repeatIntervalUs: UInt64 = 1_000_000

    public let maxPending: Int
    public private(set) var epoch: UInt64 = 0
    public private(set) var pending = 0
    public private(set) var awaitingKeyframe = true

    private var lastRequestUs: UInt64?

    public struct Counters: Equatable, Sendable {
        public var received = 0
        public var decoded = 0
        public var dropped = 0
        public var decodeErrors = 0
        public var requests = 0
    }

    public private(set) var counters = Counters()

    public init(maxPending: Int = defaultMaxPending) { self.maxPending = max(1, maxPending) }

    /// A new camera connection became active: nothing is decodable until `CODEC_CONFIG` + a keyframe arrive.
    public mutating func reset() {
        epoch &+= 1
        pending = 0
        awaitingKeyframe = true
        lastRequestUs = nil
    }

    /// The first request after the proof (`STARTUP`) ignores the interval and starts it.
    public mutating func startupRequest(now: UInt64) -> CamKeyframeReason? {
        request(.startup, now: now)
    }

    /// `CODEC_CONFIG` always goes to the decoder (it rebuilds the session) and never counts as a pending frame.
    /// A new config means the next picture must be a keyframe, and frames queued before it are void (new epoch).
    public mutating func codecConfig() -> Decision {
        epoch &+= 1
        pending = 0
        awaitingKeyframe = true
        return .submit(epoch: epoch)
    }

    /// One `CAM_FRAME` (not config).
    public mutating func frame(keyframe: Bool, now: UInt64) -> Decision {
        counters.received += 1
        if awaitingKeyframe, !keyframe {
            counters.dropped += 1
            return .dropAwaitingKeyframe
        }
        if pending >= maxPending {
            epoch &+= 1
            pending = 0
            awaitingKeyframe = true
            counters.dropped += 1
            return .overflow(request: request(.framesDropped, now: now))
        }
        if keyframe { awaitingKeyframe = false }
        pending += 1
        return .submit(epoch: epoch)
    }

    /// The decoder finished a submitted frame (output or error). Work of an older epoch was already voided.
    public mutating func finished(epoch finishedEpoch: UInt64, decoded: Bool) {
        guard finishedEpoch == epoch else { return }
        pending = max(0, pending - 1)
        if decoded { counters.decoded += 1 }
    }

    /// The decoder failed on a frame of the current epoch: the reference chain is broken.
    public mutating func decodeFailed(epoch failedEpoch: UInt64, now: UInt64) -> CamKeyframeReason? {
        guard failedEpoch == epoch else { return nil }
        counters.decodeErrors += 1
        epoch &+= 1
        pending = 0
        awaitingKeyframe = true
        return request(.decodeError, now: now)
    }

    /// Repeats the request while a keyframe is missing (the client may have merged or lost the first one).
    public mutating func tick(now: UInt64) -> CamKeyframeReason? {
        guard awaitingKeyframe, let last = lastRequestUs, now >= last + Self.repeatIntervalUs else { return nil }
        return request(.framesDropped, now: now)
    }

    private mutating func request(_ reason: CamKeyframeReason, now: UInt64) -> CamKeyframeReason? {
        if let last = lastRequestUs, now < last + Self.requestIntervalUs { return nil }
        lastRequestUs = now
        counters.requests += 1
        return reason
    }

    /// Counters since the last call (the 10 s summary), then zero.
    public mutating func takeCounters() -> Counters {
        defer { counters = Counters() }
        return counters
    }
}
