import XCTest
@testable import MateBridgeCore

final class DisplayWakePolicyTests: XCTestCase {
    private let s: UInt64 = 1_000_000

    func testClassifiesOnlyNoCaptureSource() {
        XCTAssertEqual(DisplayWakeReason.fromScreenCaptureError(code: -3815), .captureSourceLost)
        XCTAssertNil(DisplayWakeReason.fromScreenCaptureError(code: -3801))  // user declined
        XCTAssertNil(DisplayWakeReason.fromScreenCaptureError(code: -3811))  // internal error
        XCTAssertNil(DisplayWakeReason.fromScreenCaptureError(code: 0))
    }

    func testNoSessionNeverWakes() {
        var p = DisplayWakePolicy()
        XCTAssertEqual(p.displayLost(.captureSourceLost, sessionActive: false, now: 10 * s), .skip)
        XCTAssertEqual(p.displayLost(.displayCreateNil, sessionActive: false, now: 20 * s), .skip)
        XCTAssertEqual(p.wakes, 0)
    }

    func testUnrecognisedCauseNeverWakes() {
        var p = DisplayWakePolicy()
        XCTAssertEqual(p.displayLost(nil, sessionActive: true, now: 10 * s), .skip)
        XCTAssertEqual(p.wakes, 0)
    }

    func testFirstLossWakesAndLogs() {
        var p = DisplayWakePolicy()
        XCTAssertEqual(p.displayLost(.captureSourceLost, sessionActive: true, now: 10 * s), .wake(log: true, wakes: 1))
    }

    func testAtMostOneWakePerSecond() {
        var p = DisplayWakePolicy()
        // Retries every 0.6 s (the measured cadence of failed display creation).
        var woke: [UInt64] = []
        var t: UInt64 = 10 * s
        for _ in 0..<20 {
            if case .wake = p.displayLost(.displayCreateNil, sessionActive: true, now: t) { woke.append(t) }
            t += 600_000
        }
        XCTAssertEqual(woke.count, 10)
        for (a, b) in zip(woke, woke.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, s) }
    }

    func testSkippedLossDoesNotRestartTheInterval() {
        var p = DisplayWakePolicy()
        XCTAssertNotEqual(p.displayLost(.displayCreateNil, sessionActive: true, now: 10 * s), .skip)
        XCTAssertEqual(p.displayLost(.displayCreateNil, sessionActive: true, now: 10 * s + 900_000), .skip)
        XCTAssertNotEqual(p.displayLost(.displayCreateNil, sessionActive: true, now: 11 * s), .skip)
    }

    func testLogIsRateLimitedWithinAnEpisode() {
        var p = DisplayWakePolicy()
        XCTAssertEqual(p.displayLost(.displayCreateNil, sessionActive: true, now: 10 * s), .wake(log: true, wakes: 1))
        XCTAssertEqual(p.displayLost(.displayCreateNil, sessionActive: true, now: 11 * s), .wake(log: false, wakes: 2))
        XCTAssertEqual(p.displayLost(.displayCreateNil, sessionActive: true, now: 15 * s), .wake(log: false, wakes: 3))
        // 10 s after the last log line: log again with the count.
        XCTAssertEqual(p.displayLost(.displayCreateNil, sessionActive: true, now: 20 * s), .wake(log: true, wakes: 4))
    }

    func testReasonChangeLogs() {
        var p = DisplayWakePolicy()
        XCTAssertEqual(p.displayLost(.captureSourceLost, sessionActive: true, now: 10 * s), .wake(log: true, wakes: 1))
        XCTAssertEqual(p.displayLost(.displayCreateNil, sessionActive: true, now: 11 * s), .wake(log: true, wakes: 2))
        XCTAssertEqual(p.displayLost(.displayCreateNil, sessionActive: true, now: 12 * s), .wake(log: false, wakes: 3))
    }

    func testRecoveryStartsNewEpisodeButKeepsRateLimit() {
        var p = DisplayWakePolicy()
        _ = p.displayLost(.captureSourceLost, sessionActive: true, now: 10 * s)
        _ = p.displayLost(.displayCreateNil, sessionActive: true, now: 11 * s)
        p.recovered()
        XCTAssertEqual(p.wakes, 0)
        // A display that dies again right after recovering does not wake faster than once per second.
        XCTAssertEqual(p.displayLost(.captureSourceLost, sessionActive: true, now: 11 * s + 500_000), .skip)
        XCTAssertEqual(p.displayLost(.captureSourceLost, sessionActive: true, now: 12 * s), .wake(log: true, wakes: 1))
    }

    func testSessionEndEndsEpisodeAndKeepsRateLimit() {
        var p = DisplayWakePolicy()
        _ = p.displayLost(.captureSourceLost, sessionActive: true, now: 10 * s)
        _ = p.displayLost(.captureSourceLost, sessionActive: true, now: 11 * s)
        p.sessionEnded()
        XCTAssertEqual(p.wakes, 0)
        // After the session is gone nothing wakes, whatever the cause.
        XCTAssertEqual(p.displayLost(.captureSourceLost, sessionActive: false, now: 13 * s), .skip)
        // A new session right away still respects the interval since the last real wake.
        XCTAssertEqual(p.displayLost(.displayCreateNil, sessionActive: true, now: 11 * s + 500_000), .skip)
        XCTAssertEqual(p.displayLost(.displayCreateNil, sessionActive: true, now: 14 * s), .wake(log: true, wakes: 1))
    }
}
