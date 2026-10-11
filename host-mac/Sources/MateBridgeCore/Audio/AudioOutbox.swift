/// Audio messages handed to the session server and waiting for its queue (decision 0011, PROTOCOL.md 5: at most
/// 100 ms of pending audio). Order is kept, so `AUDIO_CONFIG(STARTED)` precedes its frames and `STOPPED` follows
/// them. At most `maxFrames` `AUDIO_FRAME`s and `maxPendingSampleFrames` (100 ms) of audio wait: a new frame beyond
/// that replaces the oldest waiting frame (newest wins). The time limit makes AAC (1024-frame units, about 21 ms)
/// hold 4 units, not 10. `AUDIO_CONFIG` is never dropped. Used under the server's lock; one drain pass takes everything.
public struct AudioOutbox: Sendable {
    public struct Item: Sendable {
        public var sessionID: UInt32
        public var message: Message
        /// Host clock when `push` was called (T-116 queue lag; 0 when the caller did not stamp it).
        public var pushedUs: UInt64 = 0
    }

    /// 10 packets = 100 ms.
    public static let maxFrames = 10
    /// 100 ms of audio at 48 kHz, in sample frames (PROTOCOL.md 5).
    public static let maxPendingSampleFrames = 4_800
    /// How many frames of `frameCount` sample frames make up at most 100 ms (at least 1). PCM 480: 10, AAC 1024: 4.
    public static func backlogFrames(frameCount: Int) -> Int {
        max(1, min(maxFrames, maxPendingSampleFrames / max(1, frameCount)))
    }

    /// Unsent-bytes mark of the control socket for a stream. PCM: all but one frame of the 100 ms window (the frame
    /// written after the check makes up the rest); exact in time because PCM frames have a fixed size.
    /// AAC: a fixed ~1 KB (about 3 nominal units, `aacNotSentLowatBytes`). The kernel part is byte-bounded only
    /// (PROTOCOL.md 5): unit sizes vary, and tiny units (near silence) can make the same bytes span more than 100 ms.
    /// That is accepted: such audio is nearly silent, and the client's 300 ms jitter cap is the upper bound. The
    /// user-space queue is time-bounded separately (sample frames, `maxPendingSampleFrames`).
    public static func notSentLowatBytes(for config: AudioConfig, framingBytes: Int) -> Int {
        if config.format == .aacLC { return aacNotSentLowatBytes }
        let frames = backlogFrames(frameCount: Int(config.framesPerPacket))
        return max(1, frames - 1) * (framingBytes + Int(config.framesPerPacket) * Int(config.channels) * 2)
    }

    public static let aacNotSentLowatBytes = 1_024

    /// Frames captured longer ago than this when they would be sealed are dropped (they would only be late).
    public static let maxAgeUs: UInt64 = 100_000

    public private(set) var items: [Item] = []
    private var frames = 0
    private var sampleFrames = 0
    private var drainQueued = false

    public init() {}

    /// Adds `message`. Returns whether the caller must enqueue a drain pass (at most one is pending) and how many
    /// frames were dropped to make room (0 or 1). `nowUs` stamps the item (`pushedUs`).
    public mutating func push(sessionID: UInt32, _ message: Message,
                              nowUs: UInt64 = 0) -> (enqueueDrain: Bool, dropped: Int) {
        var dropped = 0
        if case .audioFrame = message {
            let count = Self.sampleFrameCount(message)
            while frames >= Self.maxFrames || (frames > 0 && sampleFrames + count > Self.maxPendingSampleFrames),
                  let oldest = items.firstIndex(where: { Self.isFrame($0.message) }) {
                sampleFrames -= Self.sampleFrameCount(items[oldest].message)
                items.remove(at: oldest)
                frames -= 1
                dropped += 1
            }
            frames += 1
            sampleFrames += count
        }
        items.append(Item(sessionID: sessionID, message: message, pushedUs: nowUs))
        let enqueue = !drainQueued
        drainQueued = true
        return (enqueue, dropped)
    }

    /// The drain pass starts: everything waiting, in order.
    public mutating func take() -> [Item] {
        defer {
            items.removeAll(keepingCapacity: true)
            frames = 0
            sampleFrames = 0
            drainQueued = false
        }
        return items
    }

    /// True when `frame` was captured more than `maxAgeUs` before `nowUs` (same host clock).
    /// An AAC unit (more than 480 frames; the host's PCM packets are 480) is captured earlier than it can be sent: its
    /// time is that of its first decoded frame, so the encoder delay (2112 frames) and its own length (1024) are
    /// allowed on top.
    public static func isStale(_ frame: AudioFrame, nowUs: UInt64) -> Bool {
        let allowanceUs: UInt64 = frame.frameCount > AudioStreamPolicy.framesPerPacket ? aacAllowanceUs : 0
        return nowUs > frame.captureTimeUs && nowUs - frame.captureTimeUs > maxAgeUs + allowanceUs
    }

    public static let aacAllowanceUs: UInt64 = (2112 + 1024) * 1_000_000 / 48_000

    private static func sampleFrameCount(_ message: Message) -> Int {
        if case .audioFrame(let f) = message { return Int(f.frameCount) }
        return 0
    }

    private static func isFrame(_ message: Message) -> Bool {
        if case .audioFrame = message { return true }
        return false
    }
}
