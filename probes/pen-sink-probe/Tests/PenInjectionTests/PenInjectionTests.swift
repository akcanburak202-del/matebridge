import XCTest
import CoreGraphics
@testable import PenInjection

final class PenInjectionTests: XCTestCase {
    func testPointFieldsRoundTrip() throws {
        let s = PenSample(x: 100, y: 200, pressure: 0.75, tiltX: -0.5, tiltY: 0.25, rotation: 30, phase: .move)
        let e = try PenInjector().buildPoint(s)
        XCTAssertEqual(e.type, .leftMouseDragged)
        XCTAssertEqual(e.getIntegerValueField(.mouseEventSubtype), Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        XCTAssertEqual(e.getDoubleValueField(.tabletEventPointPressure), 0.75, accuracy: 0.005)
        XCTAssertEqual(e.getDoubleValueField(.mouseEventPressure), 0.75, accuracy: 0.005)
        XCTAssertEqual(e.getDoubleValueField(.tabletEventTiltX), -0.5, accuracy: 0.005)
        XCTAssertEqual(e.getDoubleValueField(.tabletEventTiltY), 0.25, accuracy: 0.005)
        XCTAssertEqual(e.location.x, 100, accuracy: 0.005)
        XCTAssertEqual(e.location.y, 200, accuracy: 0.005)
    }

    func testClamping() {
        let s = PenSample(x: 0, y: 0, pressure: 3, tiltX: -9, tiltY: .nan, phase: .move)
        let d = Dictionary(uniqueKeysWithValues: PenEventFields.pointDoubleFields(for: s).map { ($0.0.rawValue, $0.1) })
        XCTAssertEqual(d[CGEventField.tabletEventPointPressure.rawValue], 1)
        XCTAssertEqual(d[CGEventField.tabletEventTiltX.rawValue], -1)
        XCTAssertEqual(d[CGEventField.tabletEventTiltY.rawValue], 0)
    }

    func testMouseTypes() {
        XCTAssertEqual(PenEventFields.mouseType(for: .down, pressure: 0.1), .leftMouseDown)
        XCTAssertEqual(PenEventFields.mouseType(for: .up, pressure: 0), .leftMouseUp)
        XCTAssertEqual(PenEventFields.mouseType(for: .move, pressure: 0), .mouseMoved)
        XCTAssertEqual(PenEventFields.mouseType(for: .move, pressure: 0.5), .leftMouseDragged)
    }

    func testProximityEvent() throws {
        let inn = try PenInjector().buildProximity(entering: true)
        XCTAssertEqual(inn.type, .tabletProximity)
        XCTAssertEqual(inn.getIntegerValueField(.tabletProximityEventEnterProximity), 1)
        XCTAssertEqual(inn.getIntegerValueField(.tabletProximityEventPointerType), PenDevice.pointerType)
        let out = try PenInjector().buildProximity(entering: false)
        XCTAssertEqual(out.getIntegerValueField(.tabletProximityEventEnterProximity), 0)
    }

    func testPatternsWellFormed() {
        for p in PenPattern.allCases {
            let s = p.strokeSamples(originX: 0, originY: 0, width: 400, height: 200)
            XCTAssertEqual(s.first?.phase, .down)
            XCTAssertEqual(s.last?.phase, .up)
            XCTAssertEqual(s.last?.pressure, 0)
            XCTAssertEqual(s.filter { $0.phase == .down }.count, 1)
            XCTAssertTrue(s.allSatisfy { (0...1).contains($0.pressure) && (-1...1).contains($0.tiltX) && (-1...1).contains($0.tiltY) })
        }
        let r = PenPattern.ramp.strokeSamples(originX: 0, originY: 0, width: 100, height: 10, count: 101)
        XCTAssertEqual(r[50].pressure, 1, accuracy: 1e-9)
        let t = PenPattern.tilt.strokeSamples(originX: 0, originY: 0, width: 100, height: 10, count: 101)
        XCTAssertEqual(t[0].tiltX, -1, accuracy: 1e-9)
        XCTAssertEqual(t[100].tiltX, 1, accuracy: 1e-9)
    }
}
