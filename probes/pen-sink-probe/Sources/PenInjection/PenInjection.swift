// Pen event synthesis for macOS: proximity + tablet-point mouse events.
// Approach follows LukeLogix/android-display (Apache-2.0): a tablet-proximity
// event, then mouse events carrying kCGEventMouseSubtypeTabletPoint with
// pressure/tilt fields, then a leaving-proximity event.
import CoreGraphics
import Foundation

/// One normalized pen sample. Pressure 0...1, tilt -1...1 (both axes), position in global display points.
public struct PenSample: Equatable, Sendable {
    public enum Phase: Sendable { case down, move, up }
    public var x: Double
    public var y: Double
    public var pressure: Double
    public var tiltX: Double
    public var tiltY: Double
    public var rotation: Double
    public var phase: Phase

    public init(x: Double, y: Double, pressure: Double, tiltX: Double, tiltY: Double,
                rotation: Double = 0, phase: Phase) {
        self.x = x; self.y = y; self.pressure = pressure
        self.tiltX = tiltX; self.tiltY = tiltY; self.rotation = rotation; self.phase = phase
    }
}

/// Stable identity of the synthetic tablet device.
public enum PenDevice {
    public static let deviceID: Int64 = 1
    public static let vendorID: Int64 = 0x4D42       // "MB"
    public static let tabletID: Int64 = 1
    public static let pointerID: Int64 = 1
    public static let pointerType: Int64 = 1         // NX_TABLET_POINTER_PEN
    public static let systemTabletID: Int64 = 1
}

public enum PenEventFields {
    /// Clamp to a range; NaN becomes 0.
    public static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v.isNaN ? 0 : min(max(v, lo), hi)
    }

    /// Double-valued fields written onto a tablet-point mouse event.
    public static func pointDoubleFields(for s: PenSample) -> [(CGEventField, Double)] {
        let p = clamp(s.pressure, 0, 1)
        return [
            (.mouseEventPressure, p),
            (.tabletEventPointPressure, p),
            (.tabletEventTiltX, clamp(s.tiltX, -1, 1)),
            (.tabletEventTiltY, clamp(s.tiltY, -1, 1)),
            (.tabletEventRotation, s.rotation),
        ]
    }

    /// Integer-valued fields written onto a tablet-point mouse event.
    public static func pointIntFields() -> [(CGEventField, Int64)] {
        [
            (.mouseEventSubtype, Int64(CGEventMouseSubtype.tabletPoint.rawValue)),
            (.tabletEventDeviceID, PenDevice.deviceID),
        ]
    }

    /// Integer fields for a proximity event.
    public static func proximityIntFields(entering: Bool) -> [(CGEventField, Int64)] {
        [
            (.tabletProximityEventVendorID, PenDevice.vendorID),
            (.tabletProximityEventTabletID, PenDevice.tabletID),
            (.tabletProximityEventPointerID, PenDevice.pointerID),
            (.tabletProximityEventDeviceID, PenDevice.deviceID),
            (.tabletProximityEventSystemTabletID, PenDevice.systemTabletID),
            (.tabletProximityEventPointerType, PenDevice.pointerType),
            (.tabletProximityEventEnterProximity, entering ? 1 : 0),
        ]
    }

    /// Mouse event type for a phase. Move while hovering uses mouseMoved.
    public static func mouseType(for phase: PenSample.Phase, pressure: Double) -> CGEventType {
        switch phase {
        case .down: return .leftMouseDown
        case .up: return .leftMouseUp
        case .move: return pressure > 0 ? .leftMouseDragged : .mouseMoved
        }
    }
}

public enum PenInjectionError: Error, CustomStringConvertible {
    case eventCreationFailed
    public var description: String { "Could not create CGEvent" }
}

/// Builds (and optionally posts) pen events. `build*` never posts, so it is safe to unit-test.
public struct PenInjector: Sendable {
    public init() {}

    public func buildProximity(entering: Bool) throws -> CGEvent {
        guard let e = CGEvent(source: CGEventSource(stateID: .hidSystemState)) else {
            throw PenInjectionError.eventCreationFailed
        }
        e.type = .tabletProximity
        for (f, v) in PenEventFields.proximityIntFields(entering: entering) { e.setIntegerValueField(f, value: v) }
        return e
    }

    public func buildPoint(_ s: PenSample) throws -> CGEvent {
        let type = PenEventFields.mouseType(for: s.phase, pressure: s.pressure)
        guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                              mouseCursorPosition: CGPoint(x: s.x, y: s.y), mouseButton: .left) else {
            throw PenInjectionError.eventCreationFailed
        }
        for (f, v) in PenEventFields.pointIntFields() { e.setIntegerValueField(f, value: v) }
        for (f, v) in PenEventFields.pointDoubleFields(for: s) { e.setDoubleValueField(f, value: v) }
        return e
    }

    /// Posts an event. Requires Accessibility permission.
    public func post(_ e: CGEvent) { e.post(tap: .cghidEventTap) }
}
