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

    public let intervalUs: UInt64
    public let toleranceUs: UInt64
    public private(set) var nextSlotUs: UInt64?

    public init(streamFps: Int, toleranceUs: UInt64 = FrameGate.defaultToleranceUs) {
        intervalUs = 1_000_000 / UInt64(max(1, streamFps))
        self.toleranceUs = toleranceUs
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
    private var pending: (frame: Frame, ptsUs: UInt64)?
    public private(set) var lastSubmittedPtsUs: UInt64?
    private var overwrittenCount = 0

    public init(streamFps: Int, toleranceUs: UInt64 = FrameGate.defaultToleranceUs) {
        gate = FrameGate(streamFps: streamFps, toleranceUs: toleranceUs)
    }

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
        let wait = gate.waitUs(nowUs: nowUs)
        if slotFree, bypassGate || wait == 0 {
            // A newer frame goes out directly: whatever was waiting is older and must never follow it.
            if pending != nil { pending = nil; overwrittenCount += 1 }
            submitted(ptsUs: ptsUs, nowUs: nowUs)
            return .submit(frame)
        }
        if pending != nil { overwrittenCount += 1 }
        pending = (frame, ptsUs)
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
        let wait = gate.waitUs(nowUs: nowUs)
        if wait > 0 { return .retry(afterUs: wait) }
        pending = nil
        submitted(ptsUs: p.ptsUs, nowUs: nowUs)
        return .submit(p.frame)
    }

    private mutating func submitted(ptsUs: UInt64, nowUs: UInt64) {
        gate.accept(nowUs: nowUs)
        lastSubmittedPtsUs = ptsUs
    }
}
