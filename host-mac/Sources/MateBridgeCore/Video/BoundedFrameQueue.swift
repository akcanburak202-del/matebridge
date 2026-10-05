/// Bounded encoder-to-sink queue policy (PROTOCOL.md section 5): at most `capacity` (2) frames wait.
///
/// On overflow the oldest frame that is not a keyframe / CODEC_CONFIG is dropped. Because a dropped
/// delta frame breaks the reference chain, a keyframe is then requested (`takeKeyframeRequest`) and deltas pushed
/// afterwards are refused until a keyframe has been pushed.
/// Dropping a keyframe never needs a request: it can only happen when a newer keyframe (or
/// config) is already queued or arriving.
///
/// **Drop policy and the reference chain (T-176).** The queue keeps "newest frame wins": it drops the oldest delta,
/// never refuses the newest one. Take `[IDR, d1]` plus `d2`: `d1` is dropped and `d2` purged, `IDR` stays. The queued
/// `IDR` does not repair the chain: every delta the encoder produces after `d2` references `d1` through `d2`, so all of
/// them are undecodable and a new keyframe is needed eventually. Deltas are therefore refused until that keyframe has
/// been pushed (`isAwaitingKeyframe`), and what is popped stays decodable: `IDR`, then the next keyframe.
/// What changes is *when* that keyframe is forced: `takeKeyframeRequest` only says one is needed. The pipeline lets
/// `KeyframeRequestCoalescer.hostDrop` decide, which defers the force while a keyframe is still on its way (in the
/// encoder, queued here: `hasQueuedKeyframe`, or being written) or was written within its window. Forcing at once
/// put another IDR (hundreds of KB) on a link that was already backed up: more drops, more IDRs (positive feedback).
/// The coalescer keeps watching while the queue awaits a keyframe, so this state never outlives its pending timeout
/// without a force.
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
    /// Delta frames are refused until a keyframe is pushed (after a chain-breaking drop, a new consumer or a resync).
    public var isAwaitingKeyframe: Bool { awaitingKeyframe }
    /// A keyframe waits in the queue (it is about to be written).
    public var hasQueuedKeyframe: Bool { frames.contains(where: \.isKeyframe) }

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
            // The chain is broken: deltas queued after the dropped one reference it and are purged, up to the next
            // keyframe (CODEC_CONFIG in between stays). A surviving keyframe restarts the chain, so recovery is
            // already satisfied: no keyframe request, and later deltas (which reference it) are accepted. Without
            // one, ask for a keyframe and refuse deltas until it arrives.
            var purged = 0
            var i = idx
            var restarted = false
            while i < frames.count {
                if frames[i].isKeyframe { restarted = true; break }
                if frames[i].isProtected { i += 1 } else { frames.remove(at: i); purged += 1 }
            }
            droppedCount += purged
            if !restarted {
                keyframeNeeded = true
                awaitingKeyframe = true
            }
            return 1 + purged
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

    /// The first queued frame, without removing it.
    public var first: EncodedVideoFrame? { frames.first }

    /// The reference chain was broken outside the queue (the sender dropped a frame, T-258 auxiliary stream): queued
    /// deltas are purged and deltas are refused until a keyframe is pushed. The caller asks the encoder for one.
    public mutating func breakChain() {
        frames.removeAll { !$0.isProtected }
        awaitingKeyframe = true
    }

    public mutating func removeAll() {
        frames.removeAll()
    }
}
