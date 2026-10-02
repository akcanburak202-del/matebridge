/// Audio messages handed to the session server and waiting for its queue (decision 0011, PROTOCOL.md 5: at most
/// 100 ms of pending audio). Order is kept, so `AUDIO_CONFIG(STARTED)` precedes its frames and `STOPPED` follows
/// them. At most `maxFrames` `AUDIO_FRAME`s wait: a new frame beyond that replaces the oldest waiting frame (newest
/// wins). `AUDIO_CONFIG` is never dropped. Used under the server's lock; one drain pass takes everything.
public struct AudioOutbox: Sendable {
    public struct Item: Sendable {
        public var sessionID: UInt32
        public var message: Message
        /// Host clock when `push` was called (T-116 queue lag; 0 when the caller did not stamp it).
        public var pushedUs: UInt64 = 0
    }

    /// 10 packets = 100 ms.
    public static let maxFrames = 10
    /// Frames captured longer ago than this when they would be sealed are dropped (they would only be late).
    public static let maxAgeUs: UInt64 = 100_000

    public private(set) var items: [Item] = []
    private var frames = 0
    private var drainQueued = false

    public init() {}

    /// Adds `message`. Returns whether the caller must enqueue a drain pass (at most one is pending) and how many
    /// frames were dropped to make room (0 or 1). `nowUs` stamps the item (`pushedUs`).
    public mutating func push(sessionID: UInt32, _ message: Message,
                              nowUs: UInt64 = 0) -> (enqueueDrain: Bool, dropped: Int) {
        var dropped = 0
        if case .audioFrame = message {
            if frames >= Self.maxFrames, let oldest = items.firstIndex(where: { Self.isFrame($0.message) }) {
                items.remove(at: oldest)
                frames -= 1
                dropped = 1
            }
            frames += 1
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
            drainQueued = false
        }
        return items
    }

    /// True when `frame` was captured more than `maxAgeUs` before `nowUs` (same host clock).
    public static func isStale(_ frame: AudioFrame, nowUs: UInt64) -> Bool {
        nowUs > frame.captureTimeUs && nowUs - frame.captureTimeUs > maxAgeUs
    }

    private static func isFrame(_ message: Message) -> Bool {
        if case .audioFrame = message { return true }
        return false
    }
}
