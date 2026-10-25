import XCTest
@testable import MateBridgeCore

private typealias C = WifiAdaptV2Controller

/// Drives a controller with 100 ms ticks.
private struct Rig {
    var c: C
    var now: UInt64 = 10_000_000
    var steps: [(atUs: UInt64, step: C.Step)] = []

    init(ceilingKbps: Int = 60_000, warm: Bool = true) {
        c = C(ceilingKbps: ceilingKbps)
        if warm { quiet(ticks: 30) }
    }

    @discardableResult
    mutating func tick(srtt: UInt32 = 6, sb: UInt32 = 0, tx: UInt64 = 20, retx: UInt64 = 0,
                       stall: Bool = false, active: UInt32 = 0, ended: UInt32 = 0) -> C.Outcome {
        now += 100_000
        let o = c.tick(.init(nowUs: now, srttMs: srtt, sendBufferBytes: sb, txPacketsDelta: tx,
                             retransmitPacketsDelta: retx, stallStarted: stall, stallActiveMs: active, stallEndedMs: ended))
        if let s = o.step { steps.append((now, s)) }
        return o
    }

    mutating func quiet(ticks: Int, srtt: UInt32 = 6, sb: UInt32 = 0) {
        for _ in 0..<ticks { tick(srtt: srtt, sb: sb) }
    }

    /// A stall event at this tick (the detector reports it once, then the stall stays active until it ends).
    mutating func stallEvent() { tick(stall: true, active: 200) }

    var lastStep: C.Step? { steps.last?.step }
    var downSteps: Int { steps.filter { $0.step.toKbps < $0.step.fromKbps }.count }
}

final class WifiAdaptV2Tests: XCTestCase {
    // MARK: Knob

    func testKnobIsOffUnlessExactlyOne() {
        XCTAssertFalse(WifiAdaptKnob.isEnabled([:]))
        for v in ["", "0", "true", "on", "yes", "2", "01", "-1"] {
            XCTAssertFalse(WifiAdaptKnob.isEnabled([WifiAdaptKnob.name: v]), v)
        }
        XCTAssertTrue(WifiAdaptKnob.isEnabled([WifiAdaptKnob.name: "1"]))
        XCTAssertTrue(WifiAdaptKnob.isEnabled([WifiAdaptKnob.name: " 1 "]))
        XCTAssertFalse(WifiAdaptKnob.isEnabled(["OTHER": "1"]))
    }

    func testKnobIsNeverActiveOnUsb() {
        let on = [WifiAdaptKnob.name: "1"]
        XCTAssertTrue(WifiAdaptKnob.isActive(on, transport: .network))
        XCTAssertFalse(WifiAdaptKnob.isActive(on, transport: .usb))
        XCTAssertFalse(WifiAdaptKnob.isActive([:], transport: .network))
        XCTAssertFalse(WifiAdaptKnob.isActive([:], transport: .usb))
    }

    // MARK: Baseline

    func testBaselineNeedsEnoughDrainedSamplesAndIgnoresQueuedOnes() {
        var b = RttBaseline()
        for i in 0..<19 { b.add(nowUs: UInt64(i) * 100_000, srttMs: 6, drained: true) }
        XCTAssertNil(b.baselineMs, "19 samples are too few")
        b.add(nowUs: 1_900_000, srttMs: 6, drained: true)
        XCTAssertEqual(b.baselineMs, 6)
        for i in 20..<120 { b.add(nowUs: UInt64(i) * 100_000, srttMs: 80, drained: false) }
        XCTAssertEqual(b.baselineMs, 6, "a standing queue is never learned as baseline")
    }

    func testBaselineIsALowPercentileOverThirtySeconds() {
        var b = RttBaseline()
        var t: UInt64 = 0
        for i in 0..<100 {
            t += 100_000
            b.add(nowUs: t, srttMs: i < 10 ? 5 : 10, drained: true)
        }
        XCTAssertEqual(b.baselineMs, 5, "the 10th percentile of 10 x 5 and 90 x 10")
        for _ in 0..<310 {
            t += 100_000
            b.add(nowUs: t, srttMs: 12, drained: true)
        }
        XCTAssertEqual(b.baselineMs, 12, "old samples left the 30 s window")
    }

    // MARK: Stall detector (the sampling-phase sweeps are in WriteGapMeterTests)

    func testDetectorReportsOneEventPerOpenWriterStall() {
        var d = SendStallDetector()
        func obs(gapMs: UInt64) -> SendStallDetector.Result {
            d.observe(.init(writerBusy: true, writerOpenGapUs: gapMs * 1_000, sinceProgressUs: gapMs * 1_000))
        }
        XCTAssertEqual(obs(gapMs: 50), .init(newEvent: false, activeUs: 0))
        XCTAssertFalse(obs(gapMs: 149).newEvent)
        let first = obs(gapMs: 250)
        XCTAssertTrue(first.newEvent)
        XCTAssertEqual(first.activeUs, 250_000)
        let next = obs(gapMs: 350)
        XCTAssertFalse(next.newEvent, "the same stall is not a second event")
        XCTAssertEqual(next.activeUs, 350_000)
        XCTAssertEqual(obs(gapMs: 10), .init(newEvent: false, activeUs: 0), "progress ends it")
        XCTAssertTrue(obs(gapMs: 200).newEvent, "a later stall is a new event")
    }

    func testStallThatEndedBetweenPollsIsCountedOnceAndNotTwiceWhenSeenOpen() {
        var d = SendStallDetector()
        // Ended unseen.
        let r = d.observe(.init(writerLongGapsEnded: 1, writerLastLongGapUs: 220_000))
        XCTAssertTrue(r.newEvent)
        XCTAssertEqual(r.endedUs, 220_000)
        // Seen open, then ended: one event.
        XCTAssertTrue(d.observe(.init(writerBusy: true, writerOpenGapUs: 200_000, writerLongGapsEnded: 1)).newEvent)
        let end = d.observe(.init(writerLongGapsEnded: 2, writerLastLongGapUs: 320_000))
        XCTAssertFalse(end.newEvent)
        XCTAssertEqual(end.endedUs, 320_000)
    }

    func testNoWorkIsNeverAStall() {
        var d = SendStallDetector()
        for _ in 0..<20 {
            XCTAssertEqual(d.observe(.init(sinceProgressUs: 5_000_000)), .init(newEvent: false, activeUs: 0))
        }
    }

    func testQueueHeadAgeWithoutProgressIsAStallOnlyWhenNothingIsBeingWritten() {
        var d = SendStallDetector()
        XCTAssertFalse(d.observe(.init(sinceProgressUs: 400_000, headAgeUs: 100_000)).newEvent, "head is young")
        XCTAssertFalse(d.observe(.init(sinceProgressUs: 100_000, headAgeUs: 400_000)).newEvent, "bytes moved 100 ms ago")
        XCTAssertTrue(d.observe(.init(sinceProgressUs: 160_000, headAgeUs: 400_000)).newEvent)
        XCTAssertFalse(d.observe(.init(sinceProgressUs: 260_000, headAgeUs: 500_000)).newEvent)
        // A record being written is the writer's business.
        var e = SendStallDetector()
        XCTAssertFalse(e.observe(.init(writerBusy: true, writerOpenGapUs: 50_000, sinceProgressUs: 900_000,
                                       headAgeUs: 900_000)).newEvent)
    }

    // MARK: Controller, S

    func testTwoStallsWithinTwoSecondsLowerByHeavyFactor() {
        var r = Rig()
        r.stallEvent()
        r.quiet(ticks: 9)
        XCTAssertTrue(r.steps.isEmpty, "one S alone does not lower")
        r.stallEvent()
        XCTAssertEqual(r.lastStep, .init(fromKbps: 60_000, toKbps: 42_000, reason: .severe, evidence: .stall))
        XCTAssertEqual(r.lastStep?.evidence.logValue, "S")
    }

    func testStallsMoreThanTwoSecondsApartNeverLower() {
        var r = Rig()
        for _ in 0..<5 {
            r.stallEvent()
            r.quiet(ticks: 25)
        }
        XCTAssertTrue(r.steps.isEmpty)
    }

    func testSingleLongStallLowersOnceAndIsNotCountedAgain() {
        var r = Rig()
        r.tick(stall: true, active: 200)
        r.tick(active: 300)
        r.tick(active: 400)
        XCTAssertTrue(r.steps.isEmpty)
        r.tick(active: 500)
        XCTAssertEqual(r.lastStep?.toKbps, 42_000)
        for ms in stride(from: 600, through: 3_000, by: 100) { r.tick(active: UInt32(ms)) }
        XCTAssertEqual(r.downSteps, 1, "the same stall is one piece of evidence")
    }

    func testEveryStepNeedsFreshEvidence() {
        var r = Rig()
        r.stallEvent(); r.quiet(ticks: 4); r.stallEvent()
        XCTAssertEqual(r.downSteps, 1)
        // One more event alone, after the minimum interval: nothing.
        r.quiet(ticks: 6)
        r.stallEvent()
        XCTAssertEqual(r.downSteps, 1)
        // A second fresh one pairs with it.
        r.quiet(ticks: 5)
        r.stallEvent()
        XCTAssertEqual(r.downSteps, 2)
        XCTAssertEqual(r.lastStep?.toKbps, 30_000, "42 x 0.7 = 29.4, held at the 30 Mbps floor")
    }

    func testHeavyStepsAreAtLeastHalfASecondApart() {
        var r = Rig()
        r.stallEvent(); r.stallEvent()  // step at t
        XCTAssertEqual(r.downSteps, 1)
        let at = r.steps[0].atUs
        r.stallEvent(); r.stallEvent()  // fresh pair 100-200 ms later: too soon
        XCTAssertEqual(r.downSteps, 1)
        while r.now - at < 500_000 { r.quiet(ticks: 1) }
        r.stallEvent()  // the pair is still inside its 2 s window; the next event is evidence again
        XCTAssertEqual(r.downSteps, 2)
        XCTAssertGreaterThanOrEqual(r.steps[1].atUs - at, 500_000)
    }

    // MARK: Controller, D / L / B

    func testDelayWithBacklogIsModerate() {
        var r = Rig()
        for _ in 0..<3 { r.tick(srtt: 30, sb: 200_000) }
        XCTAssertTrue(r.steps.isEmpty, "the backlog needs 300 ms")
        r.tick(srtt: 30, sb: 200_000)
        XCTAssertEqual(r.lastStep, .init(fromKbps: 60_000, toKbps: 51_000, reason: .moderate, evidence: [.delay, .backlog]))
        XCTAssertEqual(r.lastStep?.evidence.logValue, "D,B")
    }

    func testDelayWithoutBacklogNeverLowers() {
        var r = Rig()
        for _ in 0..<100 { r.tick(srtt: 60, sb: 0) }  // the v1 collapse shape: repeated srtt excess, nothing queued
        XCTAssertTrue(r.steps.isEmpty)
    }

    func testBacklogWithoutDelayNeverLowers() {
        var r = Rig()
        for _ in 0..<100 { r.tick(srtt: 7, sb: 400_000) }
        XCTAssertTrue(r.steps.isEmpty)
    }

    func testBacklogThatFallsIsNotBacklog() {
        var r = Rig()
        for i in 0..<60 { r.tick(srtt: 40, sb: UInt32(3_000_000 - i * 45_000)) }
        XCTAssertTrue(r.steps.isEmpty, "a buffer that keeps draining is no standing queue")
    }

    func testSingleSrttSpikeNeverLowers() {
        var r = Rig()
        r.tick(srtt: 120, sb: 200_000)
        for _ in 0..<50 { r.tick(srtt: 7, sb: 0) }
        XCTAssertTrue(r.steps.isEmpty)
    }

    func testLossWithBacklogIsModerateLossAloneIsNot() {
        var r = Rig()
        for _ in 0..<30 { r.tick(srtt: 7, sb: 0, tx: 20, retx: 2) }  // 10 %, and plenty of packets
        XCTAssertTrue(r.steps.isEmpty, "L alone")
        for _ in 0..<5 { r.tick(srtt: 7, sb: 200_000, tx: 20, retx: 2) }
        XCTAssertEqual(r.lastStep?.reason, .moderate)
        XCTAssertEqual(r.lastStep?.evidence.logValue, "L,B")
    }

    func testFewRetransmitsOrLowRatioAreNotLoss() {
        var r = Rig()
        for i in 0..<100 { r.tick(srtt: 7, sb: 200_000, tx: 200, retx: i % 10 == 0 ? 3 : 0) }  // 3 per second
        for i in 0..<100 { r.tick(srtt: 7, sb: 200_000, tx: 2_000, retx: i % 2 == 0 ? 4 : 0) }  // 20 per second, 0.5 %
        XCTAssertTrue(r.steps.isEmpty)
    }

    func testHeavyDelayWithBacklog() {
        var r = Rig()
        for _ in 0..<4 { r.tick(srtt: 60, sb: 200_000) }
        XCTAssertEqual(r.lastStep, .init(fromKbps: 60_000, toKbps: 42_000, reason: .severe, evidence: [.delay, .backlog]))
    }

    func testModerateStepsAreThreeQuartersOfASecondApart() {
        var r = Rig()
        for _ in 0..<4 { r.tick(srtt: 30, sb: 200_000) }
        XCTAssertEqual(r.downSteps, 1)
        let at = r.steps[0].atUs
        while r.downSteps < 2 && r.now - at < 3_000_000 { r.tick(srtt: 30, sb: 200_000) }
        XCTAssertEqual(r.downSteps, 2)
        XCTAssertGreaterThanOrEqual(r.steps[1].atUs - at, 750_000)
    }

    func testStepClearsTheDelayHistory() {
        var r = Rig()
        for _ in 0..<4 { r.tick(srtt: 30, sb: 200_000) }
        XCTAssertEqual(r.downSteps, 1)
        for _ in 0..<3 { r.tick(srtt: 30, sb: 200_000) }
        XCTAssertEqual(r.downSteps, 1, "three fresh samples are not enough, the old ones are spent")
    }

    func testStallRightAfterANonStallStepIsNotConsumed() {
        var r = Rig()
        for _ in 0..<4 { r.tick(srtt: 30, sb: 200_000) }  // moderate step, no stall involved
        XCTAssertEqual(r.lastStep?.reason, .moderate)
        // A stall starts at once and runs: no tick with stallActiveMs == 0 in between.
        r.tick(stall: true, active: 200)
        for ms in stride(from: 300, through: 700, by: 100) { r.tick(active: UInt32(ms)) }
        XCTAssertEqual(r.lastStep?.reason, .severe, "a 500 ms stall is heavy on its own")
        XCTAssertEqual(r.downSteps, 2)
    }

    func testStallRunningAtAStepIsConsumedAndANewOneIsFresh() {
        var r = Rig()
        r.tick(stall: true, active: 200)
        r.tick(active: 300); r.tick(active: 400); r.tick(active: 500)
        XCTAssertEqual(r.downSteps, 1)
        for ms in stride(from: 600, through: 2_000, by: 100) { r.tick(active: UInt32(ms)) }
        XCTAssertEqual(r.downSteps, 1, "consumed")
        // A new stall starts right away, with no idle tick between: it is fresh.
        r.tick(stall: true, active: 200)
        for ms in stride(from: 300, through: 500, by: 100) { r.tick(active: UInt32(ms)) }
        XCTAssertEqual(r.downSteps, 2)
    }

    func testStallThatEndedBetweenSamplesCountsByItsLength() {
        var r = Rig()
        r.tick(stall: true, active: 0, ended: 600)
        XCTAssertEqual(r.lastStep?.toKbps, 42_000)
    }

    // MARK: Hold and recovery

    func testSingleSignalsOnlyHoldTheClimb() {
        var r = Rig()
        r.stallEvent(); r.stallEvent()  // 60 -> 42
        let at = r.now
        // Clean for 3 s: the first climb comes after the 3 s hold.
        while r.steps.count < 2 && r.now - at < 10_000_000 { r.quiet(ticks: 1) }
        XCTAssertEqual(r.steps[1].step.reason, .recover)
        XCTAssertGreaterThanOrEqual(r.steps[1].atUs - at, 3_000_000)
        XCTAssertEqual(r.steps[1].step.toKbps, 44_000)
        // A lone stall now delays the next climb by 2 s from the signal.
        r.stallEvent()
        let signalAt = r.now
        while r.steps.count < 3 && r.now - signalAt < 10_000_000 { r.quiet(ticks: 1) }
        XCTAssertGreaterThanOrEqual(r.steps[2].atUs - signalAt, 2_000_000)
        XCTAssertEqual(r.downSteps, 1)
    }

    func testRecoversTwoMbpsPerSecondToTheCeilingWithoutJumping() {
        var r = Rig()
        r.stallEvent(); r.stallEvent()
        let ups = { r.steps.filter { $0.step.reason == .recover } }
        var guardTicks = 0
        while r.c.targetKbps < 60_000 && guardTicks < 400 { r.quiet(ticks: 1); guardTicks += 1 }
        XCTAssertEqual(r.c.targetKbps, 60_000)
        XCTAssertEqual(ups().count, 9, "42 -> 60 in nine steps of 2 Mbps")
        for (a, b) in zip(ups(), ups().dropFirst()) {
            XCTAssertEqual(b.step.toKbps - a.step.toKbps, 2_000)
            XCTAssertGreaterThanOrEqual(b.atUs - a.atUs, 1_000_000)
        }
        XCTAssertNil(r.c.tick(.init(nowUs: r.now + 1_000_000, srttMs: 6, sendBufferBytes: 0, txPacketsDelta: 20,
                                    retransmitPacketsDelta: 0)).step, "at the ceiling nothing changes")
    }

    // MARK: Floors

    func testNeverBelowThirtyOnFirstEventAndEmergencyNeedsTwoMoreSeconds() {
        var r = Rig()
        r.stallEvent(); r.stallEvent()                      // 60 -> 42
        r.quiet(ticks: 6)
        r.stallEvent(); r.stallEvent()                      // 42 -> 30 (floor)
        XCTAssertEqual(r.c.targetKbps, 30_000)
        let floorAt = r.now
        // More heavy evidence at once and within 2 s: held at 30.
        for _ in 0..<4 { r.quiet(ticks: 4); r.stallEvent() }
        XCTAssertLessThan(r.now - floorAt, 2_500_000)
        XCTAssertGreaterThanOrEqual(r.c.targetKbps, 30_000)
        // Heavy evidence goes on for 2 s: 20 Mbps, once.
        for _ in 0..<6 { r.quiet(ticks: 4); r.stallEvent() }
        XCTAssertEqual(r.c.targetKbps, 20_000)
        XCTAssertEqual(r.lastStep?.reason, .emergency)
        for _ in 0..<10 { r.quiet(ticks: 4); r.stallEvent() }
        XCTAssertEqual(r.c.targetKbps, 20_000, "never below the emergency floor")
    }

    func testHeavyEvidenceThatStopsLeavesTheFloorAtThirty() {
        var r = Rig()
        r.stallEvent(); r.stallEvent(); r.quiet(ticks: 6); r.stallEvent(); r.stallEvent()
        XCTAssertEqual(r.c.targetKbps, 30_000)
        r.quiet(ticks: 50)
        XCTAssertGreaterThan(r.c.targetKbps, 30_000, "recovering")
        XCTAssertFalse(r.steps.contains { $0.step.reason == .emergency })
    }

    func testCeilingBelowTheFloorIsNeverControlled() {
        var r = Rig(ceilingKbps: 24_000)
        for _ in 0..<5 { r.stallEvent(); r.stallEvent(); r.quiet(ticks: 8) }
        for _ in 0..<5 { r.tick(srtt: 60, sb: 400_000) }
        XCTAssertTrue(r.steps.isEmpty)
        XCTAssertEqual(r.c.targetKbps, 24_000)
        XCTAssertEqual(r.c.floorKbps, 24_000)
    }

    // MARK: Ceiling and connection

    func testLoweredCeilingIsObeyedAtOnce() {
        var c = C(ceilingKbps: 60_000)
        XCTAssertEqual(c.setCeiling(40_000), .init(fromKbps: 60_000, toKbps: 40_000, reason: .ceiling, evidence: []))
        XCTAssertEqual(c.targetKbps, 40_000)
        XCTAssertEqual(c.setCeiling(20_000)?.toKbps, 20_000, "below the 30 Mbps floor the ceiling is the floor")
        XCTAssertNil(c.setCeiling(20_000))
    }

    func testRaisedCeilingMovesAControllerThatSatAtTheOldOne() {
        var c = C(ceilingKbps: 40_000)
        XCTAssertEqual(c.setCeiling(60_000)?.toKbps, 60_000)
    }

    func testRaisedCeilingKeepsACongestedRateAndClimbs() {
        var r = Rig()
        r.stallEvent(); r.stallEvent()
        XCTAssertEqual(r.c.targetKbps, 42_000)
        XCTAssertNil(r.c.setCeiling(80_000))
        XCTAssertEqual(r.c.targetKbps, 42_000)
        while r.c.targetKbps < 44_000 { r.quiet(ticks: 1) }
        XCTAssertEqual(r.c.ceilingKbps, 80_000)
    }

    func testConnectionChangeForgetsBaselineAndEvidence() {
        var r = Rig()
        XCTAssertEqual(r.c.baselineMs, 6)
        r.stallEvent()
        r.c.connectionChanged()
        XCTAssertNil(r.c.baselineMs)
        r.stallEvent()
        XCTAssertTrue(r.steps.isEmpty, "the stall before the change is not counted")
        // Without a baseline D cannot fire: a new network starts by learning, not by reacting.
        for _ in 0..<15 { r.tick(srtt: 60, sb: 200_000) }
        XCTAssertTrue(r.steps.isEmpty)
        for _ in 0..<20 { r.tick(srtt: 60, sb: 0) }
        XCTAssertEqual(r.c.baselineMs, 60)
    }

    func testEvidenceLogValue() {
        XCTAssertEqual(C.Evidence([]).logValue, "-")
        XCTAssertEqual(C.Evidence([.backlog, .stall, .loss]).logValue, "S,L,B")
    }
}
