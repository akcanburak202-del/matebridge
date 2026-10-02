import XCTest
@testable import MateBridgeCore

final class SleepWakeGateTests: XCTestCase {
    private let s: UInt64 = 1_000_000
    private let ms: UInt64 = 1_000

    func testClassifiesIOKitMessages() {
        XCTAssertEqual(PowerEvent.fromIOKitMessage(0xE000_0270), .canSleep)
        XCTAssertEqual(PowerEvent.fromIOKitMessage(0xE000_0280), .willSleep)
        XCTAssertEqual(PowerEvent.fromIOKitMessage(0xE000_0290), .willNotSleep)
        XCTAssertEqual(PowerEvent.fromIOKitMessage(0xE000_0300), .didWake)
        XCTAssertNil(PowerEvent.fromIOKitMessage(0xE000_0320))  // SystemWillPowerOn: not used
        XCTAssertNil(PowerEvent.fromIOKitMessage(0))
        XCTAssertTrue(PowerEvent.canSleep.needsAcknowledgement)
        XCTAssertTrue(PowerEvent.willSleep.needsAcknowledgement)
        XCTAssertFalse(PowerEvent.didWake.needsAcknowledgement)
        XCTAssertFalse(PowerEvent.willNotSleep.needsAcknowledgement)
        XCTAssertEqual(PowerEvent.canSleep.rawValue, "can_sleep")
        XCTAssertEqual(PowerEvent.willSleep.rawValue, "will_sleep")
        XCTAssertEqual(PowerEvent.didWake.rawValue, "did_wake")
    }

    func testDefaultDeferralIsOnePointFiveSeconds() {
        XCTAssertEqual(SleepWakeGate.captureLossDeferUs, 1_500_000)
        XCTAssertEqual(SleepWakeGate().deferUs, 1_500_000)
    }

    func testCaptureLossIsDeferredThenWakes() {
        var g = SleepWakeGate()
        XCTAssertEqual(g.request(.captureSourceLost, now: 10 * s), .deferred(deadlineUs: 10 * s + 1_500 * ms))
        XCTAssertEqual(g.pending, .captureSourceLost)
        XCTAssertNil(g.due(now: 10 * s + 1_499 * ms), "not before the deadline")
        XCTAssertEqual(g.pendingDeadlineUs, 10 * s + 1_500 * ms, "still pending")
        XCTAssertEqual(g.due(now: 10 * s + 1_500 * ms), .captureSourceLost)
        XCTAssertNil(g.pending)
        XCTAssertNil(g.due(now: 20 * s), "handed out once")
    }

    /// `pmset sleepnow`: displays go dark (-3815), then the sleep notification arrives inside the window.
    func testSleepNotificationInsideWindowDropsTheWake() {
        var g = SleepWakeGate()
        XCTAssertEqual(g.request(.captureSourceLost, now: 10 * s), .deferred(deadlineUs: 10 * s + 1_500 * ms))
        let out = g.power(.willSleep, now: 10 * s + 400 * ms)
        XCTAssertEqual(out, .init(logState: true, suppressedPending: .captureSourceLost))
        XCTAssertNil(g.pending)
        XCTAssertNil(g.due(now: 12 * s), "the deferred wake never fires")
    }

    func testCanSleepAlsoSuppresses() {
        var g = SleepWakeGate()
        _ = g.request(.captureSourceLost, now: 10 * s)
        XCTAssertEqual(g.power(.canSleep, now: 10 * s + 100 * ms).suppressedPending, .captureSourceLost)
        XCTAssertTrue(g.sleeping)
        XCTAssertNil(g.due(now: 12 * s))
    }

    func testWhileSleepingEveryReasonIsSuppressedAndLoggedOncePerEpisode() {
        var g = SleepWakeGate()
        XCTAssertEqual(g.power(.willSleep, now: 1 * s), .init(logState: true, suppressedPending: nil))
        XCTAssertEqual(g.request(.captureSourceLost, now: 2 * s), .suppressed(log: true))
        XCTAssertEqual(g.request(.displayCreateNil, now: 3 * s), .suppressed(log: false))
        XCTAssertEqual(g.request(.displayCreateNil, now: 4 * s), .suppressed(log: false))
        XCTAssertNil(g.pending)
    }

    func testDroppedPendingCountsAsTheEpisodeLog() {
        var g = SleepWakeGate()
        _ = g.request(.captureSourceLost, now: 1 * s)
        XCTAssertEqual(g.power(.willSleep, now: 1 * s + 200 * ms).suppressedPending, .captureSourceLost)
        XCTAssertEqual(g.request(.displayCreateNil, now: 2 * s), .suppressed(log: false))
    }

    func testWakeReopensAndStartsANewEpisode() {
        var g = SleepWakeGate()
        _ = g.power(.willSleep, now: 1 * s)
        XCTAssertEqual(g.request(.displayCreateNil, now: 2 * s), .suppressed(log: true))
        XCTAssertEqual(g.power(.didWake, now: 3 * s), .init(logState: true, suppressedPending: nil))
        XCTAssertFalse(g.sleeping)
        XCTAssertEqual(g.request(.displayCreateNil, now: 4 * s), .wakeNow)
        _ = g.power(.willSleep, now: 5 * s)
        XCTAssertEqual(g.request(.displayCreateNil, now: 6 * s), .suppressed(log: true), "new episode logs again")
    }

    func testCancelledIdleSleepReopens() {
        var g = SleepWakeGate()
        _ = g.power(.canSleep, now: 1 * s)
        XCTAssertEqual(g.power(.willNotSleep, now: 2 * s), .init(logState: true, suppressedPending: nil))
        XCTAssertFalse(g.sleeping)
        XCTAssertEqual(g.request(.displayCreateNil, now: 3 * s), .wakeNow)
    }

    func testStateIsLoggedOnChangeOnly() {
        var g = SleepWakeGate()
        XCTAssertTrue(g.power(.canSleep, now: 1 * s).logState)
        XCTAssertFalse(g.power(.canSleep, now: 2 * s).logState)
        XCTAssertTrue(g.power(.willSleep, now: 3 * s).logState)
        XCTAssertFalse(g.power(.willSleep, now: 3 * s).logState)
        XCTAssertTrue(g.power(.didWake, now: 4 * s).logState)
        XCTAssertFalse(g.power(.didWake, now: 5 * s).logState)
    }

    func testDisplayCreateNilWakesAtOnceWhenAwakeAndNothingPending() {
        var g = SleepWakeGate()
        XCTAssertEqual(g.request(.displayCreateNil, now: 1 * s), .wakeNow)
        XCTAssertNil(g.pending)
    }

    /// The pipeline retry (1 s after -3815) fails with `display_create_nil` inside the window: it joins the pending
    /// wake instead of waking early, so a sleep notification at 1.2 s still wins.
    func testLaterLossJoinsThePendingWake() {
        var g = SleepWakeGate()
        _ = g.request(.captureSourceLost, now: 10 * s)
        XCTAssertEqual(g.request(.displayCreateNil, now: 11 * s), .pending)
        XCTAssertEqual(g.request(.captureSourceLost, now: 11 * s + 100 * ms), .pending)
        XCTAssertEqual(g.pendingDeadlineUs, 10 * s + 1_500 * ms, "the deadline is not pushed out")
        XCTAssertEqual(g.power(.willSleep, now: 11 * s + 200 * ms).suppressedPending, .captureSourceLost)
        XCTAssertNil(g.due(now: 12 * s))
    }

    func testCancelPendingOnRecoveryOrSessionEnd() {
        var g = SleepWakeGate()
        _ = g.request(.captureSourceLost, now: 1 * s)
        g.cancelPending()
        XCTAssertNil(g.pending)
        XCTAssertNil(g.due(now: 5 * s))
        XCTAssertEqual(g.request(.captureSourceLost, now: 6 * s), .deferred(deadlineUs: 7_500 * ms),
                       "a new loss defers again")
    }

    func testSleepWithoutPendingDropsNothing() {
        var g = SleepWakeGate()
        XCTAssertNil(g.power(.willSleep, now: 1 * s).suppressedPending)
    }

    func testCustomDeferral() {
        var g = SleepWakeGate(deferUs: 200 * ms)
        XCTAssertEqual(g.request(.captureSourceLost, now: 1 * s), .deferred(deadlineUs: 1_200 * ms))
        XCTAssertEqual(g.due(now: 1_200 * ms), .captureSourceLost)
    }
}
