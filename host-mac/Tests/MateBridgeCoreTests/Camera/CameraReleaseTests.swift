import Testing
@testable import MateBridgeCore

// "Kamerayı şimdi kapat" (CAMERA_PREFS.release_seq, decision 0040 addendum 2) and the idle audit.

private let sec: UInt64 = 1_000_000

private func prefs(_ mode: CameraMode = .auto, seq: UInt16) -> CameraPrefs {
    CameraPrefs(mode: mode, facing: .front, releaseSeq: seq)
}

private func sends(_ actions: [CameraController.Action]) -> [CameraControl] {
    actions.compactMap { if case .send(let c) = $0 { c } else { nil } }
}

private func opensListener(_ actions: [CameraController.Action]) -> Bool {
    actions.contains { if case .openListener = $0 { true } else { false } }
}

/// AUTO session, release_seq baseline `seq`, device present, usage on, START sent.
private func startedController(seq: UInt16 = 0) -> CameraController {
    var c = CameraController()
    _ = c.sessionStarted(clientHasCamera: true, now: 0)
    _ = c.prefs(prefs(seq: seq), now: 0)
    _ = c.deviceAvailable(true, now: 0)
    _ = c.usage(true, now: 0)
    _ = c.listenerOpened(port: 47004, now: 0)
    return c
}

@Suite struct CameraReleaseTests {
    @Test func changeWhileStartedStopsAndReleases() {
        var c = startedController()
        let out = c.prefs(prefs(seq: 1), now: sec)
        #expect(sends(out) == [.stop(camID: 1)])
        #expect(out.contains(.closeListener))
        #expect(c.isReleased && !c.isStarted)
        // No START while released, even though the usage stays 1 and the device is there.
        let v1 = c.tick(now: 100 * sec)
        #expect(v1.isEmpty)
        #expect(!c.isStarted)
    }

    @Test func releasedStaysStoppedWhileUsageStaysOn() {
        var c = startedController()
        _ = c.prefs(prefs(seq: 1), now: sec)
        let v2 = c.deviceAvailable(true, now: 2 * sec)
        #expect(v2.isEmpty)
        let v3 = c.prefs(prefs(seq: 1), now: 3 * sec)
        #expect(!opensListener(v3))
        #expect(c.isReleased)
    }

    @Test func usageDroppingAndReturningClearsTheReleaseAndStartsAgain() {
        var c = startedController()
        _ = c.prefs(prefs(seq: 1), now: sec)
        _ = c.usage(false, now: 2 * sec)
        _ = c.tick(now: 10 * sec)
        #expect(c.isReleased)  // still released while usage is 0
        let v4 = c.usage(true, now: 11 * sec)
        #expect(opensListener(v4))
        #expect(!c.isReleased)
    }

    @Test func offClearsTheRelease() {
        var c = startedController()
        _ = c.prefs(prefs(seq: 1), now: sec)
        _ = c.prefs(prefs(.off, seq: 1), now: 2 * sec)
        #expect(!c.isReleased)
        _ = c.prefs(prefs(seq: 1), now: 3 * sec)
        _ = c.deviceAvailable(true, now: 3 * sec)
        let v5 = c.usage(true, now: 3 * sec)
        #expect(opensListener(v5))
    }

    @Test func firstValueIsABaselineNotAChange() {
        var c = CameraController()
        _ = c.sessionStarted(clientHasCamera: true, now: 0)
        _ = c.prefs(prefs(seq: 7), now: 0)
        _ = c.deviceAvailable(true, now: 0)
        _ = c.usage(true, now: 0)
        _ = c.listenerOpened(port: 47004, now: 0)
        #expect(c.isStarted && !c.isReleased)
        // The same value again changes nothing.
        let v6 = c.prefs(prefs(seq: 7), now: sec)
        #expect(v6.isEmpty)
        #expect(c.isStarted)
    }

    @Test func changeWithoutStartDoesNotRelease() {
        var c = CameraController()
        _ = c.sessionStarted(clientHasCamera: true, now: 0)
        _ = c.prefs(prefs(seq: 0), now: 0)
        _ = c.deviceAvailable(true, now: 0)  // no usage yet
        _ = c.prefs(prefs(seq: 1), now: sec)
        #expect(!c.isReleased)
        let v7 = c.usage(true, now: 2 * sec)
        #expect(opensListener(v7))
    }

    @Test func aNewSessionForgetsTheBaseline() {
        var c = startedController(seq: 5)
        _ = c.sessionEnded()
        _ = c.sessionStarted(clientHasCamera: true, now: 0)
        _ = c.prefs(prefs(seq: 0), now: 0)  // client counter restarted: baseline, not a change
        _ = c.deviceAvailable(true, now: 0)
        let v8 = c.usage(true, now: 0)
        #expect(opensListener(v8))
        #expect(!c.isReleased)
    }

    @Test func wrapAroundCountsAsAChange() {
        var c = startedController(seq: 65535)
        let out = c.prefs(prefs(seq: 0), now: sec)
        #expect(sends(out) == [.stop(camID: 1)] && c.isReleased)
    }
}

@Suite struct CameraIdleAuditTests {
    private let idle = 600 * sec

    @Test func dueOnlyWhenIdleLongEnoughAndOncePerPeriod() {
        var a = CameraIdleAudit(idleUs: idle)
        let r1 = a.due(now: 100 * sec, canProbe: true, inputIdleUs: 599 * sec)
        #expect(!r1)
        let r2 = a.due(now: 700 * sec, canProbe: true, inputIdleUs: 600 * sec)
        #expect(r2)
        let v9 = a.due(now: 1000 * sec, canProbe: true, inputIdleUs: 900 * sec)
        #expect(!v9)  // too soon after the last one
        let v10 = a.due(now: 1300 * sec, canProbe: true, inputIdleUs: 1200 * sec)
        #expect(v10)  // next period
    }

    @Test func notDueWhenAProbeCannotStart() {
        var a = CameraIdleAudit(idleUs: idle)
        let r3 = a.due(now: 700 * sec, canProbe: false, inputIdleUs: 700 * sec)
        #expect(!r3)
        #expect(a.nextDeadline(now: 0, canProbe: false, inputIdleUs: 0) == nil)
    }

    @Test func deadlineIsWhenTheInputAgeReachesTheThreshold() {
        var a = CameraIdleAudit(idleUs: idle)
        #expect(a.nextDeadline(now: 1000 * sec, canProbe: true, inputIdleUs: 100 * sec) == 1500 * sec)
        #expect(a.nextDeadline(now: 1000 * sec, canProbe: true, inputIdleUs: 700 * sec) == 1000 * sec)
        _ = a.due(now: 1000 * sec, canProbe: true, inputIdleUs: 700 * sec)
        // Idle goes on: the next check is one full period after the last one.
        #expect(a.nextDeadline(now: 1001 * sec, canProbe: true, inputIdleUs: 701 * sec) == 1600 * sec)
        a.reset()
        #expect(a.nextDeadline(now: 1001 * sec, canProbe: true, inputIdleUs: 701 * sec) == 1001 * sec)
    }

    @Test func sleepProbesAtOnceRegardlessOfInput() {
        var a = CameraIdleAudit(idleUs: idle)
        let r4 = a.sleeping(now: 5 * sec, canProbe: true)
        #expect(r4)
        let r5 = a.sleeping(now: 6 * sec, canProbe: false)
        #expect(!r5)
        // A sleep probe counts as the last audit.
        let r6 = a.due(now: 100 * sec, canProbe: true, inputIdleUs: 700 * sec)
        #expect(!r6)
    }
}
