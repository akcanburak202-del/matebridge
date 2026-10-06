import XCTest
@testable import MateBridgeCore

final class PipelineRetryPolicyTests: XCTestCase {
    private let s: UInt64 = 1_000_000

    func testFirstFailureRetriesAfterOneSecond() {
        var p = PipelineRetryPolicy()
        XCTAssertEqual(p.failed(kind: .other, hdr10: false, nowUs: 10 * s), .retry(delayUs: s, attempt: 1))
    }

    func testBackoffDoublesAndCaps() {
        XCTAssertEqual(PipelineRetryPolicy.delay(attempt: 1), 1 * s)
        XCTAssertEqual(PipelineRetryPolicy.delay(attempt: 2), 2 * s)
        XCTAssertEqual(PipelineRetryPolicy.delay(attempt: 3), 4 * s)
        XCTAssertEqual(PipelineRetryPolicy.delay(attempt: 4), 4 * s)
        XCTAssertEqual(PipelineRetryPolicy.delay(attempt: 100), 4 * s)
        XCTAssertEqual(PipelineRetryPolicy.delay(attempt: 0), 1 * s)
    }

    func testSdrGivesUpAfterBudgetInsideWindow() {
        var p = PipelineRetryPolicy()
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: false, nowUs: 0), .retry(delayUs: 1 * s, attempt: 1))
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: false, nowUs: 2 * s), .retry(delayUs: 2 * s, attempt: 2))
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: false, nowUs: 5 * s), .retry(delayUs: 4 * s, attempt: 3))
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: false, nowUs: 10 * s), .giveUp)
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: false, nowUs: 20 * s), .giveUp)
    }

    func testNoEndlessLoopEvenWithEveryKindOfFailure() {
        var p = PipelineRetryPolicy()
        var retries = 0
        for i in 0..<50 {
            let kind: PipelineFailureKind = i.isMultiple(of: 2) ? .encoder : .other
            if case .retry = p.failed(kind: kind, hdr10: false, nowUs: UInt64(i) * s) { retries += 1 }
        }
        XCTAssertEqual(retries, PipelineRetryPolicy.maxRetries)
    }

    func testBudgetRefillsAfterWindow() {
        var p = PipelineRetryPolicy()
        for t in 0..<3 { _ = p.failed(kind: .other, hdr10: false, nowUs: UInt64(t) * s) }
        XCTAssertEqual(p.failed(kind: .other, hdr10: false, nowUs: 3 * s), .giveUp)
        // A pipeline that ran longer than the window: fresh budget.
        let later = 3 * s + PipelineRetryPolicy.windowUs + 1
        XCTAssertEqual(p.failed(kind: .other, hdr10: false, nowUs: later), .retry(delayUs: s, attempt: 1))
        XCTAssertEqual(p.recentFailureCount, 1)
    }

    func testHdrEncoderFailureRetriesOnceThenFallsBack() {
        var p = PipelineRetryPolicy()
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: true, nowUs: 5 * s), .retry(delayUs: s, attempt: 1))
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: true, nowUs: 9 * s), .fallBackToSDR)
    }

    func testFallbackStartsFreshBudgetForSdr() {
        var p = PipelineRetryPolicy()
        _ = p.failed(kind: .encoder, hdr10: true, nowUs: 0)
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: true, nowUs: s), .fallBackToSDR)
        XCTAssertEqual(p.recentFailureCount, 0)
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: false, nowUs: 3 * s), .retry(delayUs: s, attempt: 1))
    }

    func testHdrEncoderFailureOutsideWindowIsAFirstFailureAgain() {
        var p = PipelineRetryPolicy()
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: true, nowUs: 0), .retry(delayUs: s, attempt: 1))
        let later = PipelineRetryPolicy.windowUs + s
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: true, nowUs: later), .retry(delayUs: s, attempt: 1))
    }

    func testHdrNonEncoderFailuresDoNotFallBack() {
        var p = PipelineRetryPolicy()
        XCTAssertEqual(p.failed(kind: .other, hdr10: true, nowUs: 0), .retry(delayUs: s, attempt: 1))
        XCTAssertEqual(p.failed(kind: .other, hdr10: true, nowUs: s), .retry(delayUs: 2 * s, attempt: 2))
        // An encoder failure after non-encoder ones is the first encoder failure.
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: true, nowUs: 2 * s), .retry(delayUs: 4 * s, attempt: 3))
        XCTAssertEqual(p.failed(kind: .encoder, hdr10: true, nowUs: 3 * s), .fallBackToSDR)
    }

    func testSdrEncoderFailuresNeverFallBack() {
        var p = PipelineRetryPolicy()
        for t in 0..<2 {
            if case .fallBackToSDR = p.failed(kind: .encoder, hdr10: false, nowUs: UInt64(t) * s) {
                XCTFail("SDR has nothing to fall back to")
            }
        }
    }

    func testResetGivesFreshBudget() {
        var p = PipelineRetryPolicy()
        for t in 0..<4 { _ = p.failed(kind: .other, hdr10: false, nowUs: UInt64(t) * s) }
        p.reset()
        XCTAssertEqual(p.failed(kind: .other, hdr10: false, nowUs: 5 * s), .retry(delayUs: s, attempt: 1))
    }

    func testClockGoingBackwardsDoesNotCrash() {
        var p = PipelineRetryPolicy()
        _ = p.failed(kind: .other, hdr10: false, nowUs: 100 * s)
        XCTAssertEqual(p.failed(kind: .other, hdr10: false, nowUs: 50 * s), .retry(delayUs: 2 * s, attempt: 2))
    }

    func testFailureKindRawValues() {
        XCTAssertEqual(PipelineFailureKind.encoder.rawValue, "encoder")
        XCTAssertEqual(PipelineFailureKind.other.rawValue, "other")
    }
}
