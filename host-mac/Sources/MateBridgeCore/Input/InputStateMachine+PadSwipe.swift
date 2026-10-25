// Three-finger touchpad swipe (decision 0043, PROTOCOL.md section 4 PAD_SWIPE host rules).
//
// Rules (test-name prefix SWIPE-*):
//   SWIPE-1  unknown direction or fingers != 3: ignored (not a protocol error).
//   SWIPE-2  ignored while a source owns the left button (a drag is going on).
//   SWIPE-3  ignored within `padSwipeMinIntervalUs` after the previous performed swipe.
//   SWIPE-4  an open scroll or pinch is force-ended first (the swipe replaces the gesture).
//   SWIPE-5  nothing is held afterwards: the swipe is one atomic key sequence (see `InjectionPlanner`), so
//            `hasHeldInput`, `heldKeys` and release-all are untouched.

/// Why a PAD_SWIPE was ignored (the `ignored=` field of the `pad_swipe` log event).
public enum PadSwipeIgnoreReason: String, Equatable, Sendable {
    case rate
    case drag
    case fingers
    case dir
}

/// What became of one PAD_SWIPE message, for the log (never coordinates, never keys).
public enum PadSwipeOutcome: Equatable, Sendable {
    case performed(PadSwipeDirection)
    case ignored(PadSwipeIgnoreReason)
}

extension InputStateMachine {
    mutating func handlePadSwipe(_ m: PadSwipe, now: UInt64) -> [InjectAction] {
        guard let direction = m.direction else { return ignorePadSwipe(.dir) }
        guard m.fingers == 3 else { return ignorePadSwipe(.fingers) }
        guard leftOwner == nil else { return ignorePadSwipe(.drag) }
        // A clock that went backwards must not lock the gesture out for good: count from `now`.
        if let last = lastPadSwipeAt, last <= now, now - last < configuration.padSwipeMinIntervalUs {
            return ignorePadSwipe(.rate)
        }
        lastPadSwipeAt = now
        var out: [InjectAction] = []
        if scrollOpen {
            scrollOpen = false
            out.append(.scroll(.forcedEnd, dx: 0, dy: 0))
        }
        out += forceEndPinch(.padSwipe)
        out.append(.padSwipe(direction))
        pendingPadSwipe.append(.performed(direction))
        return out
    }

    private mutating func ignorePadSwipe(_ reason: PadSwipeIgnoreReason) -> [InjectAction] {
        pendingPadSwipe.append(.ignored(reason))
        return []
    }

    /// The outcomes since the last call, oldest first. The pipeline drains this after every machine call.
    mutating func takePadSwipeOutcomes() -> [PadSwipeOutcome] {
        defer { pendingPadSwipe.removeAll() }
        return pendingPadSwipe
    }
}
