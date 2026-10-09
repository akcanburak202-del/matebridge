import XCTest
@testable import MateBridgeCore

/// T-177 (restored by T-328): the live bitrate request and the `DataRateLimits` pairs.
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
}
