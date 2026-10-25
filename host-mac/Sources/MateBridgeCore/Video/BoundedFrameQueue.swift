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
    /// Deltas refused while awaiting a keyframe and deltas purged by `breakChain` (not in `droppedCount`).
    public private(set) var refusedCount = 0
    public private(set) var purgedByBreakCount = 0
    /// Every frame the queue discarded for any reason: overflow, purge, refusal, `breakChain` (T-258 loss accounting).
    public var discardedCount: Int { droppedCount + refusedCount + purgedByBreakCount }
    private var awaitingKeyframe = false
    /// T-378: the one frame the consumer popped, could not send (`.busy`) and handed back. It is the head: `pop()`
    /// returns it first, and it counts toward `count` / `capacity`, so downstream reservations (T-370) see it.
    /// Overflow never drops it: it is the oldest frame and was neither sealed nor sent, so the chain stays intact.
    private var held: EncodedVideoFrame?
    /// T-378: when on, a popped frame stays charged to the queue's reservation (`reservedCount`) until the consumer
    /// calls `settle()` (the transport accepted it, or refused it for good) or hands it back with `unpop`. Without
    /// this the frame vanishes from the downstream accounting between pop and unpop, and a capture admitted into the
    /// freed slot overflows the queue when the frame comes back. A reset (new consumer, resync, `removeAll`) drops the
    /// charge, so a stale `unpop` of a frame the reset discarded is refused (no resurrection).
    public var chargesPops = false
    private var chargedFrame: EncodedVideoFrame?  // the popped frame itself, for the config de-duplication in `push`
    private var charged: Bool { chargedFrame != nil }

    public init(capacity: Int = BoundedFrameQueue.defaultCapacity) {
        precondition(capacity >= 1)
        self.capacity = capacity
    }

    public var count: Int { frames.count + (held == nil ? 0 : 1) }
    public var isEmpty: Bool { frames.isEmpty && held == nil }
    /// `count` plus the popped frame still charged (see `chargesPops`): what downstream reservations and `push`'s
    /// overflow rule compare with `capacity`.
    public var reservedCount: Int { count + (charged ? 1 : 0) }
    /// A frame is handed back and waits to be offered again (T-378).
    public var hasHeldFrame: Bool { held != nil }
    /// Delta frames are refused until a keyframe is pushed (after a chain-breaking drop, a new consumer or a resync).
    public var isAwaitingKeyframe: Bool { awaitingKeyframe }
    /// A keyframe waits in the queue (it is about to be written).
    public var hasQueuedKeyframe: Bool { held?.isKeyframe == true || frames.contains(where: \.isKeyframe) }

    /// Adds a frame; returns how many frames were dropped to make room (0 or 1).
    @discardableResult
    public mutating func push(_ frame: EncodedVideoFrame) -> Int {
        // A new consumer must see CODEC_CONFIG then a keyframe: stale deltas still in flight are refused.
        if awaitingKeyframe {
            if frame.isKeyframe {
                awaitingKeyframe = false
            } else if !frame.isCodecConfig {
                refusedCount += 1
                return 1
            }
        }
        // The same parameter sets queued twice (encoder announcement racing a resync) are redundant.
        if frame.isCodecConfig {
            // T-378: also when the same config is held or charged (with the sender after a busy answer): a resync's
            // snapshot can reach the sender before the encoder announces it, and a duplicate would take a slot the
            // recovery keyframe needs.
            if frames.contains(where: { $0.isCodecConfig && $0.data == frame.data })
                || (held?.isCodecConfig == true && held?.data == frame.data)
                || (chargedFrame?.isCodecConfig == true && chargedFrame?.data == frame.data) { return 0 }
            // T-378: a CHANGED config supersedes an older one the sender retained (`held`) or still has (`charged`):
            // the stale one goes (a charged one's later `unpop` is refused), so it cannot take a slot the new config's
            // keyframe needs.
            if held?.isCodecConfig == true { held = nil }
            if chargedFrame?.isCodecConfig == true { chargedFrame = nil }
            // Changed parameter sets while only configs wait (after a resync): the newer config replaces them, so
            // the queue keeps room for the keyframe that follows. Configs queued behind real frames stay as they are.
            if !frames.isEmpty, frames.allSatisfy(\.isCodecConfig) { frames.removeAll() }
        }
        frames.append(frame)
        // A popped frame that is still charged (T-378) counts as if it were queued: if it comes back (`unpop`) the
        // queue must not exceed `capacity`, and the usual newest-wins / keyframe rules apply to what is queued now.
        guard frames.count + (held == nil ? 0 : 1) + (charged ? 1 : 0) > capacity else { return 0 }
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
        // A protected frame was dropped. Losing the only keyframe of the current chain (none left queued or held)
        // would leave later deltas referencing a missing IDR: ask for a new one and refuse deltas until it arrives,
        // exactly as for an unprotected drop (T-378).
        if dropped.isKeyframe, held?.isKeyframe != true, !frames.contains(where: \.isKeyframe) {
            keyframeNeeded = true
            awaitingKeyframe = true
        }
        return 1
    }

    public mutating func pop() -> EncodedVideoFrame? {
        let frame: EncodedVideoFrame?
        if let h = held {
            held = nil
            frame = h
        } else {
            frame = frames.isEmpty ? nil : frames.removeFirst()
        }
        chargedFrame = chargesPops ? frame : nil
        return frame
    }

    /// The consumer is done with the frame `pop()` returned (accepted, or refused for good): releases its charge.
    public mutating func settle() { chargedFrame = nil }

    /// T-378: gives back the frame `pop()` just returned because the transport was busy: it becomes the head again,
    /// with no change to the reference chain. At most one frame can be held (the consumer sends one at a time);
    /// returns false, holding nothing, when one already is.
    @discardableResult
    public mutating func unpop(_ frame: EncodedVideoFrame) -> Bool {
        // Refused when a reset discarded the pop's charge (its frame must not come back) or one is already held.
        guard held == nil, !chargesPops || charged else { return false }
        chargedFrame = nil
        held = frame
        return true
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
        held = nil  // belongs to the previous consumer's connection
        chargedFrame = nil
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
    public var first: EncodedVideoFrame? { held ?? frames.first }

    /// The reference chain was broken outside the queue (the sender dropped a frame, T-258 auxiliary stream): queued
    /// deltas are purged and deltas are refused until a keyframe is pushed. The caller asks the encoder for one.
    public mutating func breakChain() {
        // Every queued frame is later than the lost one. Deltas up to the first queued keyframe are useless; that
        // keyframe restarts the chain (so recovery is already satisfied and later deltas stay valid). Without one,
        // deltas are refused until a keyframe is pushed.
        // The held frame is the oldest: a keyframe restarts the chain (the deltas behind it stay valid); a held delta
        // is later than the lost frame and so is as useless as the queued ones before the next keyframe.
        let before = frames.count
        var heldDropped = 0
        var restarted = false
        if let h = held {
            if h.isKeyframe {
                restarted = true
            } else if !h.isProtected {
                held = nil
                heldDropped = 1
            }
        }
        var i = 0
        if restarted { i = frames.count }  // nothing to purge behind a held keyframe
        while i < frames.count {
            if frames[i].isKeyframe { restarted = true; break }
            if frames[i].isProtected { i += 1 } else { frames.remove(at: i) }
        }
        purgedByBreakCount += before - frames.count + heldDropped
        if !restarted { awaitingKeyframe = true }
    }

    public mutating func removeAll() {
        frames.removeAll()
        held = nil
        chargedFrame = nil
    }
}
