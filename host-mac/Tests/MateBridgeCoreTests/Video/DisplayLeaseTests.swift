import XCTest
@testable import MateBridgeCore

/// `MATEBRIDGE_DISPLAY_KEEP_S` (T-165). The lease state machine itself is tested in `DisplayLeaseTests`
/// (IntegrationTests.swift).
final class DisplayParkTests: XCTestCase {
    func testDefaultIsTenSeconds() {
        XCTAssertEqual(DisplayLease.defaultKeepSeconds, 10)
        XCTAssertEqual(DisplayLease.defaultGraceUs, 10_000_000, "the default keep time is unchanged")
        XCTAssertEqual(DisplayLease.keepUs(env: [:]), DisplayLease.defaultGraceUs)
    }

    func testAcceptedRange() {
        for (text, seconds) in [("10", 10), ("11", 11), ("300", 300), ("1800", 1800), ("86400", 86_400), (" 60 ", 60)] {
            XCTAssertEqual(DisplayLease.keepSeconds(text), seconds, text)
        }
        XCTAssertEqual(DisplayLease.keepUs(env: ["MATEBRIDGE_DISPLAY_KEEP_S": "300"]), 300_000_000)
    }

    func testAnythingElseFallsBackToTen() {
        let bad: [String?] = [nil, "", " ", "abc", "10s", "5m", "1.5", "9", "0", "-1", "-10", "86401",
                              "99999999999999999999999", "0x10", "+"]
        for text in bad {
            XCTAssertEqual(DisplayLease.keepSeconds(text), 10, String(describing: text))
        }
        XCTAssertEqual(DisplayLease.keepUs(env: ["MATEBRIDGE_DISPLAY_KEEP_S": "9"]), 10_000_000)
        XCTAssertEqual(DisplayLease.keepUs(env: ["OTHER": "300"]), 10_000_000)
    }
}
