// Pinch part of the input state machine (PROTOCOL.md section 4 PINCH host rules, section 7 pinch watchdog).
//
// Rules (test-name prefix PINCH-*):
//   PINCH-1  one open gesture at a time; a BEGAN over an open gesture (pinch or scroll) first ends the old one.
//   PINCH-2  a BEGAN is ignored while a source owns the left button, and (TOUCH only) while the finger gate is
//            active (PROTOCOL.md section 7). The rest of that gesture is ignored too, because it never opened.
//   PINCH-3  CHANGED / ENDED / CANCELLED without an open gesture are ignored.
//   PINCH-4  a SCROLL BEGAN ends an open pinch (see `handleScroll`).
//   PINCH-5  500 ms without a PINCH message ends the gesture; release-all ends it too.

extension InputStateMachine {
    mutating func handlePinch(_ m: Pinch, now: UInt64) -> [InjectAction] {
        switch m.phase {
        case .began:
            // PINCH-2. An ignored BEGAN must not leave an older gesture open: its continuation would be taken for
            // the ignored one's.
            if leftOwner != nil || (m.source == .touch && isTouchGateActive(at: now)) {
                return forceEndPinch(.ignoredBegan)
            }
            var out: [InjectAction] = []
            if scrollOpen {
                scrollOpen = false
                out.append(.scroll(.forcedEnd, dx: 0, dy: 0))
            }
            out += forceEndPinch(.newPinch)
            pinchOpen = true
            lastPinchAt = now
            let center = m.source == .touch ? PinchCenter(x: m.x, y: m.y) : nil
            out.append(.pinch(.began, scale: 0, center: center))
            return out
        case .changed:
            guard pinchOpen else { return [] }
            lastPinchAt = now
            return [.pinch(.changed, scale: m.scale, center: nil)]
        case .ended:
            guard pinchOpen else { return [] }
            pinchOpen = false
            return [.pinch(.ended, scale: 0, center: nil)]
        case .cancelled:
            guard pinchOpen else { return [] }
            pinchOpen = false
            return [.pinch(.cancelled, scale: 0, center: nil)]
        }
    }

    /// Ends an open pinch on the host's own initiative and remembers why (for the log). No-op when none is open.
    mutating func forceEndPinch(_ cause: PinchEndCause) -> [InjectAction] {
        guard pinchOpen else { return [] }
        pinchOpen = false
        pendingPinchEnds.append(cause)
        return [.pinch(.forcedEnd(cause), scale: 0, center: nil)]
    }

    /// The forced ends since the last call, oldest first. The pipeline drains this after every machine call.
    mutating func takePinchForcedEnds() -> [PinchEndCause] {
        defer { pendingPinchEnds.removeAll() }
        return pendingPinchEnds
    }
}
