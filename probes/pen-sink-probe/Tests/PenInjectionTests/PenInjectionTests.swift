import XCTest
import CoreGraphics
@testable import PenInjection

final class PenInjectionTests: XCTestCase {
    func testPointFieldsRoundTrip() throws {
        let s = PenSample(x: 100, y: 200, pressure: 0.75, tiltX: -0.5, tiltY: 0.25, rotation: 30, phase: .move)
        let e = try PenInjector().buildPoint(s, inContact: true)
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
        XCTAssertEqual(PenEventFields.mouseType(for: .down, inContact: false), .leftMouseDown)
        XCTAssertEqual(PenEventFields.mouseType(for: .up, inContact: true), .leftMouseUp)
        XCTAssertEqual(PenEventFields.mouseType(for: .move, inContact: false), .mouseMoved)
        XCTAssertEqual(PenEventFields.mouseType(for: .move, inContact: true), .leftMouseDragged)
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

    func testProximityCapabilityAndButtonFields() throws {
        let e = try PenInjector().buildProximity(entering: true)
        XCTAssertEqual(e.getIntegerValueField(.tabletProximityEventCapabilityMask), PenEventFields.capabilityMask)
        XCTAssertEqual(e.getIntegerValueField(.tabletProximityEventSystemTabletID), PenDevice.systemTabletID)
        let d = try PenInjector().buildPoint(PenSample(x: 1, y: 1, pressure: 0.5, tiltX: 0, tiltY: 0, phase: .down), inContact: false)
        XCTAssertEqual(d.getIntegerValueField(.mouseEventClickState), 1)
        XCTAssertEqual(d.getIntegerValueField(.mouseEventButtonNumber), 0)
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(CGEventType, CGPoint)] = []
        func add(_ e: CGEvent) { lock.lock(); items.append((e.type, e.location)); lock.unlock() }
        var all: [(CGEventType, CGPoint)] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testZeroPressureMidStrokeStaysDragged() throws {
        let rec = Recorder()
        let s = PenSession(post: { rec.add($0) })
        try s.setProximity(true)
        try s.send(PenSample(x: 1, y: 1, pressure: 0.5, tiltX: 0, tiltY: 0, phase: .down))
        try s.send(PenSample(x: 2, y: 2, pressure: 0, tiltX: 0, tiltY: 0, phase: .move))
        try s.send(PenSample(x: 3, y: 3, pressure: 0, tiltX: 0, tiltY: 0, phase: .up))
        try s.send(PenSample(x: 4, y: 4, pressure: 0, tiltX: 0, tiltY: 0, phase: .move))
        XCTAssertEqual(rec.all.map { $0.0 }, [.tabletProximity, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved])
    }

    func testCancelReleasesAtLastPositionAndBlocksLaterSends() throws {
        let rec = Recorder()
        let s = PenSession(post: { rec.add($0) })
        try s.setProximity(true)
        try s.send(PenSample(x: 10, y: 20, pressure: 0.5, tiltX: 0, tiltY: 0, phase: .down))
        s.cancel()
        XCTAssertEqual(rec.all.map { $0.0 }, [.tabletProximity, .leftMouseDown, .leftMouseUp, .tabletProximity])
        XCTAssertEqual(rec.all[2].1.x, 10, accuracy: 0.01)
        XCTAssertEqual(rec.all[2].1.y, 20, accuracy: 0.01)
        XCTAssertFalse(try s.send(PenSample(x: 1, y: 1, pressure: 1, tiltX: 0, tiltY: 0, phase: .down)))
        XCTAssertFalse(try s.setProximity(true))
        s.release()
        XCTAssertEqual(rec.all.count, 4)
    }

    func testCancelBeforeAnythingPostsNothing() throws {
        let rec = Recorder()
        let s = PenSession(post: { rec.add($0) })
        s.cancel()
        XCTAssertFalse(try s.setProximity(true))
        XCTAssertTrue(rec.all.isEmpty)
    }
}
