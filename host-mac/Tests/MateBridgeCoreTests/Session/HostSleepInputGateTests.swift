import Testing
@testable import MateBridgeCore

/// T-299: what the input controller does with `HostSleepInputGate` while the sleep gate is set, driven through the real
/// pipeline the same way (drop, `postFailed`, release again).
@Suite struct HostSleepInputGateTests {
    private func gated(_ pipe: inout InputPipeline, _ message: Message, now: UInt64) -> (passed: [MacEvent], dropped: Int) {
        let (pass, dropped) = HostSleepInputGate.split(pipe.handle(message, now: now, environment: openEnv))
        guard !dropped.isEmpty else { return (pass, 0) }
        pipe.postFailed(dropped, now: now, permitted: true)
        return (pass + pipe.release(.hostSleep, now: now, environment: openEnv), dropped.count)
    }

    @Test func keyDownAfterTheSleepReleaseNeverOpens() {
        var pipe = InputPipeline()
        _ = pipe.sessionStarted(now: 1_000, environment: openEnv)
        _ = pipe.handle(keyDown(Scan.a), now: 2_000, environment: openEnv)
        #expect(pipe.isHoldingInput)
        let released = pipe.release(.hostSleep, now: 3_000, environment: openEnv)
        #expect(released.contains { $0.isClosing })
        #expect(!pipe.isHoldingInput)
        // An old-session record arrives after the release (the session queue has not ended the session yet).
        let r = gated(&pipe, keyDown(Scan.b), now: 4_000)
        #expect(r.dropped == 1)
        #expect(r.passed.allSatisfy { !HostSleepInputGate.isOpening($0) })
        #expect(!pipe.isHoldingInput && pipe.machine?.hasHeldInput != true)
        _ = gated(&pipe, keyUp(Scan.b), now: 5_000)
        #expect(!pipe.isHoldingInput && pipe.owed.isEmpty)
    }

    @Test func penContactAndButtonsAfterTheSleepReleaseNeverOpen() {
        var pipe = InputPipeline()
        _ = pipe.sessionStarted(now: 1_000, environment: openEnv)
        _ = pipe.release(.hostSleep, now: 2_000, environment: openEnv)
        let pen = gated(&pipe, penMsg(.pen, penSample(1, 1, startFlags, pressure: 500)), now: 3_000)
        #expect(!pipe.isHoldingInput)
        #expect(pen.passed.allSatisfy { !HostSleepInputGate.isOpening($0) })
        let btn = gated(&pipe, relMsg(0, 0, .left), now: 4_000)
        #expect(btn.dropped >= 1 && !pipe.isHoldingInput && pipe.machine?.hasHeldInput != true)
    }

    @Test func closingAndMovingEventsPass() {
        let pos = DisplayPoint(x: 1, y: 1)
        func mouse(_ kind: MacMouse.Kind) -> MacEvent {
            .mouse(MacMouse(kind: kind, button: .left, position: pos, deltaX: 0, deltaY: 0, clickState: 1, flags: []))
        }
        let split = HostSleepInputGate.split([mouse(.moved), mouse(.down), mouse(.up),
                                              .tabletProximity(tool: .pen, entering: false),
                                              .tabletProximity(tool: .pen, entering: true)])
        #expect(split.pass.count == 3)
        #expect(split.dropped.count == 2)
    }
}
