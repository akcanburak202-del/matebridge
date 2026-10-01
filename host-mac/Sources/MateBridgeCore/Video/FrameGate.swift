/// Host-side guard that keeps the *average* send rate at or below the stream fps (T-017).
///
/// ScreenCaptureKit runs with `minimumFrameInterval` = 1 / (2 x stream fps) so it never discards a frame that
/// arrives a hair early. That allows bursts faster than the stream fps. This gate hands out send slots on a fixed
/// grid: every accepted frame advances `nextSlotUs` by one stream interval, so the long-run rate cannot exceed the
/// stream fps. A frame may use its slot up to `toleranceUs` early (arrival jitter). If the gate falls more than one
/// interval behind the clock (idle screen, stall) it re-anchors to "now" instead of allowing a burst to catch up.
/// All times are on one clock (the host time clock), in microseconds.
public struct FrameGate: Sendable {
    public static let defaultToleranceUs: UInt64 = 2_000

    public private(set) var intervalUs: UInt64
    public private(set) var toleranceUs: UInt64
    public private(set) var nextSlotUs: UInt64?

    public init(streamFps: Int, toleranceUs: UInt64 = FrameGate.defaultToleranceUs) {
        intervalUs = 1_000_000 / UInt64(max(1, streamFps))
        self.toleranceUs = toleranceUs
    }

    /// Changes the send rate while running (T-058). The grid restarts: the next frame is accepted at once and
    /// anchors the new grid, so a rise is effective immediately and a fall starts from a clean slot.
    public mutating func setFps(_ fps: Int, toleranceUs: UInt64? = nil) {
        intervalUs = 1_000_000 / UInt64(max(1, fps))
        if let toleranceUs { self.toleranceUs = toleranceUs }
        nextSlotUs = nil
    }

    /// Microseconds from `nowUs` until a frame may be accepted; 0 = accept now.
    public func waitUs(nowUs: UInt64) -> UInt64 {
        guard let slot = nextSlotUs else { return 0 }
        let open = slot > toleranceUs ? slot - toleranceUs : 0
        return nowUs >= open ? 0 : open - nowUs
    }

    /// A frame was submitted at `nowUs`.
    public mutating func accept(nowUs: UInt64) {
        if let slot = nextSlotUs, nowUs <= slot + intervalUs {
            nextSlotUs = slot + intervalUs
        } else {
            nextSlotUs = nowUs + intervalUs   // first frame, or more than one interval behind: re-anchor
        }
    }
}

/// The single pending frame plus the `FrameGate`: decides, for every captured frame, whether it is submitted now,
/// held (newest wins) or dropped, and guarantees that submitted capture timestamps never go backwards.
/// Pure logic; `HEVCEncoder` owns one under its lock and does the actual submitting and timer scheduling.
public struct FramePacer<Frame: Sendable>: Sendable {
    public enum Offer: Sendable {
        case submit(Frame)
        /// Held as the pending frame. `retryAfterUs` is set when a slot is free but the gate is closed (the caller
        /// must call `takePending` after that delay); nil when the next slot release will do it.
        case hold(retryAfterUs: UInt64?)
        /// Older than the last submitted frame: discarded.
        case drop
    }
    public enum Take: Sendable {
        case submit(Frame)
        case retry(afterUs: UInt64)
        case none
    }

    public private(set) var gate: FrameGate
    public let streamFps: Int
    /// Target rate below the stream fps (T-058): captures are picked on the capture-timestamp grid, see `offer`.
    public private(set) var decimating = false
    private var decimatedCount = 0
    private var deferredCount = 0
    private let baseToleranceUs: UInt64
    /// `readyAtUs`: earliest time it may go out (0 = ready). `deferred`: it arrived before its grid slot and is only
    /// sent by the hold-last-frame timer (T-066), so the gate has not been advanced for it yet.
    private var pending: (frame: Frame, ptsUs: UInt64, readyAtUs: UInt64, deferred: Bool)?
    public private(set) var lastSubmittedPtsUs: UInt64?
    private var overwrittenCount = 0

    public init(streamFps: Int, toleranceUs: UInt64 = FrameGate.defaultToleranceUs) {
        self.streamFps = streamFps
        self.baseToleranceUs = toleranceUs
        gate = FrameGate(streamFps: streamFps, toleranceUs: max(toleranceUs, Self.passThroughToleranceUs(streamFps)))
    }

    /// Gate tolerance while not decimating (T-072): half a source interval. There the gate only has to cap the
    /// *average* rate (SCK already delivers at the stream fps), so a frame may use its grid slot up to half an
    /// interval early instead of waiting for a timer; the grid still advances one interval per accepted frame, so
    /// the long-run rate stays at or below the stream fps and no more than two frames of a burst pass within one
    /// interval. 2 ms was far less than the ±1-2 ms delivery jitter plus phase drift needs at 120 fps (8.33 ms).
    static func passThroughToleranceUs(_ fps: Int) -> UInt64 { 1_000_000 / UInt64(max(1, fps)) / 2 }

    /// Sets the target send rate (`min(stream fps, panel Hz)`, T-058). Below the stream fps the pacer decimates:
    /// the gate runs on capture timestamps and a frame that arrives before its slot is dropped, never held, so an
    /// old pending frame cannot be flushed by a timer between two grid frames (uneven motion). At or above the
    /// stream fps the pre-T-058 behaviour returns; a rise applies to the very next frame.
    public mutating func setTargetFps(_ fps: Int) {
        let target = min(max(1, fps), streamFps)
        decimating = target < streamFps
        // Decimation judges jittered capture timestamps: stay well below half a source interval, or a frame of the
        // dropped half could pass the gate.
        let sourceIntervalUs = 1_000_000 / UInt64(max(1, streamFps))
        gate.setFps(target, toleranceUs: decimating ? min(baseToleranceUs, sourceIntervalUs / 4)
                                                    : max(baseToleranceUs, Self.passThroughToleranceUs(streamFps)))
    }

    /// Captures replaced by a newer capture while waiting for their grid slot (intended, not a loss; T-066: a
    /// frame before its slot is held, so only a frame superseded by a newer one is counted).
    public mutating func takeDecimated() -> Int {
        defer { decimatedCount = 0 }
        return decimatedCount
    }

    /// Frames sent by the hold-last-frame timer because no grid frame followed them (T-066).
    public mutating func takeDeferred() -> Int {
        defer { deferredCount = 0 }
        return deferredCount
    }

    /// How long past its grid slot a held off-grid frame waits for a grid frame to supersede it: half a source
    /// interval (on top of the delivery lag, see `offer`). Grid frames arrive at the slot within the capture jitter (well under a quarter interval), so half
    /// an interval means "the stream went quiet", while the added latency stays below one source interval.
    var holdGraceUs: UInt64 { 1_000_000 / UInt64(max(1, streamFps)) / 2 }

    public var hasPending: Bool { pending != nil }

    /// Frames discarded since the last call (replaced pending frames and stale ones).
    public mutating func takeOverwritten() -> Int {
        defer { overwrittenCount = 0 }
        return overwrittenCount
    }

    public mutating func clearPending() { pending = nil }

    /// A captured frame. `slotFree`: the encoder can take a frame right now. `bypassGate`: keyframe re-submissions
    /// do not wait for the send-rate slot.
    public mutating func offer(_ frame: Frame, ptsUs: UInt64, nowUs: UInt64, slotFree: Bool,
                               bypassGate: Bool = false) -> Offer {
        if let last = lastSubmittedPtsUs, ptsUs <= last {
            overwrittenCount += 1
            return .drop
        }
        if decimating, !bypassGate {
            // The grid is on capture timestamps (one host clock). A frame before its slot is held (newest wins) and
            // goes out at slot + grace unless a grid frame replaces it first (T-066): the newest capture must
            // reach the encoder even when the content changed once and then stopped.
            guard gate.waitUs(nowUs: ptsUs) == 0 else {
                let slot = gate.nextSlotUs ?? ptsUs
                // `slot` is on the capture-timestamp grid but `readyAt` is compared with arrival time: add this
                // frame's own delivery lag (arrival - capture) so the next grid frame, which arrives with the same
                // lag, still beats the timer.
                let lag = nowUs > ptsUs ? nowUs - ptsUs : 0
                var readyAt = slot + lag + holdGraceUs
                var deferred = true
                if let old = pending {
                    decimatedCount += 1   // superseded by a newer capture
                    if !old.deferred { readyAt = old.readyAtUs; deferred = false }   // already passed the grid
                }
                pending = (frame, ptsUs, readyAt, deferred)
                return .hold(retryAfterUs: slotFree && deferred ? (readyAt > nowUs ? readyAt - nowUs : 0) : nil)
            }
            gate.accept(nowUs: ptsUs)
            if slotFree {
                if pending != nil { pending = nil; decimatedCount += 1 }
                lastSubmittedPtsUs = ptsUs
                return .submit(frame)
            }
            if pending != nil { overwrittenCount += 1 }
            pending = (frame, ptsUs, 0, false)
            return .hold(retryAfterUs: nil)   // the next slot release submits it
        }
        let wait = gate.waitUs(nowUs: nowUs)
        if slotFree, bypassGate || wait == 0 {
            // A newer frame goes out directly: whatever was waiting is older and must never follow it.
            if pending != nil { pending = nil; overwrittenCount += 1 }
            submitted(ptsUs: ptsUs, nowUs: nowUs)
            return .submit(frame)
        }
        if pending != nil { overwrittenCount += 1 }
        pending = (frame, ptsUs, 0, false)
        return .hold(retryAfterUs: slotFree ? wait : nil)
    }

    /// Call when a slot frees up or a retry timer fires. Eligibility uses the current time, not the capture time.
    public mutating func takePending(nowUs: UInt64, slotFree: Bool) -> Take {
        guard let p = pending, slotFree else { return .none }
        if let last = lastSubmittedPtsUs, p.ptsUs <= last {
            pending = nil
            overwrittenCount += 1
            return .none
        }
        // A decimated frame that passed the grid goes out as soon as a slot is free; one held before its slot waits
        // for slot + grace (a stale timer must not flush a newer pending frame early) and then advances the grid.
        let wait: UInt64
        if decimating { wait = p.readyAtUs > nowUs ? p.readyAtUs - nowUs : 0 } else { wait = gate.waitUs(nowUs: nowUs) }
        if wait > 0 { return .retry(afterUs: wait) }
        pending = nil
        if decimating {
            if p.deferred { gate.accept(nowUs: p.ptsUs); deferredCount += 1 }
            lastSubmittedPtsUs = p.ptsUs
        } else { submitted(ptsUs: p.ptsUs, nowUs: nowUs) }
        return .submit(p.frame)
    }

    private mutating func submitted(ptsUs: UInt64, nowUs: UInt64) {
        gate.accept(nowUs: nowUs)
        lastSubmittedPtsUs = ptsUs
    }
}
