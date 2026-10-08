import XCTest
@testable import MateBridgeCore

final class InjectToFrameTests: XCTestCase {
    func testMeasuresFirstDirtyFrameAfterPress() {
        var m = InjectToFrameMatcher()
        m.noteInjection(atUs: 1_000_000)
        m.noteDirtyFrame(atUs: 1_012_000)
        m.noteDirtyFrame(atUs: 1_020_000)
        XCTAssertEqual(m.samplesUs, [12_000])
    }

    func testBusyScreenIsNoisyAndGivesNoSample() {
        var m = InjectToFrameMatcher()
        m.noteDirtyFrame(atUs: 900_000)
        m.noteInjection(atUs: 1_000_000)  // 100 ms after a change: not quiet
        m.noteDirtyFrame(atUs: 1_010_000)
        XCTAssertEqual(m.noisy, 1)
        XCTAssertTrue(m.samplesUs.isEmpty)
    }

    func testQuietAfterWindowArms() {
        var m = InjectToFrameMatcher()
        m.noteDirtyFrame(atUs: 100_000)
        m.noteInjection(atUs: 700_000)
        m.noteDirtyFrame(atUs: 716_000)
        XCTAssertEqual(m.samplesUs, [16_000])
        XCTAssertEqual(m.noisy, 0)
    }

    func testTimeoutWhenNoFrameAnswers() {
        var m = InjectToFrameMatcher()
        m.noteInjection(atUs: 1_000_000)
        m.noteDirtyFrame(atUs: 2_500_000)  // too late: a timeout, not a 1.5 s sample
        XCTAssertEqual(m.timeouts, 1)
        XCTAssertTrue(m.samplesUs.isEmpty)
    }

    func testSecondPressWhilePendingIsAbsorbed() {
        var m = InjectToFrameMatcher()
        m.noteInjection(atUs: 1_000_000)
        m.noteInjection(atUs: 1_005_000)
        m.noteDirtyFrame(atUs: 1_020_000)
        XCTAssertEqual(m.samplesUs, [20_000])
    }

    func testFrameBeforePressNeverMatches() {
        var m = InjectToFrameMatcher()
        m.noteInjection(atUs: 1_000_000)
        m.noteDirtyFrame(atUs: 999_000)
        XCTAssertTrue(m.samplesUs.isEmpty)
        XCTAssertNotNil(m.pendingUs)
    }

    func testLateDeliveredEarlierFrameInsideQuietWindowInvalidatesPending() {
        var m = InjectToFrameMatcher()
        m.noteInjection(atUs: 1_000_000)  // screen looked still when armed
        // a change captured 100 ms before the press, delivered only now
        m.noteDirtyFrame(atUs: 1_030_000, captureUs: 900_000)
        XCTAssertEqual(m.noisy, 1)
        XCTAssertNil(m.pendingUs)
        XCTAssertTrue(m.samplesUs.isEmpty)
        m.noteDirtyFrame(atUs: 1_040_000, captureUs: 1_035_000)
        XCTAssertTrue(m.samplesUs.isEmpty)
    }

    func testOldFrameOutsideQuietWindowDoesNotAnswerPress() {
        var m = InjectToFrameMatcher()
        m.noteInjection(atUs: 5_000_000)
        m.noteDirtyFrame(atUs: 5_010_000, captureUs: 4_000_000)  // captured long before the press
        XCTAssertTrue(m.samplesUs.isEmpty)
        XCTAssertNotNil(m.pendingUs)
        m.noteDirtyFrame(atUs: 5_030_000, captureUs: 5_020_000)
        XCTAssertEqual(m.samplesUs, [30_000])
    }

    func testResetAndForcedReport() {
        let meter = InjectToFrameMeter()
        meter.noteInjection(atUs: 2_000_000)
        meter.noteDirtyFrame(atUs: 2_008_000)
        XCTAssertNotNil(meter.takeReport(nowUs: 2_100_000, force: true))
        meter.noteInjection(atUs: 5_000_000)
        meter.noteDirtyFrame(atUs: 5_008_000)
        meter.reset()
        XCTAssertNil(meter.takeReport(nowUs: 5_100_000, force: true))
    }

    func testReportFieldsAndReset() {
        var m = InjectToFrameMatcher()
        XCTAssertNil(m.takeFields())
        var t: UInt64 = 10_000_000
        for d: UInt64 in [10_000, 20_000, 30_000, 40_000] {
            m.noteInjection(atUs: t)
            m.noteDirtyFrame(atUs: t + d)
            t += 2_000_000
        }
        XCTAssertEqual(m.takeFields(), "n=4 p50_ms=20.0 p95_ms=40.0 max_ms=40.0 noisy=0 timeout=0")
        XCTAssertNil(m.takeFields())
    }

    func testMeterReportsEveryTenSecondsOnlyWithSamples() {
        let meter = InjectToFrameMeter()
        XCTAssertNil(meter.takeReport(nowUs: 1_000_000))  // starts the window
        meter.noteInjection(atUs: 2_000_000)
        meter.noteDirtyFrame(atUs: 2_008_000)
        XCTAssertNil(meter.takeReport(nowUs: 5_000_000))
        XCTAssertEqual(meter.takeReport(nowUs: 11_000_000), "n=1 p50_ms=8.0 p95_ms=8.0 max_ms=8.0 noisy=0 timeout=0")
        XCTAssertNil(meter.takeReport(nowUs: 22_000_000))
    }

    func testPressEdges() {
        let pos = DisplayPoint(x: 0, y: 0)
        XCTAssertTrue(MacEvent.key(MacKey(kind: .keyDown, keyCode: 0, flags: [])).isPressEdge)
        XCTAssertFalse(MacEvent.key(MacKey(kind: .keyDown, keyCode: 0, flags: [], isRepeat: true)).isPressEdge)
        XCTAssertFalse(MacEvent.key(MacKey(kind: .keyUp, keyCode: 0, flags: [])).isPressEdge)
        XCTAssertTrue(MacEvent.mouse(MacMouse(kind: .down, button: .left, position: pos, deltaX: 0, deltaY: 0,
                                              clickState: 1)).isPressEdge)
        XCTAssertFalse(MacEvent.mouse(MacMouse(kind: .dragged, button: .left, position: pos, deltaX: 0, deltaY: 0,
                                               clickState: 0)).isPressEdge)
        XCTAssertTrue(MacEvent.tabletPoint(MacTabletPoint(kind: .down, tool: .pen, position: pos, pressure: 0.5,
                                                          tiltX: 0, tiltY: 0, clickState: 1)).isPressEdge)
        XCTAssertFalse(MacEvent.tabletPoint(MacTabletPoint(kind: .hover, tool: .pen, position: pos, pressure: 0,
                                                           tiltX: 0, tiltY: 0, clickState: 0)).isPressEdge)
    }
}
