import XCTest
@testable import MateBridgeCore

/// T-087: refresh buffer mode, refresh-frame QP cap knob and its on/off state machine, sharpness bench options.
final class IdleRefreshRefineTests: XCTestCase {
    // MARK: Knobs

    func testRefreshKnobDefaultsAreT086Behaviour() {
        let c = IdleRefreshConfig.parse(["MATEBRIDGE_IDLE_REFRESH_MS": "300"])
        XCTAssertEqual(c.buffer, .same)
        XCTAssertNil(c.maxQP)
        XCTAssertEqual(c.logValue, "300ms*3")
        XCTAssertEqual(IdleRefreshConfig(), IdleRefreshConfig.parse([:]))
    }

    func testRefreshBufferParse() {
        XCTAssertEqual(IdleRefreshBuffer.parse(nil), .same)
        XCTAssertEqual(IdleRefreshBuffer.parse("copy"), .copy)
        XCTAssertEqual(IdleRefreshBuffer.parse(" COPY "), .copy)
        XCTAssertEqual(IdleRefreshBuffer.parse("same"), .same)
        XCTAssertEqual(IdleRefreshBuffer.parse("clone"), .same)
    }

    func testRefreshQPParseAndRange() {
        func qp(_ v: String) -> Int? { IdleRefreshConfig.parse(["MATEBRIDGE_IDLE_REFRESH_QP": v]).maxQP }
        XCTAssertEqual(qp("10"), 10)
        XCTAssertEqual(qp(" 1 "), 1)
        XCTAssertEqual(qp("51"), 51)
        XCTAssertNil(qp("0"))
        XCTAssertNil(qp("52"))
        XCTAssertNil(qp("ten"))
    }

    func testRefreshLogValueShowsCopyAndQP() {
        let c = IdleRefreshConfig.parse(["MATEBRIDGE_IDLE_REFRESH_MS": "300", "MATEBRIDGE_IDLE_REFRESH_COUNT": "6",
                                         "MATEBRIDGE_IDLE_REFRESH_BUFFER": "copy", "MATEBRIDGE_IDLE_REFRESH_QP": "10"])
        XCTAssertEqual(c, IdleRefreshConfig(delayMs: 300, count: 6, buffer: .copy, maxQP: 10))
        XCTAssertEqual(c.logValue, "300ms*6+copy+qp10")
        // Off stays "off" whatever else is set.
        XCTAssertEqual(IdleRefreshConfig.parse(["MATEBRIDGE_IDLE_REFRESH_QP": "10"]).logValue, "off")
    }

    // MARK: QP cap state machine

    func testBoostAppliesOnceForARefreshRunAndLiftsBeforeTheNextOtherFrame() {
        var b = RefreshQPBoost(maxQP: 10)
        XCTAssertNil(b.before(refresh: false), "nothing to lift before any refresh")
        XCTAssertEqual(b.before(refresh: true), .apply(10))
        XCTAssertTrue(b.active)
        XCTAssertNil(b.before(refresh: true))
        XCTAssertNil(b.before(refresh: true))
        XCTAssertEqual(b.before(refresh: false), .restore)
        XCTAssertFalse(b.active)
        XCTAssertNil(b.before(refresh: false))
        // The next static stretch caps again.
        XCTAssertEqual(b.before(refresh: true), .apply(10))
        XCTAssertEqual(b.before(refresh: false), .restore)
    }

    func testBoostRefusedByVideoToolboxIsNeverRetried() {
        var b = RefreshQPBoost(maxQP: 12)
        XCTAssertEqual(b.before(refresh: true), .apply(12))
        b.applyFailed()
        XCTAssertFalse(b.active)
        XCTAssertTrue(b.disabled)
        XCTAssertNil(b.before(refresh: false), "nothing was applied, nothing to lift")
        XCTAssertNil(b.before(refresh: true))
        XCTAssertNil(b.before(refresh: false))
    }

    // MARK: Bench options

    func testSharpnessBenchDefaultsToASettledSession() throws {
        let d = try XCTUnwrap(SharpnessBenchOptions.parse(["--sharpness-bench"])).get()
        XCTAssertEqual(d.motionFrames, 240)
        XCTAssertEqual(d.resumeFrames, 0)
        XCTAssertNil(d.refreshBuffer)
    }

    func testSharpnessBenchRefreshBufferAndResume() throws {
        let o = try XCTUnwrap(SharpnessBenchOptions.parse(
            ["--sharpness-bench", "--refresh-buffer", "copy", "--resume-frames", "120", "--motion-frames", "1200"]))
            .get()
        XCTAssertEqual(o.refreshBuffer, .copy)
        XCTAssertEqual(o.resumeFrames, 120)
        XCTAssertEqual(o.motionFrames, 1200)
        XCTAssertEqual(try XCTUnwrap(SharpnessBenchOptions.parse(["--sharpness-bench", "--refresh-buffer", "SAME"]))
            .get().refreshBuffer, .same)
        for bad in [["--refresh-buffer"], ["--refresh-buffer", "clone"], ["--resume-frames", "-1"],
                    ["--motion-frames", "1201"]] {
            guard case .failure = SharpnessBenchOptions.parse(["--sharpness-bench"] + bad)! else {
                return XCTFail("\(bad) should fail")
            }
        }
    }
}
