import XCTest
@testable import MateBridgeCore

final class ExperimentKnobTests: XCTestCase {
    func testParseFps() {
        XCTAssertEqual(VideoSettings.parseFps("120"), 120)
        XCTAssertEqual(VideoSettings.parseFps(" 90 "), 90)
        XCTAssertEqual(VideoSettings.parseFps("60"), 60)
        for bad in [nil, "", "30", "144", "abc"] { XCTAssertEqual(VideoSettings.parseFps(bad), 60) }
    }

    func testParseBitrate() {
        XCTAssertEqual(VideoSettings.parseBitrateKbps("80000"), 80_000)
        XCTAssertEqual(VideoSettings.parseBitrateKbps("5000"), 5_000)
        XCTAssertEqual(VideoSettings.parseBitrateKbps("500"), 500)
        XCTAssertEqual(VideoSettings.parseBitrateKbps("150000"), 150_000)
        for bad in [nil, "", "499", "150001", "x"] { XCTAssertNil(VideoSettings.parseBitrateKbps(bad)) }
    }

    func testNoVariablesKeepsDefaults() {
        let base = VideoSettings.tabletDefault
        XCTAssertEqual(base.applyingExperimentKnobs([:]), base)
    }

    func testFps120ImpliesRefresh120() {
        let base = VideoSettings.tabletDefault
        let a = base.applyingExperimentKnobs(["MATEBRIDGE_FPS": "120"])
        XCTAssertEqual(a.fps, 120)
        XCTAssertEqual(a.displayRefreshHz, 120)
        XCTAssertEqual(a.bitrateKbps, base.bitrateKbps)
        // T-302: `MATEBRIDGE_REFRESH` is gone and inert.
        let b = base.applyingExperimentKnobs(["MATEBRIDGE_FPS": "120", "MATEBRIDGE_REFRESH": "60"])
        XCTAssertEqual(b.displayRefreshHz, 120)
        let c = base.applyingExperimentKnobs(["MATEBRIDGE_FPS": "90", "MATEBRIDGE_BITRATE_KBPS": "90000"])
        XCTAssertEqual(c.fps, 90)
        XCTAssertEqual(c.displayRefreshHz, 60)
        XCTAssertEqual(c.bitrateKbps, 90_000)
        XCTAssertEqual(c.streamConfig(configID: 1).fps, 90)
    }

    func testCadenceTargetFollowsFps() {
        let w = CadenceMeter(fps: 120).take(nowUs: 0, queueDropsTotal: 0, sentTotal: 0)
        XCTAssertEqual(w.targetIntervalUs, 8_333)
    }

    func testEncoderBehindAndP99() {
        var w = CadenceWindow(targetIntervalUs: 8_333)
        for i in 0..<10 {
            w.recordEncoderIn()
            if i < 7 { w.recordEncoderOut(encodeTimeUs: UInt64(1000 * (i + 1))) }
        }
        XCTAssertEqual(w.encoderBehind, 3)
        XCTAssertTrue(w.logFields.contains("enc_behind=3"))
        XCTAssertTrue(w.logFields.contains("enc_ms_p50_95_99=4.0/7.0/7.0"))
    }
}
