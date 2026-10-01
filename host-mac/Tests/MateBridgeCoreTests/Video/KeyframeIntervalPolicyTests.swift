import XCTest
@testable import MateBridgeCore

final class KeyframeIntervalPolicyTests: XCTestCase {
    func testResolve() {
        XCTAssertEqual(KeyframeIntervalPolicy.resolve(nil), 300)
        XCTAssertEqual(KeyframeIntervalPolicy.resolve("0"), 0)
        XCTAssertEqual(KeyframeIntervalPolicy.resolve(" 10 "), 10)
        XCTAssertEqual(KeyframeIntervalPolicy.resolve("-5"), 300)
        XCTAssertEqual(KeyframeIntervalPolicy.resolve("abc"), 300)
        XCTAssertEqual(KeyframeIntervalPolicy.resolve("999999"), 3600)
    }
}
