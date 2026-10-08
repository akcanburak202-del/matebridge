import Foundation
import Testing
@testable import MateBridgeCore

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    func add(_ s: String) { lock.withLock { steps.append(s) } }
    var all: [String] { lock.withLock { steps } }
}

private func steps(_ r: Recorder, release: @escaping @Sendable () -> Void,
                   emergency: @escaping @Sendable () -> Int? = { 3 }) -> StallRestart.Steps {
    StallRestart.Steps(
        releaseInput: { release(); r.add("release") },
        scheduleRelaunch: { r.add("relaunch") },
        requestTerminate: { r.add("terminate") },
        emergencyRelease: { r.add("emergency"); return emergency() },
        forceExit: { r.add("exit") },
        log: { r.add("log:\($0)") })
}

@Suite struct StallRestartTests {
    @Test func inputIsReleasedBeforeRelaunchTerminateAndExit() {
        let r = Recorder()
        StallRestart.run(steps(r, release: {}), inputTimeout: 1, terminateTimeout: 0.05)
        #expect(r.all == ["release", "log:input=done", "relaunch", "terminate", "log:terminate=timeout", "exit"])
    }

    @Test func wedgedInputQueueIsReleasedByTheEmergencyPathBeforeAnyExit() {
        let r = Recorder()
        let hang = DispatchSemaphore(value: 0)
        let outcome = StallRestart.run(steps(r, release: { hang.wait() }), inputTimeout: 0.1, emergencyTimeout: 0.5,
                                       terminateTimeout: 0.05)
        #expect(outcome == .restarted)
        #expect(r.all == ["emergency", "log:input=emergency released=3", "relaunch", "terminate",
                          "log:terminate=timeout", "exit"])
        hang.signal()
    }

    @Test func failedEmergencyReleaseNeverTerminatesOrExits() {
        let r = Recorder()
        let hang = DispatchSemaphore(value: 0)
        let outcome = StallRestart.run(steps(r, release: { hang.wait() }, emergency: { nil }), inputTimeout: 0.1,
                                       emergencyTimeout: 0.5, terminateTimeout: 0.05)
        #expect(outcome == .inputUnreleased)
        #expect(r.all == ["emergency", "log:input=unreleased"])
        hang.signal()
    }

    @Test func hungEmergencyReleaseIsTreatedAsUnreleased() {
        let r = Recorder()
        let hang = DispatchSemaphore(value: 0)
        let outcome = StallRestart.run(steps(r, release: { hang.wait() }, emergency: { hang.wait(); return 1 }),
                                       inputTimeout: 0.05, emergencyTimeout: 0.1, terminateTimeout: 0.05)
        #expect(outcome == .inputUnreleased)
        #expect(!r.all.contains("terminate") && !r.all.contains("exit"))
        hang.signal(); hang.signal()
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
