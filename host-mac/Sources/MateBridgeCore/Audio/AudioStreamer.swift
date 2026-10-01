import Foundation

/// What a capture backend reports about the capture it was asked to start (`streamID` is its token).
public enum AudioCaptureEvent: Equatable, Sendable {
    /// The IOProc runs; packets flow into the stream's packetizer.
    case started(streamID: UInt16)
    /// Could not start (permission, no device, Core Audio error) or broke down. The backend tears it down itself.
    case failed(streamID: UInt16, reason: String, status: Int32)
    /// Has to be rebuilt: default output changed, the device died, or the Mac woke up.
    case interrupted(streamID: UInt16, reason: String)
}

/// The system audio capture (the host's `SystemAudioTap`; a fake in tests).
/// `start` and `stop` return at once; the work happens on the backend's own queue, where `start` may block for the
/// audio capture permission prompt. Requests are served in order, so a `stop` issued during a blocked `start` takes
/// effect right after it. `stop` of a stream that is not running is a no-op.
public protocol AudioCaptureBackend: AnyObject, Sendable {
    func start(streamID: UInt16, packetizer: AudioPacketizer,
               events: @escaping @Sendable (AudioCaptureEvent) -> Void)
    func stop(streamID: UInt16)
}

/// Where audio messages go: the control connection of session `sessionID` (the host's `SessionServer`).
public protocol AudioSink: AnyObject, Sendable {
    /// Fire and forget. Ignored when `sessionID` is no longer the active session. `AUDIO_FRAME`s may be dropped
    /// when the connection is backed up (counted, see `takeAudioWireDrops`); `AUDIO_CONFIG` is never dropped.
    func sendAudio(sessionID: UInt32, _ message: Message)
    /// AUDIO_FRAMEs dropped since the last call.
    func takeAudioWireDrops() -> Int
}

/// `MATEBRIDGE_AUDIO=off` turns audio off completely (experiment knob). Anything else, or unset, leaves it on.
public enum AudioKnob {
    public static func isDisabled(_ env: [String: String]) -> Bool {
        env["MATEBRIDGE_AUDIO"]?.trimmingCharacters(in: .whitespaces).lowercased() == "off"
    }
}

/// Host audio streaming (decision 0011): drives `AudioStreamPolicy`, starts and stops the capture backend, and
/// sends the packets of the running stream as `AUDIO_FRAME` on the control connection.
///
/// All state lives on one serial queue. The sender is a timer on that queue (every `drainInterval`) that reads the
/// ring (at most `maxPendingPackets` = 100 ms behind; older audio is dropped) and hands frames to the sink. Since
/// `AUDIO_CONFIG` and `AUDIO_FRAME` leave from the same queue, STARTED always precedes the stream's frames and nothing
/// of a stream follows its STOPPED. Session end stops the capture immediately (no video grace period).
public final class AudioStreamer: @unchecked Sendable {
    public struct Options: Sendable {
        public var ringCapacity = 16
        /// 10 packets = 100 ms (PROTOCOL.md 5).
        public var maxPendingPackets = 10
        /// nil: no timer (tests drive `drainNow`).
        public var drainInterval: DispatchTimeInterval? = .milliseconds(5)
        public var statsIntervalUs: UInt64 = 1_000_000
        /// Overrides the policy's rebuild retry delay (tests). nil: the policy's delay.
        public var retryDelay: DispatchTimeInterval?
        public init() {}
    }

    public struct Clock: Sendable {
        /// Host monotonic clock, microseconds (same as `VIDEO_FRAME.capture_time_us`).
        public var nowUs: @Sendable () -> UInt64
        /// Host time in mach ticks (IOProc `mHostTime`) to the same clock in microseconds. Linear: also converts
        /// durations.
        public var hostTicksToUs: @Sendable (UInt64) -> UInt64

        public init(nowUs: @escaping @Sendable () -> UInt64, hostTicksToUs: @escaping @Sendable (UInt64) -> UInt64) {
            self.nowUs = nowUs
            self.hostTicksToUs = hostTicksToUs
        }
    }

    /// `(level, event, sessionID, fields)`. Fields carry counters only, never audio.
    public typealias Log = @Sendable (LogLevel, String, UInt32, String) -> Void

    private struct Stream {
        var id: UInt16
        var sessionID: UInt32
        var packetizer: AudioPacketizer
        var seq: UInt32 = 0
        /// STARTED sent: frames may flow.
        var live = false
    }

    private let queue = DispatchQueue(label: "dev.matebridge.audio", qos: .userInitiated)
    private let backend: AudioCaptureBackend
    private let clock: Clock
    private let options: Options
    private let log: Log
    private weak var sink: AudioSink?
    private var policy: AudioStreamPolicy
    private var stream: Stream?
    private var timer: DispatchSourceTimer?
    private var stats = AudioStatsWindow()
    private var statsStartUs: UInt64 = 0
    /// Session id for log lines (kept after the session ended so its stop lines still carry it).
    private var logSessionID: UInt32 = 0

    private static let packetMs = Int(AudioStreamPolicy.framesPerPacket) * 1000 / Int(AudioStreamPolicy.sampleRate)

    public init(backend: AudioCaptureBackend, disabled: Bool, clock: Clock, options: Options = Options(),
                log: @escaping Log) {
        self.backend = backend
        self.clock = clock
        self.options = options
        self.log = log
        self.policy = AudioStreamPolicy(disabled: disabled)
    }

    /// Where messages go (set once the session server exists). Held weakly.
    public func attach(sink: AudioSink) {
        queue.async { [self] in self.sink = sink }
    }

    // MARK: Session events (any thread)

    public func sessionStarted(sessionID: UInt32, clientSupportsAudio: Bool) {
        queue.async { [self] in
            perform(policy.sessionEnded())
            logSessionID = sessionID
            perform(policy.sessionStarted(sessionID: sessionID, clientSupportsAudio: clientSupportsAudio))
        }
    }

    public func prefs(sessionID: UInt32, enabled: Bool) {
        queue.async { [self] in perform(policy.prefs(sessionID: sessionID, enabled: enabled)) }
    }

    public func sessionEnded() {
        queue.async { [self] in perform(policy.sessionEnded()) }
    }

    /// App shutdown: stops everything before returning. The backend's teardown itself runs on its own queue.
    public func shutdown() {
        queue.sync { perform(policy.sessionEnded()) }
    }

    // MARK: Test hooks

    /// Waits until everything queued so far ran.
    func sync() { queue.sync {} }

    /// Runs one sender pass (and the stats check) synchronously.
    func drainNow() { queue.sync { tick() } }

    // MARK: Internals (queue)

    private func handle(_ event: AudioCaptureEvent) {
        switch event {
        case .started(let id):
            perform(policy.captureStarted(streamID: id))
        case .failed(let id, let reason, let status):
            perform(policy.captureFailed(streamID: id, reason: reason, status: status))
        case .interrupted(let id, let reason):
            perform(policy.captureInterrupted(streamID: id, reason: reason))
        }
    }

    private func perform(_ actions: [AudioStreamPolicy.Action]) {
        for action in actions {
            switch action {
            case .startCapture(let id):
                let packetizer = AudioPacketizer(ring: AudioPacketRing(
                    capacity: options.ringCapacity, framesPerPacket: Int(AudioStreamPolicy.framesPerPacket)))
                stream = Stream(id: id, sessionID: policy.sessionID ?? 0, packetizer: packetizer)
                backend.start(streamID: id, packetizer: packetizer) { [weak self] event in
                    guard let self else { return }
                    queue.async { self.handle(event) }
                }
            case .stopCapture(let id):
                if stream?.id == id {
                    stream = nil
                    stopTimer()
                }
                backend.stop(streamID: id)
            case .send(let sessionID, let config):
                if config.state == .started, stream?.id == config.streamID {
                    stream?.live = true
                    stats = AudioStatsWindow()
                    statsStartUs = clock.nowUs()
                    _ = sink?.takeAudioWireDrops()  // count from this stream's start
                    startTimer()
                }
                sink?.sendAudio(sessionID: sessionID, .audioConfig(config))
            case .scheduleRetry(let token, let delayUs):
                let delay = options.retryDelay ?? .microseconds(Int(clamping: delayUs))
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    perform(policy.retryDue(token: token))
                }
            case .log(let level, let ev, let fields):
                log(level, ev, logSessionID, fields)
            }
        }
    }

    private func startTimer() {
        guard timer == nil, let interval = options.drainInterval else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        drain()
        guard stream?.live == true else { return }
        let now = clock.nowUs()
        guard now &- statsStartUs >= options.statsIntervalUs else { return }
        stats.addWireDropped(sink?.takeAudioWireDrops() ?? 0)
        log(.info, "stats", logSessionID, stats.logFields)
        stats = AudioStatsWindow()
        statsStartUs = now
    }

    /// Sends every packet waiting in the ring (bounded by the ring's 100 ms window).
    private func drain() {
        guard var s = stream, s.live, let sink else { return }
        let ring = s.packetizer.ring
        stats.addDropped(ring.takeProducerDrops())
        for _ in 0..<(options.maxPendingPackets + 2) {
            let read = ring.next(maxPending: options.maxPendingPackets)
            stats.addDropped(read.dropped)
            stats.noteBacklog(packets: read.backlog, packetMs: Self.packetMs)
            guard let packet = read.packet else { break }
            let meta = packet.meta
            guard meta.frameCount > 0 else { continue }  // never produced; defensive
            let offsetUs = UInt64(meta.hostOffsetFrames) * 1_000_000 / UInt64(AudioStreamPolicy.sampleRate)
            let frame = AudioFrame(streamID: s.id, seq: s.seq, sampleIndex: meta.sampleIndex,
                                   captureTimeUs: clock.hostTicksToUs(meta.hostTime) &+ offsetUs,
                                   frameCount: UInt16(meta.frameCount), data: packet.data)
            s.seq &+= 1
            sink.sendAudio(sessionID: s.sessionID, .audioFrame(frame))
            stats.addPacket(frames: Int(meta.frameCount), channels: Int(AudioStreamPolicy.channels),
                            sumSquares: meta.sumSquares,
                            callbackUs: meta.callbackMaxTicks > 0 ? clock.hostTicksToUs(meta.callbackMaxTicks) : 0)
        }
        stream?.seq = s.seq
    }
}
