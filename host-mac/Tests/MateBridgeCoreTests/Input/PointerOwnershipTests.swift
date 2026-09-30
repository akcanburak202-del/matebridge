import Testing
@testable import MateBridgeCore

// PROTOCOL.md section 7: left-button owner (OWN-*), other buttons as an OR (OR-*), and the finger gate (GATE-*,
// decision 0006).

/// The three pointer sources, with the messages and the move action each produces.
enum PtrSource: CaseIterable, CustomTestStringConvertible {
    case rel, mouse, touch

    var testDescription: String {
        switch self {
        case .rel: "POINTER_REL"
        case .mouse: "POINTER_ABS mouse"
        case .touch: "POINTER_ABS touch"
        }
    }

    func msg(_ buttons: PointerButtons, x: UInt16 = 500, y: UInt16 = 600) -> Message {
        switch self {
        case .rel: relMsg(0, 0, buttons)
        case .mouse: absMsg(.mouse, x, y, buttons)
        case .touch: absMsg(.touch, x, y, buttons)
        }
    }

    /// The move that precedes button changes of this source; `POINTER_REL` with dx = dy = 0 moves nothing.
    func move(x: UInt16 = 500, y: UInt16 = 600, dragging: MouseButton? = nil) -> [InjectAction] {
        self == .rel ? [] : [moveAbs(x, y, dragging: dragging)]
    }
}

/// Pen contact on the default point: hover, then touch.
private func penDown(_ d: inout Driver) {
    d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
    d.send(penMsg(.pen, penSample(2, 2, startFlags, pressure: 100)))
}

private func penUpAndLeave(_ d: inout Driver) {
    d.send(penMsg(.pen, penSample(3, 3, [])))
}

@Suite("OWN: single owner of the left button")
struct OwnershipTests {
    @Test("OWN-1 only the first source gets the left button; other sources' presses and releases are inert")
    func own1_singleOwner() {
        var d = Driver()
        #expect(d.send(absMsg(.touch, 500, 600, .left)) == [moveAbs(500, 600), .mouseButton(.left, down: true)])
        #expect(d.send(absMsg(.mouse, 10, 20, .left)).isEmpty)
        #expect(d.send(absMsg(.mouse, 11, 21, [])).isEmpty)
        #expect(d.send(relMsg(0, 0, .left)).isEmpty)
        #expect(d.send(relMsg(0, 0, [])).isEmpty)
        #expect(d.send(absMsg(.touch, 510, 610, [])) == [
            moveAbs(510, 610, dragging: .left), .mouseButton(.left, down: false),
        ])
        #expect(!d.machine.hasHeldInput)
    }

    @Test("OWN-2 pen contact takes the button from any owner: up on its behalf, then the pen down",
          arguments: PtrSource.allCases)
    func own2_penPriority(source: PtrSource) {
        var d = Driver()
        #expect(d.send(source.msg(.left)) == source.move() + [.mouseButton(.left, down: true)])
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(penMsg(.pen, penSample(2, 2, startFlags, pressure: 100))) == [
            .mouseButton(.left, down: false), .penDown(tool: .pen, penPt(2, 2, 100)),
        ])
        // The previous owner's continued hold and later release change nothing on the Mac.
        #expect(d.send(source.msg(.left, x: 700, y: 800)).isEmpty)
        #expect(d.send(source.msg([], x: 700, y: 800)).isEmpty)
        #expect(d.send(penMsg(.pen, penSample(4, 4, touchFlags, pressure: 120))) == [
            .penDrag(tool: .pen, penPt(4, 4, 120)),
        ])
    }

    @Test("OWN-2b after losing the button to the pen a source must release and press again",
          arguments: PtrSource.allCases)
    func own2b_mustRePress(source: PtrSource) {
        var d = Driver()
        d.send(source.msg(.left))
        penDown(&d)
        penUpAndLeave(&d)
        // Still holding: no edge, so no ownership (and no movement of a held finger).
        #expect(d.send(source.msg(.left), after: 2_000 * msec) == (source == .mouse ? [moveAbs()] : []))
        #expect(!d.machine.hasHeldInput)
        // Release, then press: a new press is accepted.
        d.send(source.msg([]))
        #expect(d.send(source.msg(.left)) == source.move() + [.mouseButton(.left, down: true)])
    }

    @Test("OWN-3 while the pen touches, other sources' left presses are ignored", arguments: PtrSource.allCases)
    func own3_penContactBlocksPresses(source: PtrSource) {
        var d = Driver()
        penDown(&d)
        #expect(d.send(source.msg(.left)).isEmpty)
        #expect(d.send(source.msg([])).isEmpty)
        #expect(d.machine.isPenInContact)
        // After the pen lifts, a press that was ignored must be repeated to count.
        d.send(source.msg(.left))
        penUpAndLeave(&d)
        let late = d.send(source.msg(.left), after: 2_000 * msec)
        #expect(!late.contains(.mouseButton(.left, down: true)))
        #expect(!d.machine.hasHeldInput)
    }

    @Test("OWN-3b a pen hover does not block mouse or trackpad presses")
    func own3b_hoverDoesNotBlockMouseAndRel() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(relMsg(0, 0, .left)) == [.mouseButton(.left, down: true)])
        #expect(d.send(relMsg(0, 0, [])) == [.mouseButton(.left, down: false)])
        #expect(d.send(absMsg(.mouse, 5, 6, .left)) == [moveAbs(5, 6), .mouseButton(.left, down: true)])
    }

    @Test("OWN-4 the owner's release frees the button for the next source")
    func own4_releaseHandsOver() {
        var d = Driver()
        d.send(absMsg(.mouse, 1, 2, .left))
        d.send(absMsg(.mouse, 1, 2, []))
        #expect(d.send(relMsg(0, 0, .left)) == [.mouseButton(.left, down: true)])
    }

    @Test("OWN-5 a press that was ignored never becomes ownership while it is merely held")
    func own5_ignoredPressStaysIgnored() {
        var d = Driver()
        d.send(absMsg(.touch, 500, 600, .left))
        d.send(absMsg(.mouse, 10, 20, .left))         // ignored: touch owns
        d.send(absMsg(.touch, 500, 600, []))           // touch releases, button is free
        // The mouse keeps holding: no new edge, cursor only hovers.
        #expect(d.send(absMsg(.mouse, 30, 40, .left)) == [moveAbs(30, 40)])
        // Its release is inert too (it never owned the button).
        #expect(d.send(absMsg(.mouse, 31, 41, [])) == [moveAbs(31, 41)])
        #expect(!d.machine.hasHeldInput)
    }

    @Test("OWN-6 only the owner moves the cursor while the button is held; nobody else while the pen touches")
    func own6_movement() {
        var d = Driver()
        d.send(absMsg(.touch, 500, 600, .left))
        #expect(d.send(absMsg(.mouse, 10, 20, [])).isEmpty)         // hover of another source is suppressed
        #expect(d.send(relMsg(4, 5, [])).isEmpty)
        #expect(d.send(absMsg(.touch, 520, 620, .left)) == [moveAbs(520, 620, dragging: .left)])
        d.send(absMsg(.touch, 520, 620, []))
        // Nobody owns: a mouse and a trackpad move freely.
        #expect(d.send(absMsg(.mouse, 10, 20, [])) == [moveAbs(10, 20)])
        #expect(d.send(relMsg(4, 5, [])) == [.mouseMove(.relative(dx: 4, dy: 5), dragging: nil)])
        // Pen contact silences them again.
        penDown(&d)
        #expect(d.send(absMsg(.mouse, 30, 40, [])).isEmpty)
        #expect(d.send(relMsg(4, 5, [])).isEmpty)
    }

    @Test("OWN-7 a finger that does not hold the button never moves the cursor")
    func own7_looseFingerIsSilent() {
        var d = Driver()
        #expect(d.send(absMsg(.touch, 500, 600, [])).isEmpty)
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        d.send(absMsg(.touch, 500, 600, .left))       // gated press
        #expect(d.send(absMsg(.touch, 510, 610, .left)).isEmpty)
    }

    @Test("OWN-8 relative motion drags with the owner's button and moves freely otherwise")
    func own8_relativeDrag() {
        var d = Driver()
        #expect(d.send(relMsg(3, 4, .left)) == [
            .mouseMove(.relative(dx: 3, dy: 4), dragging: nil), .mouseButton(.left, down: true),
        ])
        #expect(d.send(relMsg(1, 1, .left)) == [.mouseMove(.relative(dx: 1, dy: 1), dragging: .left)])
        #expect(d.send(relMsg(0, 0, [])) == [.mouseButton(.left, down: false)])
    }
    @Test("OWN-9 while a pointer source owns the left button the pen's hover moves do not reach the Mac; enter and leave do",
          arguments: PtrSource.allCases)
    func own9_hoverSuppressedWhileOwned(source: PtrSource) {
        var d = Driver()
        d.send(source.msg(.left))
        #expect(d.send(penMsg(.pen, penSample(60000, 60000, hoverFlags))) == [penEnter(.pen)])
        #expect(d.send(penMsg(.pen, penSample(60010, 60010, hoverFlags))).isEmpty)
        // Pen priority: the on-behalf up comes with no pen hover in between, so it lands at the owner's position.
        #expect(d.send(penMsg(.pen, penSample(60020, 60020, startFlags, pressure: 100))) == [
            .mouseButton(.left, down: false), .penDown(tool: .pen, penPt(60020, 60020, 100)),
        ])
        // Enter and contact in one sample: enter, on-behalf up, down.
        var e = Driver()
        e.send(source.msg(.left))
        #expect(e.send(penMsg(.pen, penSample(9, 9, startFlags, pressure: 100))) == [
            penEnter(.pen), .mouseButton(.left, down: false), .penDown(tool: .pen, penPt(9, 9, 100)),
        ])
        // Leaving range is still reported while the source owns the button.
        var f = Driver()
        f.send(source.msg(.left))
        f.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(f.send(penMsg(.pen, penSample(1, 1, []))) == [penLeave(.pen)])
    }

    @Test("OWN-9b the pen's hover moves resume as soon as the owner releases")
    func own9b_hoverResumes() {
        var d = Driver()
        d.send(absMsg(.mouse, 5, 5, .left))
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(penMsg(.pen, penSample(2, 2, hoverFlags))).isEmpty)
        d.send(absMsg(.mouse, 5, 5, []))
        #expect(d.send(penMsg(.pen, penSample(3, 3, hoverFlags))) == [.penHover(tool: .pen, penPt(3, 3))])
    }

    @Test("OWN-10 after the pen lifts but stays in range, mouse and trackpad presses are accepted at once; touch waits for the gate")
    func own10_pressAfterPenLift() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, startFlags, pressure: 100)))
        #expect(d.send(penMsg(.pen, penSample(2, 2, hoverFlags))) == [.penUp(tool: .pen, penPt(2, 2, 0))])
        #expect(d.machine.isPenInRange)
        #expect(d.send(relMsg(0, 0, .left)) == [.mouseButton(.left, down: true)])
        #expect(d.send(relMsg(0, 0, [])) == [.mouseButton(.left, down: false)])
        #expect(d.send(absMsg(.mouse, 7, 8, .left)) == [moveAbs(7, 8), .mouseButton(.left, down: true)])
        d.send(absMsg(.mouse, 7, 8, []))
        // A finger is still gated while the pen is in range, and for 1 s after its last sample.
        #expect(d.send(absMsg(.touch, 9, 9, .left)).isEmpty)
        d.send(absMsg(.touch, 9, 9, []))
        d.send(penMsg(.pen, penSample(2, 2, [])))          // leaves range; last pen sample
        #expect(d.send(absMsg(.touch, 9, 9, .left), after: 999_999).isEmpty)
        d.send(absMsg(.touch, 9, 9, []))
        #expect(d.send(absMsg(.touch, 9, 9, .left), after: 1) == [moveAbs(9, 9), .mouseButton(.left, down: true)])
    }
}

@Suite("OR: right, middle, back, forward are the union of all sources")
struct ButtonUnionTests {
    @Test("OR-1 down on the first source's press, up only when the last source releases")
    func or1_union() {
        var d = Driver()
        #expect(d.send(relMsg(0, 0, .right)) == [.mouseButton(.right, down: true)])
        #expect(d.send(absMsg(.mouse, 10, 20, .right)) == [moveAbs(10, 20, dragging: .right)])
        #expect(d.send(relMsg(0, 0, [])).isEmpty)
        #expect(d.send(absMsg(.mouse, 10, 20, [])) == [
            moveAbs(10, 20, dragging: .right), .mouseButton(.right, down: false),
        ])
        #expect(!d.machine.hasHeldInput)
    }

    @Test("OR-2 right, middle, back and forward map to their own buttons, in a fixed order")
    func or2_mapping() {
        var d = Driver()
        #expect(d.send(relMsg(0, 0, [.forward, .middle, .back])) == [
            .mouseButton(.middle, down: true), .mouseButton(.back, down: true), .mouseButton(.forward, down: true),
        ])
        #expect(d.send(relMsg(0, 0, [.back])) == [
            .mouseButton(.middle, down: false), .mouseButton(.forward, down: false),
        ])
        #expect(d.send(relMsg(0, 0, [])) == [.mouseButton(.back, down: false)])
    }

    @Test("OR-3 left and right are independent: left first, then the others")
    func or3_leftAndRight() {
        var d = Driver()
        #expect(d.send(relMsg(0, 0, [.left, .right])) == [
            .mouseButton(.left, down: true), .mouseButton(.right, down: true),
        ])
        #expect(d.send(relMsg(0, 0, [])) == [
            .mouseButton(.left, down: false), .mouseButton(.right, down: false),
        ])
    }

    @Test("OR-4 the drag button is left before right")
    func or4_dragPriority() {
        var d = Driver()
        d.send(relMsg(0, 0, .right))
        #expect(d.send(absMsg(.mouse, 5, 5, .left)) == [moveAbs(5, 5, dragging: .right), .mouseButton(.left, down: true)])
        #expect(d.send(absMsg(.mouse, 6, 6, .left)) == [moveAbs(6, 6, dragging: .left)])
    }

    @Test("OR-5 right press while the pen touches is accepted and does not disturb the stroke")
    func or5_rightDuringPenContact() {
        var d = Driver()
        penDown(&d)
        #expect(d.send(relMsg(0, 0, .right)) == [.mouseButton(.right, down: true)])
        #expect(d.send(penMsg(.pen, penSample(4, 4, touchFlags, pressure: 100))) == [
            .penDrag(tool: .pen, penPt(4, 4, 100)),
        ])
        #expect(d.send(relMsg(0, 0, [])) == [.mouseButton(.right, down: false)])
    }

    @Test("OR-6 a touch press of a non-left button inside the finger gate is ignored; its release is inert")
    func or6_touchRightGated() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(absMsg(.touch, 1, 1, .right)).isEmpty)
        #expect(d.send(absMsg(.touch, 1, 1, [])).isEmpty)
        #expect(d.machine.isPenInRange && d.machine.macOtherButtons.isEmpty)
    }

    @Test("OR-7 an accepted touch non-left press is released even inside the gate")
    func or7_touchRightReleaseInsideGate() {
        var d = Driver()
        #expect(d.send(absMsg(.touch, 1, 1, .right)) == [.mouseButton(.right, down: true)])
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(absMsg(.touch, 1, 1, [])) == [.mouseButton(.right, down: false)])
    }

    @Test("OR-8 undefined button bits are ignored")
    func or8_undefinedBits() {
        var d = Driver()
        #expect(d.send(relMsg(0, 0, PointerButtons(rawValue: 0b1110_0000))).isEmpty)
        #expect(!d.machine.hasHeldInput)
    }
}

@Suite("GATE: finger gate (decision 0006)")
struct FingerGateTests {
    @Test("GATE-1 a new touch press is ignored while the pen is in range; mouse and trackpad are not gated")
    func gate1_inRange() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(absMsg(.touch, 500, 600, .left)).isEmpty)
        #expect(d.send(absMsg(.touch, 500, 600, [])).isEmpty)
        #expect(d.send(absMsg(.mouse, 5, 6, .left)) == [moveAbs(5, 6), .mouseButton(.left, down: true)])
    }

    @Test("GATE-2 the gate holds for exactly 1 s after the last pen sample")
    func gate2_holdBoundary() {
        func touchAfterPen(_ us: UInt64) -> [InjectAction] {
            var d = Driver()
            d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
            d.send(penMsg(.pen, penSample(1, 1, [])))   // last pen sample: leaves range
            return d.send(absMsg(.touch, 500, 600, .left), after: us)
        }
        #expect(touchAfterPen(999_999).isEmpty)
        #expect(touchAfterPen(1_000_000) == [moveAbs(500, 600), .mouseButton(.left, down: true)])
    }

    @Test("GATE-3 the owner's release is always processed, even with the pen in range")
    func gate3_ownerReleaseNeverIgnored() {
        var d = Driver()
        d.send(absMsg(.touch, 500, 600, .left))
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(absMsg(.touch, 520, 620, .left)) == [moveAbs(520, 620, dragging: .left)])
        #expect(d.send(absMsg(.touch, 520, 620, [])) == [
            moveAbs(520, 620, dragging: .left), .mouseButton(.left, down: false),
        ])
    }

    @Test("GATE-4 a press ignored by the gate stays ignored after the gate opens, until released and pressed again")
    func gate4_gatedPressStaysDead() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        d.send(absMsg(.touch, 500, 600, .left))
        d.send(penMsg(.pen, penSample(1, 1, [])))
        #expect(d.send(absMsg(.touch, 500, 600, .left), after: 2_000 * msec).isEmpty)
        #expect(d.send(absMsg(.touch, 500, 600, [])).isEmpty)
        #expect(d.send(absMsg(.touch, 500, 600, .left)) == [moveAbs(500, 600), .mouseButton(.left, down: true)])
    }

    @Test("GATE-5 the 1 s hold counts from the last pen sample even after the watchdog closed the pen")
    func gate5_holdAfterWatchdog() {
        func touchAt(afterWatchdog us: UInt64) -> [InjectAction] {
            var d = Driver()
            d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
            d.tick(after: 500 * msec)                      // pen closed by the watchdog
            #expect(!d.machine.isPenInRange)
            return d.send(absMsg(.touch, 500, 600, .left), after: us)
        }
        #expect(touchAt(afterWatchdog: 499_999).isEmpty)  // 999_999 us after the last pen sample
        #expect(touchAt(afterWatchdog: 500_000) == [moveAbs(500, 600), .mouseButton(.left, down: true)])
    }

    @Test("GATE-6 release-all does not open the gate (the palm is still on the glass)")
    func gate6_survivesReleaseAll() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        d.release()
        #expect(d.send(absMsg(.touch, 500, 600, .left), after: 100 * msec).isEmpty)
        #expect(d.machine.isTouchGateActive(at: d.now))
    }

    @Test("GATE-7 isTouchGateActive follows the pen and the hold time; the hold is configurable")
    func gate7_query() {
        var config = InputStateMachine.Configuration()
        config.touchGateHoldUs = 200_000
        var d = Driver(configuration: config)
        #expect(!d.machine.isTouchGateActive(at: d.now))
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.machine.isTouchGateActive(at: d.now + 10 * msec))
        d.send(penMsg(.pen, penSample(1, 1, [])))
        #expect(d.machine.isTouchGateActive(at: d.now + 199_999))
        #expect(!d.machine.isTouchGateActive(at: d.now + 200_000))
    }

    @Test("GATE-8 the gate applies to touch only")
    func gate8_touchOnly() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(relMsg(0, 0, .left)) == [.mouseButton(.left, down: true)])
        #expect(d.send(relMsg(0, 0, [])) == [.mouseButton(.left, down: false)])
    }
}
