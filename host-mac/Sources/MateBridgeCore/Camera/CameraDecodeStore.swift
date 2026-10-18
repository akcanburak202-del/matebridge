// Bounded storage between the camera connection and its decoder (T-357 r2, Codex P2). The decoder's serial queue used
// to get one closure per frame, each holding its frame data: a stalled decoder plus new keyframes could pile up more
// than the gate's limit. Here the frames live in this store instead (at most `capacity`, the gate's limit), and one
// drain closure at a time takes them out. A `CODEC_CONFIG` replaces every waiting frame and any older config (the
// gate voids those frames at the same moment, see `CameraStreamGate.codecConfig`). Not thread-safe by itself: the
// owner puts it behind a lock.

public struct CameraDecodeStore<Frame, Config> {
    public enum Item {
        case config(Config)
        case frame(Frame)
    }

    public let capacity: Int
    private var config: Config?
    private var frames: [Frame] = []
    private var drainScheduled = false
    private var dropped = 0

    public init(capacity: Int = CameraStreamGate.defaultMaxPending) { self.capacity = max(1, capacity) }

    public var frameCount: Int { frames.count }
    public var hasConfig: Bool { config != nil }

    /// Stores a config (newest wins) and drops waiting frames. Returns true when the caller must schedule a drain.
    public mutating func push(config newConfig: Config) -> Bool {
        config = newConfig
        dropped += frames.count
        frames.removeAll()
        return scheduleIfNeeded()
    }

    /// Stores a frame. When `capacity` frames already wait the oldest goes (the gate normally prevents this).
    /// Returns true when the caller must schedule a drain.
    public mutating func push(frame: Frame) -> Bool {
        if frames.count >= capacity {
            dropped += frames.count - capacity + 1
            frames.removeFirst(frames.count - capacity + 1)
        }
        frames.append(frame)
        return scheduleIfNeeded()
    }

    /// The next thing to do, the config first. nil ends the drain (and allows the next `push` to schedule one).
    public mutating func pop() -> Item? {
        if let c = config {
            config = nil
            return .config(c)
        }
        if !frames.isEmpty { return .frame(frames.removeFirst()) }
        drainScheduled = false
        return nil
    }

    /// Drops everything waiting (connection gone, overflow). A running drain just finds nothing.
    public mutating func clear() {
        config = nil
        dropped += frames.count
        frames.removeAll()
    }

    /// Drops waiting frames only; a waiting config stays valid (overflow, decode error).
    public mutating func clearFrames() {
        dropped += frames.count
        frames.removeAll()
    }

    /// Frames removed without being popped (replaced, evicted, cleared) since the last call: the owner retires them.
    public mutating func takeDropped() -> Int {
        defer { dropped = 0 }
        return dropped
    }

    private mutating func scheduleIfNeeded() -> Bool {
        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }
}

extension CameraDecodeStore.Item: Sendable where Frame: Sendable, Config: Sendable {}
