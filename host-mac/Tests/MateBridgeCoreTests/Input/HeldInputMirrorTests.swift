import Testing
@testable import MateBridgeCore

private let p0 = DisplayPoint(x: 10, y: 20)

private func key(_ k: MacKey.Kind, _ code: UInt16) -> MacEvent { .key(MacKey(kind: k, keyCode: code, flags: [])) }
private func mouse(_ k: MacMouse.Kind, _ b: MouseButton = .left) -> MacEvent {
    .mouse(MacMouse(kind: k, button: b, position: p0, deltaX: 0, deltaY: 0, clickState: 1))
}
private func pen(_ k: MacTabletPoint.Kind, tool: PenTool = .pen) -> MacEvent {
    .tabletPoint(MacTabletPoint(kind: k, tool: tool, position: p0, pressure: 0.5, tiltX: 0, tiltY: 0, clickState: 1))
}

@Suite struct HeldInputMirrorTests {
    @Test func emptyMirrorHasNothingToRelease() {
        let m = HeldInputMirror()
        #expect(m.isEmpty)
        #expect(m.emergencyRelease().isEmpty)
    }

    @Test func keysAndModifiersAreTrackedAndReleased() {
        var m = HeldInputMirror()
        m.posted(key(.modifierDown, 55))
        m.posted(key(.keyDown, 8))
        m.posted(key(.keyDown, 9))
        m.posted(key(.keyUp, 9))
        #expect(m.keys == [8] && m.modifiers == [55])
        // Key-ups first, then the modifiers with cleared flags.
        #expect(m.emergencyRelease() == [key(.keyUp, 8), key(.modifierUp, 55)])
    }

    @Test func releasedStateIsEmptyAgain() {
        var m = HeldInputMirror()
        m.posted(key(.keyDown, 8)); m.posted(key(.keyUp, 8))
        m.posted(mouse(.down)); m.posted(mouse(.up))
        m.posted(pen(.down)); m.posted(pen(.up))
        m.posted(.tabletProximity(tool: .pen, entering: true)); m.posted(.tabletProximity(tool: .pen, entering: false))
        #expect(m.isEmpty)
    }

    @Test func mouseButtonsGetUps() {
        var m = HeldInputMirror()
        m.posted(mouse(.down, .left)); m.posted(mouse(.down, .right)); m.posted(mouse(.dragged, .left))
        let plan = m.emergencyRelease()
        #expect(plan == [mouse(.up, .left), mouse(.up, .right)])
    }

    @Test func penInContactGetsUpWithZeroPressureThenLeave() {
        var m = HeldInputMirror()
        m.posted(.tabletProximity(tool: .eraser, entering: true))
        m.posted(pen(.down, tool: .eraser))
        let plan = m.emergencyRelease()
        #expect(plan.count == 2)
        guard case .tabletPoint(let up) = plan[0] else { Issue.record("first is not a pen up"); return }
        #expect(up.kind == .up && up.pressure == 0 && up.tool == .eraser && up.position == p0)
        #expect(plan[1] == .tabletProximity(tool: .eraser, entering: false))
    }

    @Test func penInProximityOnlyGetsLeaveOnly() {
        var m = HeldInputMirror()
        m.posted(.tabletProximity(tool: .pen, entering: true))
        m.posted(pen(.hover))
        #expect(m.emergencyRelease() == [.tabletProximity(tool: .pen, entering: false)])
    }

    @Test func leavingProximityEndsContact() {
        var m = HeldInputMirror()
        m.posted(pen(.down))
        m.posted(.tabletProximity(tool: .pen, entering: false))
        #expect(m.penContact == nil && m.isEmpty)
    }

    @Test func openGesturesGetEnds() {
        var m = HeldInputMirror()
        m.posted(.scroll(MacScroll(phase: .began, dx: 0, dy: 1, position: p0)))
        m.posted(.magnify(MacMagnify(phase: .began, value: 0, position: p0)))
        let plan = m.emergencyRelease()
        #expect(plan.count == 2)
        #expect(plan.contains(.scroll(MacScroll(phase: .ended, dx: 0, dy: 0, position: p0))))
        #expect(plan.contains(.magnify(MacMagnify(phase: .ended, value: 0, position: p0))))
    }

    @Test func batchRecordsOnlyTheAcceptedPrefix() {
        var m = HeldInputMirror()
        let batch = [key(.keyDown, 1), key(.keyDown, 2), key(.keyDown, 3)]
        m.postedBatch(batch, failedCount: 2)  // the poster returned the failed suffix
        #expect(m.keys == [1])
    }

    @Test func closeInTheSameBatchWins() {
        var m = HeldInputMirror()
        m.postedBatch([key(.keyDown, 1), key(.keyUp, 1)], failedCount: 0)
        #expect(m.isEmpty)
    }

    @Test func repeatedDownsDoNotDuplicate() {
        var m = HeldInputMirror()
        m.posted(key(.keyDown, 8)); m.posted(key(.keyDown, 8))
        #expect(m.emergencyRelease() == [key(.keyUp, 8)])
    }

    @Test func releaseOrderIsPenThenMouseThenKeysThenModifiers() {
        var m = HeldInputMirror()
        m.posted(key(.modifierDown, 56)); m.posted(key(.keyDown, 8)); m.posted(mouse(.down)); m.posted(pen(.down))
        m.posted(.tabletProximity(tool: .pen, entering: true))
        let kinds = m.emergencyRelease().map { e -> String in
            switch e {
            case .tabletPoint: "penUp"
            case .tabletProximity: "leave"
            case .mouse: "mouseUp"
            case .key(let k): k.kind == .modifierUp ? "modUp" : "keyUp"
            default: "other"
            }
        }
        #expect(kinds == ["penUp", "leave", "mouseUp", "keyUp", "modUp"])
    }
}
