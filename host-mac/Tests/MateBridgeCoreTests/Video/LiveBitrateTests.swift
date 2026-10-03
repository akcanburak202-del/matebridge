import XCTest
@testable import MateBridgeCore

/// T-177: the live bitrate request, the `DataRateLimits` pairs and the debug knobs.
final class LiveBitrateTests: XCTestCase {
    // MARK: - BitrateRequest

    func testRequestClampsToRange() {
        var r = BitrateRequest(initialKbps: 30_000, range: 10_000...80_000)
        XCTAssertEqual(r.request(1), .apply(10_000))
        XCTAssertEqual(r.request(999_999), .apply(80_000))
        XCTAssertEqual(r.request(-5), .apply(10_000))
        XCTAssertEqual(r.currentKbps, 10_000)
    }

    func testDefaultRangeIsTheUserBitrateRange() {
        var r = BitrateRequest(initialKbps: 60_000)
        XCTAssertEqual(r.range, 5_000...150_000)
        XCTAssertEqual(r.request(1_000), .apply(5_000))
        XCTAssertEqual(r.request(500_000), .apply(150_000))
    }

    func testEqualConsecutiveValuesAreDeduplicated() {
        var r = BitrateRequest(initialKbps: 60_000)
        XCTAssertEqual(r.request(60_000), .unchanged, "the configured value is in force from the start")
        XCTAssertEqual(r.request(15_000), .apply(15_000))
        XCTAssertEqual(r.request(15_000), .unchanged)
        XCTAssertEqual(r.request(60_000), .apply(60_000))
        // Two requests that clamp to the same value are one change.
        XCTAssertEqual(r.request(200_000), .apply(150_000))
        XCTAssertEqual(r.request(300_000), .unchanged)
    }

    func testRequestAfterStopIsRejected() {
        var r = BitrateRequest(initialKbps: 60_000)
        XCTAssertEqual(r.request(20_000), .apply(20_000))
        r.stop()
        XCTAssertTrue(r.isStopped)
        XCTAssertEqual(r.request(30_000), .stopped)
        XCTAssertEqual(r.request(20_000), .stopped)
        XCTAssertEqual(r.currentKbps, 20_000, "a refused request changes nothing")
    }

    // MARK: - RateLimitWindows

    func testDefaultDataRateLimitsAreUnchanged() {
        // Before T-177: [kbps * 1000 / 8 * 2, 1].
        XCTAssertEqual(RateLimitWindows.pairs(kbps: 60_000, shortWindowMs: nil),
                       [.init(bytes: 15_000_000, windowMs: 1000)])
        XCTAssertEqual(RateLimitWindows.pairs(kbps: 15_000, shortWindowMs: nil),
                       [.init(bytes: 3_750_000, windowMs: 1000)])
    }

    func testShortWindowAddsASecondPairWithTheSameBurstFactor() {
        XCTAssertEqual(RateLimitWindows.pairs(kbps: 60_000, shortWindowMs: 100),
                       [.init(bytes: 15_000_000, windowMs: 1000), .init(bytes: 1_500_000, windowMs: 100)])
        // Out-of-range windows add nothing.
        XCTAssertEqual(RateLimitWindows.pairs(kbps: 60_000, shortWindowMs: 0).count, 1)
        XCTAssertEqual(RateLimitWindows.pairs(kbps: 60_000, shortWindowMs: 1000).count, 1)
    }

    // MARK: - Knobs

    func testDefaultsAreOffAndLogLineUnchanged() {
        let k = EncoderKnobs.parse([:])
        XCTAssertNil(k.bitrateStep)
        XCTAssertNil(k.rateWindowMs)
        XCTAssertEqual(k, EncoderKnobs())
        XCTAssertEqual(k.logFields, "prio_speed=1 quality=unset idle_refresh=off input_retag=1")
    }

    func testStepKnobParsesTheValidForm() {
        let s = BitrateStepKnob.parse("60000,15000,60000@5s")
        XCTAssertEqual(s, BitrateStepKnob(valuesKbps: [60_000, 15_000, 60_000], periodMs: 5_000))
        XCTAssertEqual(BitrateStepKnob.parse(" 20000 , 40000 @ 1500ms "),
                       BitrateStepKnob(valuesKbps: [20_000, 40_000], periodMs: 1_500))
        XCTAssertEqual(BitrateStepKnob.parse("15000@100MS")?.periodMs, 100)
        XCTAssertEqual(BitrateStepKnob.parse("150000,5000@600s")?.periodMs, 600_000)
        XCTAssertEqual(s?.logValue, "60000,15000,60000@5000ms")
    }

    func testStepKnobAbsentOrInvalidIsOff() {
        for text in [nil, "", " ", "60000", "60000@", "@5s", "60000,15000", "60000@5", "60000@5m", "60000@0s",
                     "60000@99ms", "60000@601s", "60000@-5s", "4999@5s", "150001@5s", "abc@5s", "60000,,15000@5s",
                     "60000,15000@5s@1s", "60000;15000@5s", "6e4@5s", "60000@99999999999999999999s",
                     Array(repeating: "20000", count: 17).joined(separator: ",") + "@5s"] {
            XCTAssertNil(BitrateStepKnob.parse(text), "\(text ?? "nil")")
        }
        XCTAssertNotNil(BitrateStepKnob.parse(Array(repeating: "20000", count: 16).joined(separator: ",") + "@5s"))
    }

    func testStepKnobCyclesThroughItsValues() {
        let s = BitrateStepKnob(valuesKbps: [60_000, 15_000, 30_000], periodMs: 1_000)
        XCTAssertEqual((0..<7).map { s.value(atTick: $0) },
                       [60_000, 15_000, 30_000, 60_000, 15_000, 30_000, 60_000])
    }

    func testEncoderKnobsReadBothT177Variables() {
        let k = EncoderKnobs.parse(["MATEBRIDGE_BITRATE_STEP": "60000,15000@5s", "MATEBRIDGE_RATE_WINDOW_MS": "100"])
        XCTAssertEqual(k.bitrateStep, BitrateStepKnob(valuesKbps: [60_000, 15_000], periodMs: 5_000))
        XCTAssertEqual(k.rateWindowMs, 100)
        XCTAssertEqual(k.logFields, "prio_speed=1 quality=unset idle_refresh=off input_retag=1 "
                       + "bitrate_step=60000,15000@5000ms rate_window_ms=100")
    }

    func testRateWindowOutOfRangeIsOff() {
        for v in ["0", "9", "1000", "-100", "x", " "] {
            XCTAssertNil(EncoderKnobs.parse(["MATEBRIDGE_RATE_WINDOW_MS": v]).rateWindowMs, v)
        }
        XCTAssertEqual(EncoderKnobs.parse(["MATEBRIDGE_RATE_WINDOW_MS": "10"]).rateWindowMs, 10)
        XCTAssertEqual(EncoderKnobs.parse(["MATEBRIDGE_RATE_WINDOW_MS": "999"]).rateWindowMs, 999)
    }
}
