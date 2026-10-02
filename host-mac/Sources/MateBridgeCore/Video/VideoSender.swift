import Foundation

/// The network side of one video connection, as seen by `VideoSender`.
/// Contract (PROTOCOL.md section 5): at most a small fixed number of sends may be in flight; `send` returns false
/// and transmits nothing when the limit is reached or the frame is invalid.
public protocol VideoTransport: Sendable {
    var canSend: Bool { get }
    /// Called whenever an outstanding send completes. Pass nil to clear.
    func setReadyHandler(_ handler: (@Sendable () -> Void)?)
    @discardableResult
    func send(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void) -> Bool
}

/// Moves encoded frames from the bounded `VideoFrameQueue` to a `VideoTransport`.
///
/// Newest frame wins: the sender only pulls a frame when the transport can take it, so while the socket is
/// backed up frames stay in the 2-frame queue, where the oldest deltas are dropped and a keyframe is requested.
/// `frame_seq` is assigned here, at send time, so dropped frames never leave gaps (PROTOCOL.md section 4).
public final class VideoSender: @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        public var framesSent = 0
        public var keyframesSent = 0
        public var bytesSent = 0
        /// Frames the transport refused (invalid, e.g. over the payload limit); a keyframe was requested.
        public var framesRejected = 0
        public var sendFailures = 0
        public init() {}
    }

    public enum EndReason: Sendable { case queueClosed, transportFailed, cancelled }

    private let transport: VideoTransport
    private let frames: VideoFrameQueue
    private let requestKeyframe: @Sendable () -> Void
    private let onEnded: @Sendable (EndReason) -> Void
    private let trace: (@Sendable (FrameTrace) -> Void)?
    private let clock: @Sendable () -> UInt64
    private let lock = NSLock()
    private var counters = Counters()
    private var failed = false
    private var lastKeyframeRequestNs: UInt64?
    static let keyframeRequestIntervalNs: UInt64 = 500_000_000
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - requestKeyframe: asks the encoder for a keyframe (after a frame the transport refused).
    ///   - onEnded: the loop finished on its own or was stopped; called once, from the sender's task.
    ///   - trace: receives the finished `FrameTrace` of every frame whose write completed (T-070), stamped with
    ///     `clock` (must be the host clock the encoder stamps with). nil: no measuring, no clock reads.
    public init(transport: VideoTransport, frames: VideoFrameQueue,
                requestKeyframe: @escaping @Sendable () -> Void,
                onEnded: @escaping @Sendable (EndReason) -> Void = { _ in },
                trace: (@Sendable (FrameTrace) -> Void)? = nil,
                clock: @escaping @Sendable () -> UInt64 = { 0 }) {
        self.trace = trace
        self.clock = clock
        self.transport = transport
        self.frames = frames
        self.requestKeyframe = requestKeyframe
        self.onEnded = onEnded
    }

    public var currentCounters: Counters { lock.lock(); defer { lock.unlock() }; return counters }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [self] in
            let reason = await run()
            transport.setReadyHandler(nil)
            onEnded(reason)
        }
    }

    /// Stops the loop and waits for it to finish. Idempotent.
    public func stop() async {
        let t = lock.withLock { task }
        t?.cancel()
        await t?.value
    }

    private func run() async -> EndReason {
        let (ready, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        transport.setReadyHandler { signal.yield() }
        defer { signal.finish() }
        var iterator = ready.makeAsyncIterator()
        var seq: UInt32 = 0
        while !Task.isCancelled {
            while !transport.canSend {
                if hasFailed { return .transportFailed }
                guard await iterator.next() != nil else { return .cancelled }
            }
            if hasFailed { return .transportFailed }
            guard let encoded = await frames.next() else {
                if Task.isCancelled { return .cancelled }
                return hasFailed ? .transportFailed : .queueClosed
            }
            let frame = encoded.toVideoFrame(seq: seq)
            let size = frame.data.count
            var timing = encoded.trace
            let measure = trace != nil && !encoded.isCodecConfig
            if measure {
                timing.writeStartUs = clock()
                timing.isKeyframe = encoded.isKeyframe
                timing.bytes = size
            }
            let accepted = transport.send(frame) { [self, timing] ok in
                if !ok { markFailed(); signal.yield() }
                if ok, measure, let trace {
                    var done = timing
                    done.writeDoneUs = clock()
                    trace(done)
                }
            }
            record(accepted: accepted, bytes: size, keyframe: encoded.isKeyframe)
            if accepted {
                seq &+= 1
            } else if keyframeRequestAllowed() {
                requestKeyframe()
            }
        }
        return .cancelled
    }

    private func record(accepted: Bool, bytes: Int, keyframe: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if accepted {
            counters.framesSent += 1
            counters.bytesSent += bytes
            if keyframe { counters.keyframesSent += 1 }
        } else {
            counters.framesRejected += 1
        }
    }

    private var hasFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }

    /// A refused frame asks for a keyframe, but not more often than every 500 ms.
    private func keyframeRequestAllowed() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return lock.withLock {
            if let last = lastKeyframeRequestNs, now - last < Self.keyframeRequestIntervalNs { return false }
            lastKeyframeRequestNs = now
            return true
        }
    }

    private func markFailed() {
        lock.lock()
        failed = true
        counters.sendFailures += 1
        lock.unlock()
        frames.detachConsumer()  // wakes run() if it is waiting for a frame, so it ends promptly
    }
}
