import XCTest
@testable import MateBridgeCore

/// T-293: the circuit breaker of `PipelineRetryPolicy` (pure, host clock in microseconds).
final class PipelineBreakerTests: XCTestCase {
    private let s: UInt64 = 1_000_000

    private func device(_ b: UInt8) -> DeviceID {
        DeviceID(bytes: [UInt8](repeating: b, count: ProtocolConstants.deviceIDSize))!
    }

    /// Three retried failures and the fourth: the budget is used up and the breaker opens at step 1 (10 s).
    private func openBreaker(_ p: inout PipelineRetryPolicy, at t: UInt64 = 0) {
        for i in 0..<3 { _ = p.failed(kind: .encoder, hdr10: false, nowUs: t + UInt64(i) * s) }
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: false, nowUs: t + 3 * s), .giveUp)
    }

    func testClosedBreakerAdmits() {
        var p = PipelineRetryPolicy()
        XCTAssertEqual(p.admit(nowUs: 5 * s), .build)
        XCTAssertEqual(p.breaker, .init(state: .closed, level: 0, waitUs: 0))
    }

    func testGiveUpOpensBreakerAndRefusesWithRemainingTime() {
        var p = PipelineRetryPolicy()
        openBreaker(&p)  // opened at 3 s, until 13 s
        XCTAssertEqual(p.breaker, .init(state: .open, level: 1, waitUs: 10 * s))
        XCTAssertEqual(p.admit(nowUs: 4 * s), .refuse(remainingUs: 9 * s))
        XCTAssertEqual(p.admit(nowUs: 12 * s), .refuse(remainingUs: s))
        XCTAssertEqual(p.refusals, 2)
    }

    func testWaitElapsedAdmitsOneProbe() {
        var p = PipelineRetryPolicy()
        openBreaker(&p)
        XCTAssertEqual(p.admit(nowUs: 13 * s), .build)
        XCTAssertEqual(p.breaker.state, .probe)
    }

    func testFailedProbeOpensNextStepsUpToThirtySeconds() {
        var p = PipelineRetryPolicy()
        openBreaker(&p)
        var now = 13 * s
        var waits: [UInt64] = [p.breaker.waitUs]
        for _ in 0..<4 {
            XCTAssertEqual(p.admit(nowUs: now), .build)
            p.built(nowUs: now)
            XCTAssertEqual(p.failed(kind: .encoder, hdr10: false, nowUs: now + s), .giveUp)  // died after 1 s
            waits.append(p.breaker.waitUs)
            now += s + p.breaker.waitUs
        }
        XCTAssertEqual(waits, [10 * s, 20 * s, 30 * s, 30 * s, 30 * s])
        XCTAssertEqual(p.breaker.level, PipelineRetryPolicy.maxBreakerLevel)
    }

    func testFailedProbeEscalatesEvenAfterTheWindowHasPassed() {
        var p = PipelineRetryPolicy()
        openBreaker(&p)
        XCTAssertEqual(p.admit(nowUs: 100 * s), .build)
        XCTAssertEqual(p.failed(kind: .other, hdr10: false, nowUs: 101 * s), .giveUp)
        XCTAssertEqual(p.breaker, .init(state: .open, level: 2, waitUs: 20 * s))
    }

    func testStartFailureOfProbeEscalatesToo() {
        var p = PipelineRetryPolicy()
        openBreaker(&p)
        XCTAssertEqual(p.admit(nowUs: 13 * s), .build)
        _ = p.failed(kind: .start, hdr10: false, nowUs: 13 * s)
        XCTAssertEqual(p.breaker, .init(state: .open, level: 2, waitUs: 20 * s))
    }

    func testLazySuccessClearsHistoryAndLadderOnLateFailure() {
        var p = PipelineRetryPolicy()
        openBreaker(&p)
        XCTAssertEqual(p.admit(nowUs: 13 * s), .build)
        p.built(nowUs: 13 * s)
        // The probe pipeline ran 10 s: its failure is the first of a fresh budget, the breaker closes.
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: false, nowUs: 23 * s), .retry(delayUs: s, attempt: 1))
        XCTAssertEqual(p.breaker, .init(state: .closed, level: 0, waitUs: 0))
        XCTAssertEqual(p.recentFailureCount, 1)
    }

    func testPipelineThatRanLessThanTenSecondsIsNotASuccess() {
        var p = PipelineRetryPolicy()
        openBreaker(&p)
        XCTAssertEqual(p.admit(nowUs: 13 * s), .build)
        p.built(nowUs: 13 * s)
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: false, nowUs: 13 * s + PipelineRetryPolicy.successUs - 1), .giveUp)
        XCTAssertEqual(p.breaker.level, 2)
    }

    func testLazySuccessAlsoOnDeliberateStop() {
        var p = PipelineRetryPolicy()
        openBreaker(&p)
        XCTAssertEqual(p.admit(nowUs: 13 * s), .build)
        p.built(nowUs: 13 * s)
        p.stopped(nowUs: 40 * s)  // parked after a long run
        XCTAssertEqual(p.breaker.state, .closed)
        XCTAssertEqual(p.recentFailureCount, 0)
        // A short run that is stopped is not one.
        openBreaker(&p, at: 100 * s)
        XCTAssertEqual(p.admit(nowUs: 113 * s), .build)
        p.built(nowUs: 113 * s)
        p.stopped(nowUs: 114 * s)
        XCTAssertEqual(p.breaker.state, .probe)
    }

    func testStartFailureNeverCountsAsLazySuccess() {
        var p = PipelineRetryPolicy()
        p.built(nowUs: 0)  // a stale build time must not turn a start failure into a success
        _ = p.failed(kind: .start, hdr10: false, nowUs: 100 * s)
        _ = p.failed(kind: .start, hdr10: false, nowUs: 101 * s)
        XCTAssertEqual(p.recentFailureCount, 2)
    }

    func testStartFailuresCountTowardTheBudgetAndOpenTheBreaker() {
        var p = PipelineRetryPolicy()
        for i in 0..<3 { _ = p.failed(kind: .start, hdr10: false, nowUs: UInt64(i) * s) }
        XCTAssertEqual(p.breaker.state, .closed)
        XCTAssertEqual(p.failed(kind: .start, hdr10: false, nowUs: 3 * s), .giveUp)
        XCTAssertEqual(p.admit(nowUs: 4 * s), .refuse(remainingUs: 9 * s))
    }

    func testMixedKindsShareOneBudget() {
        var p = PipelineRetryPolicy()
        _ = p.failed(kind: .start, hdr10: false, nowUs: 0)
        _ = p.failed(kind: .encoder, hdr10: false, nowUs: s)
        _ = p.failed(kind: .start, hdr10: false, nowUs: 2 * s)
        XCTAssertEqual(p.failed(kind: .other, hdr10: false, nowUs: 3 * s), .giveUp)
    }

    func testStartKindRawValue() {
        XCTAssertEqual(PipelineFailureKind.start.rawValue, "start")
    }

    func testSameDeviceKeepsBreakerAcrossSessions() {
        var p = PipelineRetryPolicy()
        p.sessionStarted(device: device(1))
        openBreaker(&p)
        p.sessionStarted(device: device(1))  // the tablet's ~6 s session renewal
        XCTAssertEqual(p.breaker.state, .open)
        XCTAssertEqual(p.admit(nowUs: 5 * s), .refuse(remainingUs: 8 * s))
    }

    func testOtherDeviceTakeoverResets() {
        var p = PipelineRetryPolicy()
        p.sessionStarted(device: device(1))
        openBreaker(&p)
        p.sessionStarted(device: device(2))
        XCTAssertEqual(p.breaker, .init(state: .closed, level: 0, waitUs: 0))
        XCTAssertEqual(p.recentFailureCount, 0)
        XCTAssertEqual(p.admit(nowUs: 5 * s), .build)
        // The first device coming back is "another" again.
        openBreaker(&p, at: 10 * s)
        p.sessionStarted(device: device(1))
        XCTAssertEqual(p.breaker.state, .closed)
    }

    func testResetClosesBreakerAndGivesFreshBudget() {
        var p = PipelineRetryPolicy()
        openBreaker(&p)
        p.reset()  // Mac wake, prefs/mode change
        XCTAssertEqual(p.breaker, .init(state: .closed, level: 0, waitUs: 0))
        XCTAssertEqual(p.admit(nowUs: 4 * s), .build)
        XCTAssertEqual(p.failed(kind: .other, hdr10: false, nowUs: 5 * s), .retry(delayUs: s, attempt: 1))
    }

    func testRefusalLogCadence() {
        XCTAssertTrue(PipelineRetryPolicy.logsRefusal(1))
        XCTAssertFalse(PipelineRetryPolicy.logsRefusal(2))
        XCTAssertFalse(PipelineRetryPolicy.logsRefusal(9))
        XCTAssertTrue(PipelineRetryPolicy.logsRefusal(10))
        XCTAssertTrue(PipelineRetryPolicy.logsRefusal(20))
    }

    func testRefusalCounterRestartsWhenBreakerOpensAgain() {
        var p = PipelineRetryPolicy()
        openBreaker(&p)
        _ = p.admit(nowUs: 4 * s)
        _ = p.admit(nowUs: 5 * s)
        XCTAssertEqual(p.refusals, 2)
        XCTAssertEqual(p.admit(nowUs: 13 * s), .build)
        _ = p.failed(kind: .encoder, hdr10: false, nowUs: 14 * s)
        XCTAssertEqual(p.refusals, 0)
    }

    func testBreakerWaitLadder() {
        XCTAssertEqual(PipelineRetryPolicy.breakerWait(level: 0), 0)
        XCTAssertEqual(PipelineRetryPolicy.breakerWait(level: 1), 10 * s)
        XCTAssertEqual(PipelineRetryPolicy.breakerWait(level: 2), 20 * s)
        XCTAssertEqual(PipelineRetryPolicy.breakerWait(level: 3), 30 * s)
        XCTAssertEqual(PipelineRetryPolicy.breakerWait(level: 9), 30 * s)
    }

    func testFallBackToSdrStillWorksAndKeepsBreakerClosed() {
        var p = PipelineRetryPolicy()
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: true, nowUs: 0), .retry(delayUs: s, attempt: 1))
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: true, nowUs: s), .fallBackToSDR)
        XCTAssertEqual(p.breaker.state, .closed)
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: false, nowUs: 3 * s), .retry(delayUs: s, attempt: 1))
    }

    func testHdrEncoderFailureAfterBreakerOpenedEscalates() {
        var p = PipelineRetryPolicy()
        _ = p.failed(kind: .other, hdr10: true, nowUs: 0)
        _ = p.failed(kind: .other, hdr10: true, nowUs: s)
        _ = p.failed(kind: .other, hdr10: true, nowUs: 2 * s)
        XCTAssertEqual(p.failed(kind: .other, hdr10: true, nowUs: 3 * s), .giveUp)  // opened, failures cleared
        XCTAssertEqual(p.admit(nowUs: 13 * s), .build)
        // The probe's encoder failure is the first one since the breaker opened: the next step, no SDR fallback yet.
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: true, nowUs: 14 * s), .giveUp)
        XCTAssertEqual(p.breaker.level, 2)
    }

    /// T-293 review (Codex P1): the coordinator gates every `.create` of `perform` (session start) and the video
    /// attach through `admit`. Mirrors that sequence on the pure types.
    func testOpenBreakerThenSameDeviceSessionRenewalBuildsNothing() {
        var p = PipelineRetryPolicy()
        var lease = DisplayLease()
        let settings = VideoSettings.tabletDefault
        p.sessionStarted(device: device(1))
        XCTAssertEqual(lease.sessionStarted(device: device(1), settings: settings), [.create(settings)])
        openBreaker(&p)  // the pipeline died repeatedly; opened at 3 s, until 13 s
        lease.displayLost()
        // The tablet renews its session at +6 s: same device, lease idle -> `.create`, but the gate refuses.
        p.sessionStarted(device: device(1))
        XCTAssertEqual(lease.sessionStarted(device: device(1), settings: settings), [.create(settings)])
        XCTAssertEqual(p.admit(nowUs: 9 * s), .refuse(remainingUs: 4 * s))
        lease.displayLost()  // what the coordinator does on refuse
        // And the next renewal again, then the video attach: still refused.
        p.sessionStarted(device: device(1))
        XCTAssertEqual(lease.sessionStarted(device: device(1), settings: settings), [.create(settings)])
        XCTAssertEqual(p.admit(nowUs: 11 * s), .refuse(remainingUs: 2 * s))
        lease.displayLost()
        // Wait over: the first gate is the probe; it builds once, a later attach sees the pipeline (no second admit).
        XCTAssertEqual(p.admit(nowUs: 14 * s), .build)
        XCTAssertEqual(p.breaker.state, .probe)
        // A prefs change resets and admits.
        p.reset()
        XCTAssertEqual(p.admit(nowUs: 15 * s), .build)
    }

    // MARK: Prefs reset (T-293 review round 2)

    private func prefs(chroma: UInt8 = 2, fps: UInt16 = 120) -> StreamPrefs {
        StreamPrefs(fps: fps, scalePermille: 1000, chroma: chroma)
    }

    func testPrefsReplayAcrossRenewalsNeverResetsOnlyARealChangeDoes() {
        var p = PipelineRetryPolicy()
        p.sessionStarted(device: device(1))
        XCTAssertFalse(p.prefsApplied(prefs(), settingsChanged: false), "the first value after start is not a change")
        openBreaker(&p)
        // Renewal: same device, the tablet replays the same prefs on accept (packed now granted: the derived settings
        // changed, the prefs did not).
        for _ in 0..<3 {
            p.sessionStarted(device: device(1))
            XCTAssertFalse(p.prefsApplied(prefs(), settingsChanged: true))
            XCTAssertEqual(p.breaker.state, .open)
        }
        // A different value is the user's change.
        XCTAssertTrue(p.prefsApplied(prefs(fps: 60), settingsChanged: true))
        XCTAssertEqual(p.breaker, .init(state: .closed, level: 0, waitUs: 0))
        XCTAssertEqual(p.admit(nowUs: 5 * s), .build)
    }

    func testPrefsDifferButSettingsEqualDoesNotResetButUpdatesHistory() {
        var p = PipelineRetryPolicy()
        p.sessionStarted(device: device(1))
        _ = p.prefsApplied(prefs(), settingsChanged: false)
        openBreaker(&p)
        // e.g. a bitrate change that MATEBRIDGE_BITRATE_KBPS overrides: same effective settings.
        XCTAssertFalse(p.prefsApplied(prefs(fps: 60), settingsChanged: false))
        XCTAssertEqual(p.breaker.state, .open)
        // The replay of the new prefs, now with changed derived settings, is still no change.
        XCTAssertFalse(p.prefsApplied(prefs(fps: 60), settingsChanged: true))
        XCTAssertEqual(p.breaker.state, .open)
    }

    func testPrefsHistoryIsForgottenOnOtherDeviceAndOnReset() {
        var p = PipelineRetryPolicy()
        p.sessionStarted(device: device(1))
        _ = p.prefsApplied(prefs(), settingsChanged: false)
        p.sessionStarted(device: device(2))
        XCTAssertFalse(p.prefsApplied(prefs(fps: 60), settingsChanged: true), "no previous value for this device")
        p.reset()  // Mac wake
        XCTAssertFalse(p.prefsApplied(prefs(), settingsChanged: false), "forgotten by a reset")
    }

    func testStoppedAfterLongRunChangesTheSnapshotSoTheOwnerLogsIt() {
        var p = PipelineRetryPolicy()
        openBreaker(&p)
        XCTAssertEqual(p.admit(nowUs: 13 * s), .build)
        p.built(nowUs: 13 * s)
        let before = p.breaker
        p.stopped(nowUs: 30 * s)
        XCTAssertNotEqual(p.breaker, before)
    }
}
