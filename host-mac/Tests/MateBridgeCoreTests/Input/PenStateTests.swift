import Foundation
import Testing
@testable import MateBridgeCore

// PROTOCOL.md section 4 PEN table (PEN-*), latch rule (LATCH-*) and decision 0006 eraser mode (ERASER-*).

@Suite("PEN: section 4 host state machine table")
struct PenTableTests {
    @Test("PEN-1 IN_RANGE 0->1 enters proximity with the tool type, then reports the position")
    func pen1_enterOnRange() {
        var d = Driver()
        #expect(d.send(penMsg(.pen, penSample(1000, 2000, hoverFlags))) == [
            penEnter(.pen), .penHover(tool: .pen, penPt(1000, 2000)),
        ])
        var e = Driver()
        #expect(e.send(penMsg(.eraser, penSample(1000, 2000, hoverFlags))) == [
            penEnter(.eraser), .penHover(tool: .eraser, penPt(1000, 2000)),
        ])
        #expect(d.machine.isPenInRange && !d.machine.isPenInContact)
    }

    @Test("PEN-2 CONTACT 0->1 while hovering is a mouse down with pressure and tilt")
    func pen2_contactStartsDown() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1000, 2000, hoverFlags)))
        let out = d.send(penMsg(.pen, penSample(1010, 2010, startFlags, pressure: 300)))
        #expect(out == [.penDown(tool: .pen, penPt(1010, 2010, 300))])
        #expect(d.machine.isPenInContact)
    }

    @Test("PEN-3 enter and contact in the same sample: enter first, then down")
    func pen3_enterAndDownInOneSample() {
        var d = Driver()
        let out = d.send(penMsg(.pen, penSample(7, 8, startFlags, pressure: 65535)))
        #expect(out == [penEnter(.pen), .penDown(tool: .pen, penPt(7, 8, 65535))])
    }

    @Test("PEN-4 CONTACT 1->1 is a drag")
    func pen4_dragWhileTouching() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, startFlags, pressure: 100)))
        #expect(d.send(penMsg(.pen, penSample(2, 3, touchFlags, pressure: 200))) == [
            .penDrag(tool: .pen, penPt(2, 3, 200)),
        ])
    }

    @Test("PEN-5 CONTACT 1->0 while still in range is an up at the lift position, pressure 0; hover follows")
    func pen5_liftStaysInRange() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, startFlags, pressure: 100)))
        #expect(d.send(penMsg(.pen, penSample(5, 6, hoverFlags, pressure: 999))) == [
            .penUp(tool: .pen, penPt(5, 6, 0)),
        ])
        #expect(!d.machine.isPenInContact && d.machine.isPenInRange)
        #expect(d.send(penMsg(.pen, penSample(7, 8, hoverFlags))) == [.penHover(tool: .pen, penPt(7, 8))])
    }

    @Test("PEN-6 IN_RANGE 1->1 without contact is a hover move; pressure is forced to 0")
    func pen6_hoverMoves() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(penMsg(.pen, penSample(2, 2, hoverFlags, pressure: 4000))) == [
            .penHover(tool: .pen, penPt(2, 2, 0)),
        ])
    }

    @Test("PEN-7a IN_RANGE 1->0 without contact is a leave")
    func pen7a_leaveWithoutContact() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(penMsg(.pen, penSample(1, 1, []))) == [penLeave(.pen)])
        #expect(!d.machine.isPenInRange)
    }

    @Test("PEN-7b IN_RANGE 1->0 while touching: up first, then leave")
    func pen7b_leaveWhileTouchingUpsFirst() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, startFlags, pressure: 500)))
        #expect(d.send(penMsg(.pen, penSample(9, 9, []))) == [.penUp(tool: .pen, penPt(9, 9, 0)), penLeave(.pen)])
        #expect(!d.machine.hasHeldInput)
    }

    @Test("PEN-7c a leave while already out of range produces nothing")
    func pen7c_leaveWhenAlreadyOut() {
        var d = Driver()
        #expect(d.send(penMsg(.pen, penSample(1, 1, []))).isEmpty)
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        d.send(penMsg(.pen, penSample(1, 1, [])))
        #expect(d.send(penMsg(.pen, penSample(1, 1, []))).isEmpty)
    }

    @Test("PEN-8a tool change while hovering: leave old, enter new")
    func pen8a_toolChangeHover() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(penMsg(.eraser, penSample(2, 2, hoverFlags))) == [
            penLeave(.pen), penEnter(.eraser), .penHover(tool: .eraser, penPt(2, 2)),
        ])
    }

    @Test("PEN-8b tool change with a new stroke of the new tool: up, leave, enter, down")
    func pen8b_toolChangeWhileTouchingWithStrokeStart() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, startFlags, pressure: 100)))
        #expect(d.send(penMsg(.eraser, penSample(3, 4, startFlags, pressure: 200))) == [
            .penUp(tool: .pen, penPt(1, 1, 0)), penLeave(.pen), penEnter(.eraser),
            .penDown(tool: .eraser, penPt(3, 4, 200)),
        ])
    }

    @Test("PEN-8c a tool change in the middle of a stroke never continues it as a new stroke (starts latched)")
    func pen8c_toolChangeMidStrokeIsHover() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, startFlags, pressure: 100)))
        #expect(d.send(penMsg(.eraser, penSample(3, 4, touchFlags, pressure: 200))) == [
            .penUp(tool: .pen, penPt(1, 1, 0)), penLeave(.pen), penEnter(.eraser),
            .penHover(tool: .eraser, penPt(3, 4)),
        ])
        #expect(d.send(penMsg(.eraser, penSample(5, 6, touchFlags, pressure: 200))) == [
            .penHover(tool: .eraser, penPt(5, 6)),
        ])
        // The next real stroke starts normally.
        d.send(penMsg(.eraser, penSample(5, 6, hoverFlags)))
        #expect(d.send(penMsg(.eraser, penSample(5, 6, startFlags, pressure: 50))) == [
            .penDown(tool: .eraser, penPt(5, 6, 50)),
        ])
    }

    @Test("PEN-9a CONTACT=1 IN_RANGE=0 counts as flags = 0: nothing from a fresh machine")
    func pen9a_contactWithoutRangeFresh() {
        var d = Driver()
        #expect(d.send(penMsg(.pen, penSample(1, 1, .contact, pressure: 500))).isEmpty)
        #expect(d.send(penMsg(.pen, penSample(1, 1, [.contact, .strokeStart], pressure: 500))).isEmpty)
        #expect(!d.machine.hasHeldInput)
    }

    @Test("PEN-9b CONTACT=1 IN_RANGE=0 while hovering is a leave")
    func pen9b_contactWithoutRangeWhileHovering() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(penMsg(.pen, penSample(2, 2, .contact, pressure: 500))) == [penLeave(.pen)])
    }

    @Test("PEN-9c CONTACT=1 IN_RANGE=0 while touching is up then leave")
    func pen9c_contactWithoutRangeWhileTouching() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, startFlags, pressure: 100)))
        #expect(d.send(penMsg(.pen, penSample(2, 2, .contact, pressure: 500))) == [
            .penUp(tool: .pen, penPt(2, 2, 0)), penLeave(.pen),
        ])
    }

    @Test("PEN-10 a STROKE_START while already touching is a new stroke: up, then down")
    func pen10_strokeStartWhileTouching() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, startFlags, pressure: 100)))
        #expect(d.send(penMsg(.pen, penSample(2, 2, startFlags, pressure: 300))) == [
            .penUp(tool: .pen, penPt(1, 1, 0)), .penDown(tool: .pen, penPt(2, 2, 300)),
        ])
        #expect(d.machine.isPenInContact)
    }

    @Test("PEN-11 the BUTTON flag is not mapped (decision 0006)")
    func pen11_buttonFlagIgnored() {
        var d = Driver()
        let flags: PenFlags = [.inRange, .contact, .strokeStart, .button]
        #expect(d.send(penMsg(.pen, penSample(1, 1, flags, pressure: 100))) == [
            penEnter(.pen), .penDown(tool: .pen, penPt(1, 1, 100)),
        ])
    }

    @Test("PEN-12 a batch is processed in order, one action list")
    func pen12_batchOrder() {
        var d = Driver()
        let out = d.send(penMsg(.pen,
                                penSample(1, 1, hoverFlags),
                                penSample(2, 2, startFlags, pressure: 10),
                                penSample(3, 3, touchFlags, pressure: 20),
                                penSample(4, 4, hoverFlags)))
        #expect(out == [
            penEnter(.pen), .penHover(tool: .pen, penPt(1, 1)),
            .penDown(tool: .pen, penPt(2, 2, 10)),
            .penDrag(tool: .pen, penPt(3, 3, 20)),
            .penUp(tool: .pen, penPt(4, 4, 0)),
        ])
    }

    @Test("PEN-13 fixtures: hover_to_contact, pen_leave and pen_eraser drive the documented actions")
    func pen13_fixtures() throws {
        func decode(_ name: String) throws -> Message {
            var decoder = FrameDecoder(connection: .control)
            decoder.append(Fixtures.bytes(name))
            return try #require(try decoder.nextMessage())
        }
        var d = Driver()
        let out = d.send(try decode("pen_hover_to_contact"))
        #expect(out.count == 5)
        #expect(out[0] == penEnter(.pen))
        guard case .penHover(.pen, let hover) = out[1] else { Issue.record("expected hover"); return }
        #expect(hover.x == 22364 && hover.y == 12738 && hover.pressure == 0)
        guard case .penDown(.pen, let down) = out[2] else { Issue.record("expected down"); return }
        #expect(down.pressure == 288 && down.tiltX == 3000)
        guard case .penDrag(.pen, let drag) = out[3] else { Issue.record("expected drag"); return }
        #expect(drag.pressure == 32768)
        guard case .penUp(.pen, let up) = out[4] else { Issue.record("expected up"); return }
        #expect(up.pressure == 0 && up.x == 22430)

        #expect(d.send(try decode("pen_leave")) == [penLeave(.pen)])

        var e = Driver()
        let eraser = e.send(try decode("pen_eraser"))
        #expect(eraser.count == 2)
        #expect(eraser[0] == penEnter(.eraser))
        guard case .penDown(.eraser, let erase) = eraser[1] else { Issue.record("expected eraser down"); return }
        #expect(erase.pressure == 65535)
    }
}

@Suite("LATCH: section 4 latch rule")
struct LatchTests {
    /// A pen mid-stroke on `tool`, then a release-all.
    private func midStrokeThenRelease(_ cause: ReleaseCause = .clientRequest(.background)) -> Driver {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, startFlags, pressure: 100)))
        d.send(penMsg(.pen, penSample(2, 2, touchFlags, pressure: 200)))
        d.release(cause)
        return d
    }

    @Test("LATCH-1 after release-all, CONTACT samples without STROKE_START are hover only")
    func latch1_staleMidStrokeIsHover() {
        var d = midStrokeThenRelease()
        #expect(d.send(penMsg(.pen, penSample(3, 3, touchFlags, pressure: 250))) == [
            penEnter(.pen), .penHover(tool: .pen, penPt(3, 3, 0)),
        ])
        #expect(d.send(penMsg(.pen, penSample(4, 4, touchFlags, pressure: 250))) == [
            .penHover(tool: .pen, penPt(4, 4, 0)),
        ])
        #expect(d.machine.isPenInRange && !d.machine.isPenInContact)
    }

    @Test("LATCH-2 the latch lifts on a sample without CONTACT")
    func latch2_liftsOnNoContact() {
        var d = midStrokeThenRelease()
        d.send(penMsg(.pen, penSample(3, 3, touchFlags, pressure: 250)))
        #expect(d.send(penMsg(.pen, penSample(4, 4, hoverFlags))) == [.penHover(tool: .pen, penPt(4, 4))])
        // Per the table, an unlatched CONTACT 0->1 is a down even without STROKE_START.
        #expect(d.send(penMsg(.pen, penSample(5, 5, touchFlags, pressure: 60))) == [
            .penDown(tool: .pen, penPt(5, 5, 60)),
        ])
    }

    @Test("LATCH-3 the latch lifts on STROKE_START, and that sample starts the stroke")
    func latch3_liftsOnStrokeStart() {
        var d = midStrokeThenRelease()
        d.send(penMsg(.pen, penSample(3, 3, touchFlags, pressure: 250)))
        #expect(d.send(penMsg(.pen, penSample(4, 4, startFlags, pressure: 70))) == [
            .penDown(tool: .pen, penPt(4, 4, 70)),
        ])
        #expect(d.send(penMsg(.pen, penSample(5, 5, touchFlags, pressure: 80))) == [
            .penDrag(tool: .pen, penPt(5, 5, 80)),
        ])
    }

    @Test("LATCH-4 the latch is per tool")
    func latch4_perTool() {
        var d = midStrokeThenRelease()
        // A fresh eraser stroke is not blocked by the pen's latch.
        #expect(d.send(penMsg(.eraser, penSample(1, 1, startFlags, pressure: 90))) == [
            penEnter(.eraser), .penDown(tool: .eraser, penPt(1, 1, 90)),
        ])
        d.send(penMsg(.eraser, penSample(1, 1, [])))
        // The pen is still latched.
        #expect(d.send(penMsg(.pen, penSample(2, 2, touchFlags, pressure: 90))) == [
            penEnter(.pen), .penHover(tool: .pen, penPt(2, 2)),
        ])
    }

    @Test("LATCH-5 every release-all cause arms the latch, even on an idle machine", arguments: allReleaseCauses)
    func latch5_everyCauseArmsLatch(cause: ReleaseCause) {
        var d = Driver()
        #expect(d.release(cause).isEmpty)
        #expect(d.send(penMsg(.pen, penSample(1, 1, touchFlags, pressure: 300))) == [
            penEnter(.pen), .penHover(tool: .pen, penPt(1, 1)),
        ])
        var e = midStrokeThenRelease(cause)
        #expect(!e.machine.hasHeldInput)
        #expect(e.send(penMsg(.pen, penSample(2, 2, touchFlags, pressure: 300))) == [
            penEnter(.pen), .penHover(tool: .pen, penPt(2, 2)),
        ])
    }

    @Test("LATCH-6 CONTACT=1 IN_RANGE=0 is a sample without contact and lifts the latch")
    func latch6_contactWithoutRangeLifts() {
        var d = midStrokeThenRelease()
        d.send(penMsg(.pen, penSample(3, 3, .contact, pressure: 250)))  // flags = 0 after normalisation
        d.send(penMsg(.pen, penSample(4, 4, hoverFlags)))
        #expect(d.send(penMsg(.pen, penSample(5, 5, touchFlags, pressure: 60))) == [
            .penDown(tool: .pen, penPt(5, 5, 60)),
        ])
    }

    @Test("LATCH-7 a stale contact sample in the same batch as a legitimate new stroke does not start early")
    func latch7_batchWithStaleThenNewStroke() {
        var d = midStrokeThenRelease()
        let out = d.send(penMsg(.pen,
                                penSample(3, 3, touchFlags, pressure: 250),
                                penSample(4, 4, startFlags, pressure: 70),
                                penSample(5, 5, touchFlags, pressure: 80)))
        #expect(out == [
            penEnter(.pen), .penHover(tool: .pen, penPt(3, 3)),
            .penDown(tool: .pen, penPt(4, 4, 70)),
            .penDrag(tool: .pen, penPt(5, 5, 80)),
        ])
    }

    @Test("LATCH-8 a watchdog close does not arm the latch (only release-all does)")
    func latch8_watchdogDoesNotLatch() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, startFlags, pressure: 100)))
        d.tick(after: 500 * msec)
        // Section 4 table: previous flags are 0 after the watchdog, so CONTACT 0->1 is a down.
        #expect(d.send(penMsg(.pen, penSample(2, 2, touchFlags, pressure: 100))) == [
            penEnter(.pen), .penDown(tool: .pen, penPt(2, 2, 100)),
        ])
    }
}

@Suite("ERASER: decision 0006 double tap")
struct EraserModeTests {
    @Test("ERASER-1 DOUBLE_TAP toggles eraser mode; other gestures are ignored")
    func eraser1_toggle() {
        var d = Driver()
        #expect(!d.machine.isEraserMode)
        #expect(d.send(doubleTap).isEmpty)
        #expect(d.machine.isEraserMode)
        #expect(d.send(.penGesture(PenGesture(timeUs: 0, gesture: PenGestureKind(rawValue: 42)))).isEmpty)
        #expect(d.machine.isEraserMode)
        d.send(doubleTap)
        #expect(!d.machine.isEraserMode)
    }

    @Test("ERASER-2 in eraser mode the pen enters as the eraser tip")
    func eraser2_penBecomesEraser() {
        var d = Driver()
        d.send(doubleTap)
        #expect(d.send(penMsg(.pen, penSample(1, 1, startFlags, pressure: 100))) == [
            penEnter(.eraser), .penDown(tool: .eraser, penPt(1, 1, 100)),
        ])
    }

    @Test("ERASER-3 toggling while hovering switches tool at the next sample: leave, enter as eraser")
    func eraser3_toggleWhileHovering() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(d.send(doubleTap).isEmpty)
        #expect(d.send(penMsg(.pen, penSample(2, 2, hoverFlags))) == [
            penLeave(.pen), penEnter(.eraser), .penHover(tool: .eraser, penPt(2, 2)),
        ])
        // And back.
        d.send(doubleTap)
        #expect(d.send(penMsg(.pen, penSample(3, 3, hoverFlags))) == [
            penLeave(.eraser), penEnter(.pen), .penHover(tool: .pen, penPt(3, 3)),
        ])
    }

    @Test("ERASER-4 toggling mid-stroke ends the stroke (up, leave, enter) and continues as hover")
    func eraser4_toggleMidStroke() {
        var d = Driver()
        d.send(penMsg(.pen, penSample(1, 1, startFlags, pressure: 100)))
        d.send(doubleTap)
        #expect(d.send(penMsg(.pen, penSample(2, 2, touchFlags, pressure: 150))) == [
            .penUp(tool: .pen, penPt(1, 1, 0)), penLeave(.pen), penEnter(.eraser),
            .penHover(tool: .eraser, penPt(2, 2)),
        ])
        #expect(!d.machine.isPenInContact)
    }

    @Test("ERASER-5 the tablet's real eraser tip is the eraser in both modes")
    func eraser5_realEraserAlwaysEraser() {
        var d = Driver()
        #expect(d.send(penMsg(.eraser, penSample(1, 1, hoverFlags))).first == penEnter(.eraser))
        d.send(penMsg(.eraser, penSample(1, 1, [])))
        d.send(doubleTap)
        #expect(d.send(penMsg(.eraser, penSample(1, 1, hoverFlags))).first == penEnter(.eraser))
        d.send(penMsg(.eraser, penSample(1, 1, [])))
        d.send(doubleTap)
        #expect(d.send(penMsg(.eraser, penSample(1, 1, hoverFlags))).first == penEnter(.eraser))
    }

    @Test("ERASER-6 release-all returns to pen mode", arguments: allReleaseCauses)
    func eraser6_releaseAllResets(cause: ReleaseCause) {
        var d = Driver()
        d.send(doubleTap)
        d.send(penMsg(.pen, penSample(1, 1, hoverFlags)))
        let out = d.release(cause)
        #expect(out == [penLeave(.eraser)])
        #expect(!d.machine.isEraserMode)
        #expect(d.send(penMsg(.pen, penSample(1, 1, hoverFlags))).first == penEnter(.pen))
    }

    @Test("ERASER-7 the mode toggles without any pen activity and survives until release-all")
    func eraser7_modeWithoutPen() {
        var d = Driver()
        d.send(doubleTap)
        d.tick(after: 5_000 * msec)
        #expect(d.machine.isEraserMode)
        d.release(.bye)
        #expect(!d.machine.isEraserMode)
    }
}
