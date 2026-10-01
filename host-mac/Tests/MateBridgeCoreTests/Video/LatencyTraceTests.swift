import XCTest
@testable import MateBridgeCore

final class LatencyTraceTests: XCTestCase {
    private func trace(capture: UInt64 = 1_000, delivered: UInt64 = 1_300, submitted: UInt64 = 2_300,
                       encoded: UInt64 = 9_000, enqueued: UInt64 = 9_200, writeStart: UInt64 = 10_000,
                       writeDone: UInt64 = 11_000) -> FrameTrace {
        var t = FrameTrace()
        t.captureUs = capture; t.deliveredUs = delivered; t.submittedUs = submitted; t.encodedUs = encoded
        t.enqueuedUs = enqueued; t.writeStartUs = writeStart; t.writeDoneUs = writeDone
        return t
    }

    func testStageDifferences() {
        let t = trace()
        XCTAssertEqual(t.sckLagUs, 300)
        XCTAssertEqual(t.holdUs, 1_000)
        XCTAssertEqual(t.encUs, 6_700)
        XCTAssertEqual(t.convUs, 200)
        XCTAssertEqual(t.queueUs, 800)
        XCTAssertEqual(t.writeUs, 1_000)
        XCTAssertEqual(t.capToSentUs, 10_000)
    }

    func testCapToSentIsSumOfStages() {
        let t = trace()
        XCTAssertEqual(t.capToSentUs, t.sckLagUs + t.holdUs + t.encUs + t.convUs + t.queueUs + t.writeUs)
        XCTAssertEqual(t.capToSentUs, t.writeDoneUs - t.captureUs)
    }

    func testBackwardsStageSaturatesAtZero() {
        let t = trace(delivered: 900)  // delivered before capture timestamp
        XCTAssertEqual(t.sckLagUs, 0)
    }

    func testIncompleteTraceIsIgnored() {
        var w = LatencyWindow()
        var t = trace()
        t.writeDoneUs = 0
        w.record(t)
        XCTAssertTrue(w.isEmpty)
        XCTAssertEqual(w.logFields, "frames=0 " + LatencyWindow.stageNames.map { "\($0)_ms_p50_95_99_max=0.0/0.0/0.0/0.0" }.joined(separator: " ")
                       + " " + LatencyWindow.offsetNames.map { "\($0)_ms_p50_99=0.0/0.0" }.joined(separator: " ") + " no_display=0")
    }

    func testPercentilesAndMax() {
        var w = LatencyWindow()
        // write stage: 100 frames, 1..100 ms; everything else constant
        for i in 1...100 {
            let start: UInt64 = 10_000
            w.record(trace(writeStart: start, writeDone: start + UInt64(i) * 1_000))
        }
        XCTAssertEqual(w.frames, 100)
        let fields = w.logFields
        XCTAssertTrue(fields.hasPrefix("frames=100 sck_lag_ms_p50_95_99_max=0.3/0.3/0.3/0.3 "), fields)
        XCTAssertTrue(fields.contains(" write_ms_p50_95_99_max=50.0/95.0/99.0/100.0 "), fields)
        XCTAssertTrue(fields.contains(" enc_ms_p50_95_99_max=6.7/6.7/6.7/6.7 "), fields)
        XCTAssertTrue(fields.contains(" cap_to_sent_ms_p50_95_99_max=59.0/104.0/108.0/109.0 "), fields)
    }

    func testFieldNamesAndOrder() {
        var w = LatencyWindow()
        w.record(trace())
        let keys = w.logFields.split(separator: " ").map { $0.split(separator: "=")[0] }
        XCTAssertEqual(keys.map(String.init),
                       ["frames"] + LatencyWindow.stageNames.map { "\($0)_ms_p50_95_99_max" }
                       + LatencyWindow.offsetNames.map { "\($0)_ms_p50_99" } + ["no_display"])
    }

    func testSamplesAreBounded() {
        var w = LatencyWindow()
        for _ in 0..<(LatencyWindow.maxSamples + 50) { w.record(trace()) }
        XCTAssertEqual(w.frames, LatencyWindow.maxSamples + 50)
        XCTAssertEqual(w.samples(stage: 0).count, LatencyWindow.maxSamples)
    }

    func testMeterTakeResets() {
        let m = LatencyMeter()
        m.record(trace())
        XCTAssertEqual(m.take().frames, 1)
        XCTAssertTrue(m.take().isEmpty)
    }

    func testOriginNeverExceedsDeliveredSoTotalIsAtLeastTheStages() {
        // SCK stamps that lead the callback (as on the device) must not shorten cap_to_sent below enc.
        XCTAssertEqual(FrameTrace.origin(displayUs: 1_500, ptsUs: 1_400, deliveredUs: 1_000), 1_000)
        XCTAssertEqual(FrameTrace.origin(displayUs: 0, ptsUs: 0, deliveredUs: 1_000), 1_000)
        XCTAssertEqual(FrameTrace.origin(displayUs: 700, ptsUs: 900, deliveredUs: 1_000), 700)
        XCTAssertEqual(FrameTrace.origin(displayUs: 0, ptsUs: 900, deliveredUs: 1_000), 900)
        var t = trace(delivered: 1_000, submitted: 2_000, encoded: 9_000, enqueued: 9_200, writeStart: 10_000, writeDone: 11_000)
        t.captureUs = FrameTrace.origin(displayUs: 1_500, ptsUs: 1_400, deliveredUs: 1_000)
        XCTAssertGreaterThanOrEqual(t.capToSentUs, t.encUs)
        XCTAssertEqual(t.capToSentUs, t.sckLagUs + t.holdUs + t.encUs + t.convUs + t.queueUs + t.writeUs)
    }

    func testSckLagIsPositiveWhenStampsLagTheCallback() {
        var t = trace(delivered: 1_300)
        t.displayUs = 1_100; t.ptsUs = 1_000
        t.captureUs = FrameTrace.origin(displayUs: t.displayUs, ptsUs: t.ptsUs, deliveredUs: t.deliveredUs)
        XCTAssertEqual(t.sckLagUs, 300)
        XCTAssertEqual(t.ptsVsDisplayUs, -100)
        XCTAssertEqual(t.displayVsDeliveredUs, -200)
    }

    func testSignedOffsetsAndNoDisplayCount() {
        var w = LatencyWindow()
        var t = trace(delivered: 1_000)
        t.ptsUs = 1_600; t.displayUs = 1_200   // both stamps lead the callback
        w.record(t)
        var u = trace(delivered: 1_000)
        u.ptsUs = 1_600; u.displayUs = 0        // SCK gave no display time
        w.record(u)
        XCTAssertEqual(w.offsetSamples(0), [400])        // pts_vs_display: only frames with both
        XCTAssertEqual(w.offsetSamples(1), [600, 600])   // pts_vs_deliv
        XCTAssertEqual(w.offsetSamples(2), [200])        // display_vs_deliv
        XCTAssertEqual(w.noDisplay, 1)
        XCTAssertTrue(w.logFields.contains(" pts_vs_display_ms_p50_99=0.4/0.4 "), w.logFields)
        XCTAssertTrue(w.logFields.hasSuffix(" no_display=1"), w.logFields)
    }

    func testHoldSplitsIntoGateAndSlotWait() {
        var t = trace(delivered: 1_000, submitted: 6_000)   // hold 5 ms
        t.slotWaitUs = 3_000
        XCTAssertEqual(t.slotWaitStageUs, 3_000)
        XCTAssertEqual(t.gateWaitUs, 2_000)
        XCTAssertEqual(t.gateWaitUs + t.slotWaitStageUs, t.holdUs)
        t.slotWaitUs = 9_000   // cannot exceed the hold
        XCTAssertEqual(t.slotWaitStageUs, 5_000)
        XCTAssertEqual(t.gateWaitUs, 0)
    }

    func testMachTicksConversion() {
        // Apple Silicon timebase 125/3: 24 ticks = 1 us.
        XCTAssertEqual(MachTime.ticksToUs(24, numer: 125, denom: 3), 1)
        XCTAssertEqual(MachTime.ticksToUs(24_000_000, numer: 125, denom: 3), 1_000_000)
        // Intel timebase 1/1: ticks are ns.
        XCTAssertEqual(MachTime.ticksToUs(5_000_000, numer: 1, denom: 1), 5_000)
        // Large uptime (~100 days of ticks) does not overflow the intermediate product.
        let ticks: UInt64 = 24_000_000 * 86_400 * 100
        XCTAssertEqual(MachTime.ticksToUs(ticks, numer: 125, denom: 3), 86_400 * 100 * 1_000_000)
        XCTAssertEqual(MachTime.ticksToUs(1, numer: 1, denom: 0), 0)
    }

    func testCsvLine() {
        XCTAssertEqual(trace().csvLine, "1000,1300,2300,9000,9200,10000,11000")
        XCTAssertEqual(FrameTrace.csvHeader.split(separator: ",").count, 7)
    }
}
