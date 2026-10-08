import Foundation
import Testing
@testable import MateBridgeCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    func add(_ s: String) { lock.withLock { steps.append(s) } }
    var all: [String] { lock.withLock { steps } }
}

private let clean = InputReleaseReport(owed: 0, mirrorEmpty: true)

private func steps(_ r: Recorder, release: @escaping @Sendable () -> InputReleaseReport = { clean },
                   emergency: @escaping @Sendable () -> Int? = { 3 }) -> StallRestart.Steps {
    StallRestart.Steps(
        releaseInput: { let report = release(); r.add("release"); return report },
        scheduleRelaunch: { r.add("relaunch") },
        requestTerminate: { r.add("terminate") },
        emergencyRelease: { r.add("emergency"); return emergency() },
        forceExit: { r.add("exit") },
        log: { r.add("log:\($0)") })
}

@Suite struct StallRestartDecisionTests {
    /// The decision table: only a completed release with nothing owed and an empty mirror restarts.
    @Test func decisionTable() {
        let cases: [(InputReleaseReport?, StallRestartDecision)] = [
            (nil, .skip(reason: "input_wedged")),
            (InputReleaseReport(owed: 0, mirrorEmpty: true), .restart),
            (InputReleaseReport(owed: 0, mirrorEmpty: false), .skip(reason: "input_held")),
            (InputReleaseReport(owed: 2, mirrorEmpty: true), .skip(reason: "owed")),
            (InputReleaseReport(owed: 1, mirrorEmpty: false), .skip(reason: "owed")),
        ]
        for (report, expected) in cases {
            #expect(StallRestartDecision.decide(report: report) == expected)
        }
    }
}

@Suite struct StallRestartTests {
    @Test func confirmedReleaseThenRelaunchTerminateAndExit() {
        let r = Recorder()
        let outcome = StallRestart.run(steps(r), attempt: ReleaseAttempt(), inputTimeout: 1, terminateTimeout: 0.05)
        #expect(outcome == .restarted)
        #expect(r.all == ["release", "log:input=done outcome=restart", "relaunch", "terminate",
                          "log:terminate=timeout", "exit"])
    }

    @Test func owedReleasesSkipTheRestart() {
        let r = Recorder()
        let outcome = StallRestart.run(steps(r, release: { InputReleaseReport(owed: 1, mirrorEmpty: true) }),
                                       attempt: ReleaseAttempt(), inputTimeout: 1, terminateTimeout: 0.05)
        #expect(outcome == .skipped(reason: "owed"))
        #expect(r.all == ["release", "log:outcome=skipped reason=owed"])
    }

    @Test func nonEmptyMirrorSkipsTheRestart() {
        let r = Recorder()
        let outcome = StallRestart.run(steps(r, release: { InputReleaseReport(owed: 0, mirrorEmpty: false) }),
                                       attempt: ReleaseAttempt(), inputTimeout: 1, terminateTimeout: 0.05)
        #expect(outcome == .skipped(reason: "input_held"))
        #expect(!r.all.contains("terminate") && !r.all.contains("exit") && !r.all.contains("relaunch"))
    }

    @Test func wedgedQueueTriesTheEmergencyReleaseButNeverRestarts() {
        let r = Recorder()
        let hang = DispatchSemaphore(value: 0)
        let outcome = StallRestart.run(steps(r, release: { hang.wait(); return clean }, emergency: { 3 }),
                                       attempt: ReleaseAttempt(), inputTimeout: 0.1, emergencyTimeout: 0.5,
                                       terminateTimeout: 0.05)
        #expect(outcome == .skipped(reason: "input_wedged"))
        #expect(r.all == ["emergency", "log:input=emergency released=3 confirmed=0",
                          "log:outcome=skipped reason=input_wedged"])
        hang.signal()
    }

    @Test func failedOrHungEmergencyReleaseStillSkips() {
        let r = Recorder()
        let hang = DispatchSemaphore(value: 0)
        let outcome = StallRestart.run(steps(r, release: { hang.wait(); return clean }, emergency: { hang.wait(); return 1 }),
                                       attempt: ReleaseAttempt(), inputTimeout: 0.05, emergencyTimeout: 0.1,
                                       terminateTimeout: 0.05)
        #expect(outcome == .skipped(reason: "input_wedged"))
        #expect(!r.all.contains("terminate") && !r.all.contains("exit"))
        hang.signal(); hang.signal()
    }

    @Test func retryJoinsTheHangingReleaseAndRestartsOnceItCompletes() {
        let r = Recorder()
        let hang = DispatchSemaphore(value: 0)
        let attempt = ReleaseAttempt()
        let started = Counter()
        let s = steps(r, release: { started.bump(); hang.wait(); return clean }, emergency: { nil })
        let first = StallRestart.run(s, attempt: attempt, inputTimeout: 0.05, emergencyTimeout: 0.05, terminateTimeout: 0.05)
        #expect(first == .skipped(reason: "input_wedged"))
        let second = StallRestart.run(s, attempt: attempt, inputTimeout: 0.05, emergencyTimeout: 0.05, terminateTimeout: 0.05)
        #expect(second == .skipped(reason: "input_wedged"))
        #expect(started.value == 1)  // no second blocked thread
        hang.signal()
        let third = StallRestart.run(s, attempt: attempt, inputTimeout: 1, emergencyTimeout: 0.05, terminateTimeout: 0.05)
        #expect(third == .restarted)
    }

    @Test func relaunchWaitsForTheOldProcess() {
        let args = StallRestart.relaunchArguments(pid: 123, bundlePath: "/Apps/MateBridge.app")
        #expect(args.count == 6)
        #expect(args[0] == "-c")
        #expect(args[1].contains("kill -0"))
        #expect(args[1].range(of: "kill -0")!.lowerBound < args[1].range(of: "open -n")!.lowerBound)
        #expect(Array(args[3...]) == ["123", "/Apps/MateBridge.app", "25"])
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var conts: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.withLock { conts.append(c) } } }
    func open() { lock.withLock { conts.forEach { $0.resume() }; conts = [] } }
}

@Suite struct AbandonedStopsTests {
    @Test func oneAbandonedStopIsTolerated() {
        let t = AbandonedStops()
        let a = t.newToken()
        #expect(t.abandon(a, step: "capture", nowUs: 0) == 1)
        #expect(t.escalation(nowUs: 10_000_000) == nil)
    }

    @Test func twoOpenStopsEscalate() {
        let t = AbandonedStops()
        let a = t.newToken(), b = t.newToken()
        t.abandon(a, step: "capture", nowUs: 0)
        #expect(t.abandon(b, step: "encoder", nowUs: 1_000_000) == 2)
        #expect(t.escalation(nowUs: 2_000_000) == "count=2")
    }

    @Test func resolvedStopsDoNotCount() {
        let t = AbandonedStops()
        let a = t.newToken(), b = t.newToken()
        t.abandon(a, step: "capture", nowUs: 0)
        t.completed(a)
        #expect(t.abandon(b, step: "encoder", nowUs: 0) == 1)
        #expect(t.escalation(nowUs: 1_000_000) == nil)
    }

    @Test func completionBeforeAbandonIsRemembered() {
        let t = AbandonedStops()
        let a = t.newToken()
        t.completed(a)  // the late completion won the race against recording the timeout
        #expect(t.abandon(a, step: "capture", nowUs: 0) == 0)
    }

    @Test func oneStopOlderThanAMinuteEscalates() {
        let t = AbandonedStops()
        let a = t.newToken()
        t.abandon(a, step: "capture", nowUs: 5_000_000)
        #expect(t.escalation(nowUs: 64_000_000) == nil)
        #expect(t.escalation(nowUs: 65_000_000) == "age_ms=60000")
    }

    @Test func boundedWaitReportsLateCompletion() async {
        let t = AbandonedStops()
        let token = t.newToken()
        let gate = AsyncGate()
        let outcome = await BoundedWait.run(timeout: 0.05, onLateCompletion: { t.completed(token) }) {
            await gate.wait()
        }
        #expect(outcome == .timedOut)
        t.abandon(token, step: "capture", nowUs: 0)
        #expect(t.openCount == 1)
        gate.open()
        for _ in 0..<50 where t.openCount != 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(t.openCount == 0)
    }
}

@Suite struct WatchdogRefuseStepTests {
    /// The coordinator refuses new sessions on `endSessions` (10 s) and keeps refusing through `restart` (30 s).
    @Test func sessionRefusalStepsComeInOrder() {
        var w = CoordinatorWatchdog()
        w.begin(kind: "sessionEnded", nowUs: 0)
        let early = w.poll(nowUs: 9_000_000)
        #expect(!early.contains(.endSessions(kind: "sessionEnded", ms: 9_000)))
        #expect(w.poll(nowUs: 10_000_000).contains(.endSessions(kind: "sessionEnded", ms: 10_000)))
        #expect(w.poll(nowUs: 30_000_000) == [.restart(kind: "sessionEnded", ms: 30_000)])
    }
}

@Suite struct AbandonedStopsAgeTests {
    @Test func stopRecordedAfterNowWasSampledDoesNotWrapTheAge() {
        let t = AbandonedStops()
        let a = t.newToken()
        t.abandon(a, step: "capture", nowUs: 10_000_000)
        #expect(t.escalation(nowUs: 5_000_000) == nil)  // `now` sampled before the stop was recorded
    }
}

@Suite struct WatchdogRefusalInterleavingTests {
    private let sec: UInt64 = 1_000_000

    @Test func lateStepsAfterTheEventEndedNeverRefuse() {
        var w = CoordinatorWatchdog()
        w.begin(kind: "a", nowUs: 0)
        let first = w.poll(nowUs: 10 * sec)
        #expect(first.count == 2)  // warn + endSessions
        #expect(w.refusing)
        w.end(nowUs: 10 * sec)
        let lifted = w.liftRefusal()
        #expect(lifted)
        #expect(!w.refusing)
        // Poll and hook calls share one lock with the end, so a poll that saw the event cannot apply afterwards; a
        // poll after the end sees no event and refuses nothing.
        let late = w.poll(nowUs: 11 * sec)
        #expect(late.isEmpty)
        #expect(!w.refusing)
    }

    @Test func healthyCompletionLiftsTheRefusalOnceAndIsIdempotent() {
        var w = CoordinatorWatchdog()
        w.begin(kind: "a", nowUs: 0)
        _ = w.poll(nowUs: 10 * sec)
        w.end(nowUs: 10 * sec)
        w.begin(kind: "tick", nowUs: 11 * sec)
        w.end(nowUs: 11 * sec)
        let first = w.liftRefusal()
        let second = w.liftRefusal()
        #expect(first)
        #expect(!second)
        #expect(!w.refusing)
    }

    @Test func refusalStaysAfterARestartWasRequested() {
        var w = CoordinatorWatchdog()
        w.begin(kind: "a", nowUs: 0)
        let actions = w.poll(nowUs: 30 * sec)
        #expect(actions.contains(.restart(kind: "a", ms: 30_000)))
        w.end(nowUs: 31 * sec)
        let lifted = w.liftRefusal()
        let again = w.requestRestart()
        #expect(!lifted)
        #expect(w.refusing && w.restartRequested)
        #expect(!again)  // only once
    }

    @Test func externalRestartRequestRefusesAndIsOnce() {
        var w = CoordinatorWatchdog()
        let first = w.requestRestart()
        #expect(first)
        #expect(w.refusing)
        let lifted = w.liftRefusal()
        let second = w.requestRestart()
        #expect(!lifted)
        #expect(!second)
    }
}

@Suite struct StallGateSplitTests {
    private func k(_ kind: MacKey.Kind, _ code: UInt16) -> MacEvent { .key(MacKey(kind: kind, keyCode: code, flags: [])) }

    /// The stall gate of `InputController` is `HostSleepInputGate.split` while the refusal is up: openings are dropped
    /// (after the 10 s step nothing new is pressed), closings still pass in order.
    @Test func opensAreDroppedClosesPassAfterEscalation() {
        let p = DisplayPoint(x: 1, y: 1)
        let batch: [MacEvent] = [
            k(.keyDown, 8), k(.keyUp, 9), k(.modifierDown, 55), k(.modifierUp, 56),
            .mouse(MacMouse(kind: .down, button: .left, position: p, deltaX: 0, deltaY: 0, clickState: 1)),
            .mouse(MacMouse(kind: .up, button: .left, position: p, deltaX: 0, deltaY: 0, clickState: 1)),
            .tabletProximity(tool: .pen, entering: true), .tabletProximity(tool: .pen, entering: false),
        ]
        let (pass, dropped) = HostSleepInputGate.split(batch)
        #expect(dropped.count == 4)
        #expect(pass.allSatisfy { $0.isClosing })
        #expect(pass.count == 4)
    }

    @Test func refusalStepRaisesTheGateAndLiftingClearsIt() {
        var w = CoordinatorWatchdog()
        w.begin(kind: "x", nowUs: 0)
        _ = w.poll(nowUs: 9_000_000)
        #expect(!w.refusing)  // gate and refusal share this flag: up only from the 10 s step
        _ = w.poll(nowUs: 10_000_000)
        #expect(w.refusing)
        w.end(nowUs: 11_000_000)
        let lifted = w.liftRefusal()
        #expect(lifted && !w.refusing)
    }
}
