/// Bounded encoder-to-sink queue policy (PROTOCOL.md section 5): at most `capacity` (2) frames wait.
///
/// On overflow the oldest frame that is not a keyframe / CODEC_CONFIG is dropped. Because a dropped
/// delta frame breaks the reference chain, a keyframe is then requested (`takeKeyframeRequest`) and deltas pushed
/// afterwards are refused until a keyframe has been pushed.
/// Dropping a keyframe never needs a request: it can only happen when a newer keyframe (or
/// config) is already queued or arriving.
public struct BoundedFrameQueue: Sendable {
    public static let defaultCapacity = 2

    public let capacity: Int
    private var frames: [EncodedVideoFrame] = []
    private var keyframeNeeded = false
    public private(set) var droppedCount = 0
    private var awaitingKeyframe = false

    public init(capacity: Int = BoundedFrameQueue.defaultCapacity) {
        precondition(capacity >= 1)
        self.capacity = capacity
    }

    public var count: Int { frames.count }
    public var isEmpty: Bool { frames.isEmpty }

    /// Adds a frame; returns how many frames were dropped to make room (0 or 1).
    @discardableResult
    public mutating func push(_ frame: EncodedVideoFrame) -> Int {
        // A new consumer must see CODEC_CONFIG then a keyframe: stale deltas still in flight are refused.
        if awaitingKeyframe {
            if frame.isKeyframe { awaitingKeyframe = false } else if !frame.isCodecConfig { return 1 }
        }
        // The same parameter sets queued twice (encoder announcement racing a resync) are redundant.
        if frame.isCodecConfig {
            if frames.contains(where: { $0.isCodecConfig && $0.data == frame.data }) { return 0 }
            // Changed parameter sets while only configs wait (after a resync): the newer config replaces them, so
            // the queue keeps room for the keyframe that follows. Configs queued behind real frames stay as they are.
            if !frames.isEmpty, frames.allSatisfy(\.isCodecConfig) { frames.removeAll() }
        }
        frames.append(frame)
        guard frames.count > capacity else { return 0 }
        // Oldest first: plain delta frame, else oldest non-config keyframe, else oldest overall.
        let idx = frames.firstIndex(where: { !$0.isProtected })
            ?? frames.firstIndex(where: { !$0.isCodecConfig })
            ?? 0
        let dropped = frames.remove(at: idx)
        droppedCount += 1
        if !dropped.isProtected {
            // The chain is broken: ask for a keyframe and refuse later deltas until it arrives (their reference is gone).
            keyframeNeeded = true
            awaitingKeyframe = true
        }
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

    /// Resets for a newly attached consumer: the queue then holds only `config` (if any), and until a keyframe
    /// has been pushed, delta frames are refused. The caller must force a keyframe from the encoder.
    public mutating func startNewConsumer(config: EncodedVideoFrame?) {
        frames.removeAll()
        keyframeNeeded = false
        awaitingKeyframe = true
        if let config { frames.append(config) }
    }

    /// Keyframe resync for the current consumer (STARTUP / DECODE_ERROR request): stale frames are discarded, the
    /// queue holds only `config`, and deltas are refused until a keyframe arrives. Whatever keyframe the encoder is
    /// forced to produce afterwards is therefore queued behind `config`. Calling it again replaces the config
    /// instead of stacking a second one.
    public mutating func resync(config: EncodedVideoFrame) {
        startNewConsumer(config: config)
    }

    public mutating func removeAll() {
        frames.removeAll()
    }
}
