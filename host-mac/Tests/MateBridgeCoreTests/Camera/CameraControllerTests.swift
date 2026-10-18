import Testing
@testable import MateBridgeCore

// Condition table of the tablet camera (decision 0040, PROTOCOL.md 0x0E/0x0F).

private let sec: UInt64 = 1_000_000
private let auto = CameraPrefs(mode: .auto, facing: .front)
private let off = CameraPrefs(mode: .off, facing: .front)

private func sends(_ actions: [CameraController.Action]) -> [CameraControl] {
    actions.compactMap { if case .send(let c) = $0 { c } else { nil } }
}

private func has(_ actions: [CameraController.Action], _ wanted: CameraController.Action) -> Bool { actions.contains(wanted) }

/// A controller in an AUTO session whose environment watcher reported `device` and `usage`. The listener, when asked
/// for, opened on port 47004.
private struct Rig {
    var c = CameraController()
    var now: UInt64 = 0
    var log: [CameraController.Action] = []

    @discardableResult
    mutating func take(_ out: [CameraController.Action]) -> [CameraController.Action] {
        log += out
        return out
    }

    mutating func session(camera: Bool = true) { take(c.sessionStarted(clientHasCamera: camera, now: now)) }
    mutating func prefs(_ p: CameraPrefs) -> [CameraController.Action] { take(c.prefs(p, now: now)) }
    mutating func device(_ available: Bool) -> [CameraController.Action] { take(c.deviceAvailable(available, now: now)) }
    mutating func usage(_ inUse: Bool) -> [CameraController.Action] { take(c.usage(inUse, now: now)) }
    mutating func opened(port: UInt16 = 47004) -> [CameraController.Action] { take(c.listenerOpened(port: port, now: now)) }
    mutating func advance(_ us: UInt64) -> [CameraController.Action] {
        now += us
        return take(c.tick(now: now))
    }

    /// AUTO, device present, an app using it, listener up: START sent.
    mutating func started() {
        session()
        _ = prefs(auto)
        _ = device(true)
        _ = usage(true)
        _ = opened()
    }
}

@Suite struct CameraControllerTests {
    // MARK: OFF runs nothing

    @Test func offAndNoCapabilityStartNothingAndAskForNoWatching() {
        var r = Rig()
        r.session()
        #expect(r.c.nextDeadline == nil && !r.c.isWatching)
        #expect(r.log.isEmpty)
        // OFF -> events from a stale watcher change nothing
        #expect(r.device(true).isEmpty)
        #expect(r.usage(true).isEmpty)
        #expect(r.log.isEmpty && !r.c.isWatching)

        var noBit = Rig()
        noBit.session(camera: false)
        #expect(noBit.prefs(auto).isEmpty)  // "bit15 missing: do nothing"
        #expect(!noBit.c.isEnabled && !noBit.c.isWatching)
        #expect(noBit.log.isEmpty)
    }

    @Test func autoStartsTheWatcherAndOffRemovesItAgain() {
        var r = Rig()
        r.session()
        #expect(has(r.prefs(auto), .watchEnvironment(true)))
        #expect(r.c.isWatching)
        let out = r.prefs(off)
        #expect(has(out, .watchEnvironment(false)))
        #expect(!r.c.isWatching && r.c.nextDeadline == nil)
        #expect(sends(out).isEmpty)  // nothing was started, so no STOP
    }

    @Test func aRemoteLinkCountsAsOffEvenInAuto() {
        var r = Rig()
        r.session()
        _ = r.prefs(auto)
        _ = r.device(true)
        _ = r.usage(true)
        _ = r.opened()
        let out = r.take(r.c.link(remote: true, now: r.now))
        #expect(sends(out) == [.stop(camID: 1)])
        #expect(has(out, .closeListener) && has(out, .watchEnvironment(false)))
        // Link back to local: AUTO is still the stored mode, the watcher comes back and START follows.
        let back = r.take(r.c.link(remote: false, now: r.now))
        #expect(has(back, .watchEnvironment(true)))
        _ = r.device(true)
        #expect(has(r.usage(true), .openListener(camID: 2)))
    }

    // MARK: Start conditions

    @Test func startNeedsAutoLocalDeviceAndUsageAllAtOnce() {
        var r = Rig()
        r.session()
        _ = r.prefs(auto)
        #expect(r.usage(true).isEmpty)  // device not reported yet: nothing
        #expect(has(r.device(true), .openListener(camID: 1)))
        let started = r.opened(port: 47004)
        #expect(sends(started) == [.start(camID: 1, port: 47004)])
        #expect(r.c.isStarted)
        // START is 1080p30 6000 kbps
        let start = sends(started)[0]
        #expect(start.width == 1920 && start.height == 1080 && start.fps == 30 && start.bitrateKbps == 6000)
    }

    @Test func noUsageNoStart() {
        var r = Rig()
        r.session()
        _ = r.prefs(auto)
        _ = r.device(true)
        #expect(!r.c.isStarted)
        #expect(!r.log.contains { if case .openListener = $0 { true } else { false } })
    }

    @Test func theListenerIsOpenedBeforeStartIsSentAndAFailureSendsNothing() {
        var r = Rig()
        r.session()
        _ = r.prefs(auto)
        _ = r.device(true)
        let open = r.usage(true)
        #expect(has(open, .openListener(camID: 1)) && sends(open).isEmpty)
        let failed = r.take(r.c.listenerFailed(now: r.now))
        #expect(sends(failed).isEmpty && !r.c.isStarted)
        // No retry storm while the same usage persists; after the usage ended and returned it tries again.
        #expect(r.usage(true).isEmpty)
        _ = r.usage(false)
        _ = r.advance(3 * sec)
        #expect(has(r.usage(true), .openListener(camID: 2)))
    }

    // MARK: Stop conditions

    @Test func usageEndsOnlyAfterTheThreeSecondFilter() {
        var r = Rig()
        r.started()
        #expect(r.usage(false).isEmpty)  // not at once
        #expect(r.c.nextDeadline == r.now + 3 * sec)
        #expect(r.advance(2 * sec).isEmpty)
        // Usage returns inside the filter: no STOP, no restart.
        #expect(r.usage(true).isEmpty)
        #expect(r.c.nextDeadline == nil)
        _ = r.usage(false)
        #expect(r.advance(2 * sec).isEmpty)
        let stop = r.advance(sec)
        #expect(sends(stop) == [.stop(camID: 1)] && has(stop, .closeListener))
        #expect(!r.c.isStarted && r.c.nextDeadline == nil)
    }

    @Test func startIsImmediateEvenRightAfterAStop() {
        var r = Rig()
        r.started()
        _ = r.usage(false)
        _ = r.advance(3 * sec)
        let out = r.usage(true)
        #expect(has(out, .openListener(camID: 2)))  // a new stream, a new cam_id
        #expect(sends(r.opened()) == [.start(camID: 2, port: 47004)])
    }

    @Test func camIDsIncreaseWithinASessionAndRestartWithTheNextOne() {
        var r = Rig()
        r.started()
        _ = r.usage(false)
        _ = r.advance(3 * sec)
        _ = r.usage(true)
        _ = r.opened()
        #expect(r.c.currentCamID == 2)
        _ = r.take(r.c.sessionEnded())
        r.session()
        _ = r.prefs(auto)
        _ = r.device(true)
        _ = r.usage(true)
        #expect(sends(r.opened()) == [.start(camID: 1, port: 47004)])
    }

    @Test func otherConditionsStopAtOnceWithoutTheFilter() {
        // mode -> OFF
        var a = Rig()
        a.started()
        let off1 = a.prefs(off)
        #expect(sends(off1) == [.stop(camID: 1)] && has(off1, .closeListener) && has(off1, .watchEnvironment(false)))
        // device gone -> STOP then UNAVAILABLE, in this order
        var b = Rig()
        b.started()
        let gone = b.device(false)
        #expect(sends(gone) == [.stop(camID: 1), .unavailable])
        #expect(has(gone, .closeListener))
    }

    @Test func aListenerThatOpensAfterTheConditionsFellIsClosedAgain() {
        var r = Rig()
        r.session()
        _ = r.prefs(auto)
        _ = r.device(true)
        _ = r.usage(true)  // opening
        _ = r.prefs(off)  // before the listener answered
        let late = r.opened()
        #expect(sends(late).isEmpty)
        #expect(!r.c.isStarted)
    }

    // MARK: UNAVAILABLE

    @Test func unavailableIsSentOncePerChange() {
        var r = Rig()
        r.session()
        _ = r.prefs(auto)
        #expect(sends(r.device(false)) == [.unavailable])
        #expect(r.device(false).isEmpty)
        #expect(r.usage(true).isEmpty)  // still nothing to start
        #expect(sends(r.usage(false)).isEmpty)
        // Device appears and disappears again: reported again.
        _ = r.device(true)
        #expect(sends(r.device(false)).contains(.unavailable))
        // OFF and AUTO again: reported again as well.
        _ = r.prefs(off)
        _ = r.prefs(auto)
        #expect(sends(r.device(false)) == [.unavailable])
    }

    @Test func offNeverReportsUnavailable() {
        var r = Rig()
        r.session()
        #expect(sends(r.prefs(off)).isEmpty)
        #expect(sends(r.device(false)).isEmpty)
    }

    // MARK: Session end

    @Test func sessionEndClosesEverythingWithoutAMessage() {
        var r = Rig()
        r.started()
        let out = r.take(r.c.sessionEnded())
        #expect(sends(out).isEmpty)
        #expect(has(out, .closeListener) && has(out, .watchEnvironment(false)))
        #expect(!r.c.isWatching && !r.c.isStarted && r.c.nextDeadline == nil)
        // Late events of the old session do nothing.
        #expect(r.usage(true).isEmpty && r.device(true).isEmpty)
        #expect(r.prefs(auto).isEmpty)
    }

    @Test func aNewSessionStartsInOffEvenIfTheOldOneWasAuto() {
        var r = Rig()
        r.started()
        _ = r.take(r.c.sessionEnded())
        r.session()
        #expect(!r.c.isEnabled && !r.c.isWatching)
    }

    @Test func facingChangesAreNotTheHostsBusiness() {
        var r = Rig()
        r.started()
        let out = r.prefs(CameraPrefs(mode: .auto, facing: .back))
        #expect(out.isEmpty)
        #expect(r.c.isStarted)
    }

    @Test func unknownModeIsOffAndDuplicateAutoDoesNothing() {
        var r = Rig()
        r.session()
        _ = r.prefs(auto)
        #expect(r.prefs(auto).isEmpty)
        _ = r.prefs(CameraPrefs(mode: CameraMode(rawValue: 9), facing: .front))
        #expect(!r.c.isEnabled)
    }
}
