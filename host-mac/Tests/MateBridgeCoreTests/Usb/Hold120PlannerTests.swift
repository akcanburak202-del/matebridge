import XCTest
@testable import MateBridgeCore

final class Hold120PlannerTests: XCTestCase {
    private let sec: UInt64 = 1_000_000
    private let good = Hold120Conditions(deviceKnown: true, usbTransport: true, videoFlowing: true,
                                         gameScreen: true, streamFps: 120)

    private func onPlanner(at now: UInt64 = 10_000_000) -> Hold120Planner {
        var p = Hold120Planner()
        _ = p.evaluate(nowUs: now, conditions: good)
        return p
    }

    // MARK: Knob

    func testKnobOnlyOneTurnsItOn() {
        XCTAssertTrue(Hold120Knob.isEnabled(["MATEBRIDGE_HOLD120": "1"]))
        XCTAssertTrue(Hold120Knob.isEnabled(["MATEBRIDGE_HOLD120": " 1 "]))
        for value in ["0", "", "true", "yes", "2", "on", "11"] {
            XCTAssertFalse(Hold120Knob.isEnabled(["MATEBRIDGE_HOLD120": value]), value)
        }
        XCTAssertFalse(Hold120Knob.isEnabled([:]))
    }

    // MARK: Conditions

    func testAllConditionsMeansOn() {
        XCTAssertNil(good.firstBroken)
    }

    func testFirstBrokenConditionInOrder() {
        var c = Hold120Conditions.none
        XCTAssertEqual(c.firstBroken, .noDevice)
        c.deviceKnown = true
        XCTAssertEqual(c.firstBroken, .notUsb)
        c.usbTransport = true
        XCTAssertEqual(c.firstBroken, .noVideo)
        c.videoFlowing = true
        XCTAssertEqual(c.firstBroken, .notGame)
        c.gameScreen = true
        XCTAssertEqual(c.firstBroken, .fpsNot120)
        c.streamFps = 60
        XCTAssertEqual(c.firstBroken, .fpsNot120)
        c.streamFps = 144
        XCTAssertEqual(c.firstBroken, .fpsNot120)
        c.streamFps = 120
        XCTAssertNil(c.firstBroken)
    }

    func testEachSingleBrokenConditionTurnsItOff() {
        var c = good
        c.deviceKnown = false
        XCTAssertEqual(c.firstBroken, .noDevice)
        c = good; c.usbTransport = false
        XCTAssertEqual(c.firstBroken, .notUsb)
        c = good; c.videoFlowing = false
        XCTAssertEqual(c.firstBroken, .noVideo)
        c = good; c.gameScreen = false
        XCTAssertEqual(c.firstBroken, .notGame)
        c = good; c.streamFps = 90
        XCTAssertEqual(c.firstBroken, .fpsNot120)
    }

    // MARK: State changes

    func testStateChangeReportedOnlyOnChange() {
        var p = Hold120Planner()
        XCTAssertEqual(p.evaluate(nowUs: 0, conditions: .none)?.logFields, "state=off reason=no_device")
        XCTAssertNil(p.evaluate(nowUs: 1, conditions: .none))
        XCTAssertEqual(p.evaluate(nowUs: 2, conditions: good)?.logFields, "state=on")
        XCTAssertNil(p.evaluate(nowUs: 3, conditions: good))
        var wifi = good
        wifi.usbTransport = false
        XCTAssertEqual(p.evaluate(nowUs: 4, conditions: wifi)?.logFields, "state=off reason=not_usb")
        XCTAssertNil(p.evaluate(nowUs: 5, conditions: wifi))
        // The reason changes while still off: reported again.
        var noVideo = good
        noVideo.videoFlowing = false
        XCTAssertEqual(p.evaluate(nowUs: 6, conditions: noVideo)?.logFields, "state=off reason=no_video")
    }

    func testFirstEvaluationWhileOnReports() {
        var p = Hold120Planner()
        XCTAssertEqual(p.evaluate(nowUs: 0, conditions: good)?.logFields, "state=on")
    }

    func testOffGivesOffAction() {
        var p = Hold120Planner()
        _ = p.evaluate(nowUs: 0, conditions: .none)
        XCTAssertEqual(p.next(nowUs: 5 * sec, lastInputUs: nil), .off)
        XCTAssertEqual(p.taps, 0)
    }

    // MARK: Cadence

    func testFirstTapIsImmediateThenOncePerSecond() {
        var p = onPlanner(at: 10 * sec)
        XCTAssertEqual(p.next(nowUs: 10 * sec, lastInputUs: nil), .tap)
        p.tapFinished(nowUs: 10 * sec + 30_000, success: true)
        let due = 10 * sec + 30_000 + Hold120Planner.intervalUs
        XCTAssertEqual(p.next(nowUs: 10 * sec + 500_000, lastInputUs: nil), .sleep(untilUs: due))
        XCTAssertEqual(p.next(nowUs: due - 1, lastInputUs: nil), .sleep(untilUs: due))
        XCTAssertEqual(p.next(nowUs: due, lastInputUs: nil), .tap)
        XCTAssertEqual(p.taps, 2)
    }

    func testAtMostOneTapInFlight() {
        var p = onPlanner()
        XCTAssertEqual(p.next(nowUs: 10 * sec, lastInputUs: nil), .tap)
        XCTAssertTrue(p.tapInFlight)
        XCTAssertEqual(p.next(nowUs: 11 * sec, lastInputUs: nil), .waitForCompletion)
        XCTAssertEqual(p.next(nowUs: 99 * sec, lastInputUs: nil), .waitForCompletion)
        XCTAssertEqual(p.taps, 1)
        p.tapFinished(nowUs: 12 * sec, success: true)
        XCTAssertFalse(p.tapInFlight)
    }

    func testStillOneInFlightAfterOffAndBackOn() {
        var p = onPlanner()
        XCTAssertEqual(p.next(nowUs: 10 * sec, lastInputUs: nil), .tap)
        var off = good
        off.gameScreen = false
        _ = p.evaluate(nowUs: 10 * sec + 1, conditions: off)
        XCTAssertEqual(p.next(nowUs: 10 * sec + 2, lastInputUs: nil), .off)
        _ = p.evaluate(nowUs: 10 * sec + 3, conditions: good)
        XCTAssertEqual(p.next(nowUs: 10 * sec + 4, lastInputUs: nil), .waitForCompletion)
    }

    func testFlappingConditionsDoNotBurstTaps() {
        var p = onPlanner(at: 10 * sec)
        XCTAssertEqual(p.next(nowUs: 10 * sec, lastInputUs: nil), .tap)
        p.tapFinished(nowUs: 10 * sec + 20_000, success: true)
        var off = good
        off.videoFlowing = false
        _ = p.evaluate(nowUs: 10 * sec + 100_000, conditions: off)
        _ = p.evaluate(nowUs: 10 * sec + 200_000, conditions: good)
        if case .sleep = p.next(nowUs: 10 * sec + 300_000, lastInputUs: nil) {} else { XCTFail("tap burst") }
    }

    // MARK: Real input

    func testRecentRealInputSkipsTheRound() {
        var p = onPlanner(at: 10 * sec)
        let now = 10 * sec
        let action = p.next(nowUs: now, lastInputUs: now - 1_000_000)  // 1.0 s ago: within 1.5 s
        XCTAssertEqual(action, .sleep(untilUs: now + Hold120Planner.intervalUs))
        XCTAssertEqual(p.skippedInput, 1)
        XCTAssertEqual(p.taps, 0)
        XCTAssertFalse(p.tapInFlight)
    }

    func testInputExactlyAtQuietLimitDoesNotSkip() {
        var p = onPlanner(at: 10 * sec)
        let now = 10 * sec
        XCTAssertEqual(p.next(nowUs: now, lastInputUs: now - Hold120Planner.inputQuietUs), .tap)
        XCTAssertEqual(p.skippedInput, 0)
    }

    func testOldInputDoesNotSkip() {
        var p = onPlanner(at: 10 * sec)
        XCTAssertEqual(p.next(nowUs: 10 * sec, lastInputUs: 5 * sec), .tap)
    }

    func testSkippedRoundThenTapAfterQuiet() {
        var p = onPlanner(at: 10 * sec)
        let input = 10 * sec - 100_000
        XCTAssertEqual(p.next(nowUs: 10 * sec, lastInputUs: input), .sleep(untilUs: 11 * sec))
        XCTAssertEqual(p.next(nowUs: 11 * sec, lastInputUs: input), .sleep(untilUs: 12 * sec))  // 1.1 s < 1.5 s
        XCTAssertEqual(p.next(nowUs: 12 * sec, lastInputUs: input), .tap)  // 1.9 s
        XCTAssertEqual(p.skippedInput, 2)
    }

    // MARK: Failures

    func testBackoffOneTwoFive() {
        var p = onPlanner(at: 10 * sec)
        var now = 10 * sec
        XCTAssertEqual(p.next(nowUs: now, lastInputUs: nil), .tap)
        p.tapFinished(nowUs: now, success: false)
        XCTAssertEqual(p.next(nowUs: now, lastInputUs: nil), .sleep(untilUs: now + 2 * sec))
        now += 2 * sec
        XCTAssertEqual(p.next(nowUs: now, lastInputUs: nil), .tap)
        p.tapFinished(nowUs: now, success: false)
        XCTAssertEqual(p.next(nowUs: now, lastInputUs: nil), .sleep(untilUs: now + 5 * sec))
        now += 5 * sec
        XCTAssertEqual(p.next(nowUs: now, lastInputUs: nil), .tap)
        p.tapFinished(nowUs: now, success: false)
        XCTAssertEqual(p.next(nowUs: now, lastInputUs: nil), .sleep(untilUs: now + 5 * sec))  // capped
        XCTAssertEqual(p.failures, 3)
    }

    func testSuccessResetsBackoff() {
        var p = onPlanner(at: 10 * sec)
        var now = 10 * sec
        XCTAssertEqual(p.next(nowUs: now, lastInputUs: nil), .tap)
        p.tapFinished(nowUs: now, success: false)
        now += 2 * sec
        XCTAssertEqual(p.next(nowUs: now, lastInputUs: nil), .tap)
        p.tapFinished(nowUs: now, success: true)
        XCTAssertEqual(p.next(nowUs: now, lastInputUs: nil), .sleep(untilUs: now + sec))
        now += sec
        XCTAssertEqual(p.next(nowUs: now, lastInputUs: nil), .tap)
        p.tapFinished(nowUs: now, success: false)
        XCTAssertEqual(p.next(nowUs: now, lastInputUs: nil), .sleep(untilUs: now + 2 * sec))  // back to the first step
    }

    func testFailureBackoffResetsWhenTurnedOff() {
        var p = onPlanner(at: 10 * sec)
        var now = 10 * sec
        for _ in 0..<2 {
            XCTAssertEqual(p.next(nowUs: now, lastInputUs: nil), .tap)
            p.tapFinished(nowUs: now, success: false)
            now += 5 * sec
        }
        var off = good
        off.gameScreen = false
        _ = p.evaluate(nowUs: now, conditions: off)
        _ = p.evaluate(nowUs: now + 1, conditions: good)
        XCTAssertEqual(p.next(nowUs: now + 1, lastInputUs: nil), .tap)
        p.tapFinished(nowUs: now + 1, success: false)
        XCTAssertEqual(p.next(nowUs: now + 1, lastInputUs: nil), .sleep(untilUs: now + 1 + 2 * sec))
    }

    // MARK: Stats

    func testStatsAtMostEveryThirtySecondsWhileOn() {
        var p = onPlanner(at: 100 * sec)
        XCTAssertNil(p.takeStats(nowUs: 100 * sec))
        XCTAssertNil(p.takeStats(nowUs: 129 * sec))
        XCTAssertEqual(p.next(nowUs: 100 * sec, lastInputUs: nil), .tap)
        p.tapFinished(nowUs: 100 * sec, success: false)
        XCTAssertEqual(p.next(nowUs: 102 * sec, lastInputUs: 102 * sec - 1), .sleep(untilUs: 103 * sec))
        let stats = p.takeStats(nowUs: 130 * sec)
        XCTAssertEqual(stats?.logFields, "taps=1 skipped_input=1 failures=1")
        XCTAssertNil(p.takeStats(nowUs: 131 * sec))
        XCTAssertNil(p.takeStats(nowUs: 159 * sec))
        XCTAssertNotNil(p.takeStats(nowUs: 160 * sec))
    }

    func testNoStatsWhileOff() {
        var p = Hold120Planner()
        _ = p.evaluate(nowUs: 0, conditions: .none)
        XCTAssertNil(p.takeStats(nowUs: 1_000 * sec))
    }

    // MARK: Which messages count as input

    func testOnlyTouchPenAndPointerMessagesCountAsInput() {
        let counted: Set<MessageType> = [.pen, .pointerRel, .pointerAbs, .scroll, .penGesture, .pinch, .padSwipe]
        for type in MessageType.allCases {
            XCTAssertEqual(Hold120Input.counts(type), counted.contains(type), "\(type)")
        }
        XCTAssertFalse(Hold120Input.counts(.key))
        XCTAssertFalse(Hold120Input.counts(.ping))
    }
}
