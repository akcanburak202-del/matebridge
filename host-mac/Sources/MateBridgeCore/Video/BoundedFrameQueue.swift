/// Bounded encoder-to-sink queue policy (PROTOCOL.md section 5): at most `capacity` (2) frames wait.
///
/// On overflow the oldest frame that is not a keyframe / CODEC_CONFIG is dropped. Because a dropped
/// delta frame breaks the reference chain, a keyframe is then requested (`takeKeyframeRequest`).
/// Dropping a keyframe never needs a request: it can only happen when a newer keyframe (or
/// config) is already queued or arriving.
public struct BoundedFrameQueue: Sendable {
    public static let defaultCapacity = 2

    public let capacity: Int
    private var frames: [EncodedVideoFrame] = []
    private var keyframeNeeded = false
    public private(set) var droppedCount = 0

    public init(capacity: Int = BoundedFrameQueue.defaultCapacity) {
        precondition(capacity >= 1)
        self.capacity = capacity
    }

    public var count: Int { frames.count }
    public var isEmpty: Bool { frames.isEmpty }

    /// Adds a frame; returns how many frames were dropped to make room (0 or 1).
    @discardableResult
    public mutating func push(_ frame: EncodedVideoFrame) -> Int {
        frames.append(frame)
        guard frames.count > capacity else { return 0 }
        // Oldest first: plain delta frame, else oldest non-config keyframe, else oldest overall.
        let idx = frames.firstIndex(where: { !$0.isProtected })
            ?? frames.firstIndex(where: { !$0.isCodecConfig })
            ?? 0
        let dropped = frames.remove(at: idx)
        droppedCount += 1
        if !dropped.isProtected { keyframeNeeded = true }
        return 1
    }

    public mutating func pop() -> EncodedVideoFrame? {
        frames.isEmpty ? nil : frames.removeFirst()
    }

    /// True once after a delta frame was dropped; the caller asks the encoder for a keyframe.
    public mutating func takeKeyframeRequest() -> Bool {
        defer { keyframeNeeded = false }
        return keyframeNeeded
    }

    public mutating func removeAll() {
        frames.removeAll()
    }
}
