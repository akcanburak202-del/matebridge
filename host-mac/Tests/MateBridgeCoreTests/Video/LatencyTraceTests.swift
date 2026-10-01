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
        XCTAssertEqual(w.logFields, "frames=0 " + LatencyWindow.stageNames.map { "\($0)_ms_p50_95_99_max=0.0/0.0/0.0/0.0" }.joined(separator: " "))
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
        XCTAssertTrue(fields.hasSuffix("cap_to_sent_ms_p50_95_99_max=59.0/104.0/108.0/109.0"), fields)
    }

    func testFieldNamesAndOrder() {
        var w = LatencyWindow()
        w.record(trace())
        let keys = w.logFields.split(separator: " ").map { $0.split(separator: "=")[0] }
        XCTAssertEqual(keys.map(String.init),
                       ["frames"] + LatencyWindow.stageNames.map { "\($0)_ms_p50_95_99_max" })
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

    func testCsvLine() {
        XCTAssertEqual(trace().csvLine, "1000,1300,2300,9000,9200,10000,11000")
        XCTAssertEqual(FrameTrace.csvHeader.split(separator: ",").count, 7)
    }
}
