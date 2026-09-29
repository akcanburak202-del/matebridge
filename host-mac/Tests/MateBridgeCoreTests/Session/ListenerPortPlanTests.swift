import XCTest
@testable import MateBridgeCore

final class ListenerPortPlanTests: XCTestCase {
    func testPreferredThenSystemThenExhausted() {
        var plan = ListenerPortPlan(preferred: 47001)
        XCTAssertEqual(plan.nextPort(), 47001)
        XCTAssertTrue(plan.lastWasPreferred)
        XCTAssertEqual(plan.nextPort(), 0)
        XCTAssertFalse(plan.lastWasPreferred)
        XCTAssertNil(plan.nextPort())
    }

    func testSystemOnlyPlan() {
        var plan = ListenerPortPlan(preferred: 0)
        XCTAssertEqual(plan.nextPort(), 0)
        XCTAssertFalse(plan.lastWasPreferred)
        XCTAssertNil(plan.nextPort())
    }

    func testDefaults() {
        XCTAssertEqual(DefaultPorts.control, 47001)
        XCTAssertEqual(DefaultPorts.video, 47002)
    }
}
