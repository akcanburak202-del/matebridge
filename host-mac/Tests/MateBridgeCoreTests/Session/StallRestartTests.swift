import Foundation
import Testing
@testable import MateBridgeCore

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    func add(_ s: String) { lock.withLock { steps.append(s) } }
    var all: [String] { lock.withLock { steps } }
}

private func steps(_ r: Recorder, release: @escaping @Sendable () -> Void) -> StallRestart.Steps {
    StallRestart.Steps(
        releaseInput: { release(); r.add("release") },
        scheduleRelaunch: { r.add("relaunch") },
        requestTerminate: { r.add("terminate") },
        forceExit: { r.add("exit") },
        log: { r.add("log:\($0)") })
}

@Suite struct StallRestartTests {
    @Test func inputIsReleasedBeforeRelaunchTerminateAndExit() {
        let r = Recorder()
        StallRestart.run(steps(r, release: {}), inputTimeout: 1, terminateTimeout: 0.05)
        #expect(r.all == ["release", "log:input=done", "relaunch", "terminate", "log:terminate=timeout", "exit"])
    }

    @Test func hungInputReleaseDoesNotBlockTheRestartAndIsReportedPending() {
        let r = Recorder()
        let hang = DispatchSemaphore(value: 0)
        StallRestart.run(steps(r, release: { hang.wait() }), inputTimeout: 0.1, terminateTimeout: 0.05)
        #expect(r.all == ["log:input=pending", "relaunch", "terminate", "log:terminate=timeout", "exit"])
        hang.signal()
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
