// Pointer half of the input state machine: POINTER_REL, POINTER_ABS (mouse and touch), the single left-button
// owner, the OR of the other buttons, and the finger gate (PROTOCOL.md section 7, decision 0006).
//
// Every message carries the source's complete button state, so the machine works on edges against the state the
// source last reported (`PointerSourceState.held`).

extension InputStateMachine {
    /// Handles one pointer message. `motion == nil` means "no movement" (a `POINTER_REL` with dx = dy = 0).
    ///
    /// Order of the returned actions: the move first, then the left button change, then right/middle/back/forward.
    mutating func handlePointer(_ source: Source, buttons rawButtons: PointerButtons, motion: MouseMotion?,
                                now: UInt64) -> [InjectAction] {
        guard source != .pen else { return [] }  // the pen has its own path
        var out: [InjectAction] = []
        let buttons = rawButtons.intersection(.known)
        var state = pointerStates[source] ?? PointerSourceState()
        let previous = state.held
        let macOthersBefore = macOtherButtons
        let dragBefore = macDragButton
        let gated = source == .touch && isTouchGateActive(at: now)

        // OWN-1: a left press is accepted only when nobody holds the left button (this includes pen contact:
        // OWN-3) and the finger gate is open (GATE-1). Only a press EDGE counts; holding while someone else owned
        // the button never converts into ownership.
        let leftPressed = buttons.contains(.left) && !previous.contains(.left)
        let leftReleased = !buttons.contains(.left) && previous.contains(.left)
        let acceptLeftPress = leftPressed && leftOwner == nil && !gated

        // Movement: the owner drags; while another source owns the button (or the pen touches) nothing else may
        // move the cursor; a finger that does not hold the button never moves it (palm rejection).
        if let motion {
            let allowed: Bool
            if leftOwner == source || acceptLeftPress {
                allowed = true
            } else if leftOwner != nil {
                allowed = false
            } else {
                allowed = source != .touch
            }
            if allowed { out.append(.mouseMove(motion, dragging: dragBefore)) }
        }

        // Left button.
        if acceptLeftPress {
            leftOwner = source
            out.append(.mouseButton(.left, down: true))
        } else if leftReleased && leftOwner == source {
            // OWN-4/GATE-3: the owner's release is always processed. A release by a non-owner is inert.
            leftOwner = nil
            out.append(.mouseButton(.left, down: false))
        }

        // OR-*: right, middle, back, forward are the union of all sources. A touch press inside the gate is not
        // accepted (GATE-1); a release is always applied (GATE-3).
        for button in MouseButton.allCases where button != .left {
            let bit = button.pointerButton
            if buttons.contains(bit) && !previous.contains(bit) {
                if !gated { state.contributing.insert(bit) }
            } else if !buttons.contains(bit) && previous.contains(bit) {
                state.contributing.remove(bit)
            }
        }
        state.held = buttons
        pointerStates[source] = state

        let macOthersAfter = macOtherButtons
        for button in MouseButton.allCases where button != .left {
            let bit = button.pointerButton
            let before = macOthersBefore.contains(bit)
            let after = macOthersAfter.contains(bit)
            if after && !before {
                out.append(.mouseButton(button, down: true))
            } else if before && !after {
                out.append(.mouseButton(button, down: false))
            }
        }
        return out
    }
}
