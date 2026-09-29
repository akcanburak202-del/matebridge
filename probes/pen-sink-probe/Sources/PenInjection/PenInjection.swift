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
    public static func pointIntFields(phase: PenSample.Phase) -> [(CGEventField, Int64)] {
        var f: [(CGEventField, Int64)] = [
            (.mouseEventSubtype, Int64(CGEventMouseSubtype.tabletPoint.rawValue)),
            (.tabletEventDeviceID, PenDevice.deviceID),
            (.mouseEventButtonNumber, 0),
        ]
        switch phase {
        case .down, .up: f.append((.mouseEventClickState, 1))
        case .move: break
        }
        return f
    }

    /// Tablet capability bits (NX_TABLET_CAPABILITY_* from IOLLEvent.h, recalled from memory, not re-verified):
    /// deviceID 0x2, absX 0x4, absY 0x8, buttons 0x80, tiltX 0x100, tiltY 0x200, pressure 0x800, rotation 0x4000.
    public static let capabilityMask: Int64 = 0x2 | 0x4 | 0x8 | 0x80 | 0x100 | 0x200 | 0x800 | 0x4000

    /// Integer fields for a proximity event.
    public static func proximityIntFields(entering: Bool) -> [(CGEventField, Int64)] {
        [
            (.tabletProximityEventVendorID, PenDevice.vendorID),
            (.tabletProximityEventTabletID, PenDevice.tabletID),
            (.tabletProximityEventPointerID, PenDevice.pointerID),
            (.tabletProximityEventDeviceID, PenDevice.deviceID),
            (.tabletProximityEventSystemTabletID, PenDevice.systemTabletID),
            (.tabletProximityEventVendorPointerType, PenDevice.pointerType),
            (.tabletProximityEventPointerType, PenDevice.pointerType),
            (.tabletProximityEventCapabilityMask, capabilityMask),
            (.tabletProximityEventEnterProximity, entering ? 1 : 0),
        ]
    }

    /// Mouse event type. Drag vs. move depends on contact state (button down), never on pressure.
    public static func mouseType(for phase: PenSample.Phase, inContact: Bool) -> CGEventType {
        switch phase {
        case .down: return .leftMouseDown
        case .up: return .leftMouseUp
        case .move: return inContact ? .leftMouseDragged : .mouseMoved
        }
    }
}

public enum PenInjectionError: Error, CustomStringConvertible {
    case eventCreationFailed
    public var description: String { "Could not create CGEvent" }
}

/// Builds pen events. Never posts, so it is safe to unit-test.
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

    public func buildPoint(_ s: PenSample, inContact: Bool) throws -> CGEvent {
        let type = PenEventFields.mouseType(for: s.phase, inContact: inContact)
        guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                              mouseCursorPosition: CGPoint(x: s.x, y: s.y), mouseButton: .left) else {
            throw PenInjectionError.eventCreationFailed
        }
        for (f, v) in PenEventFields.pointIntFields(phase: s.phase) { e.setIntegerValueField(f, value: v) }
        for (f, v) in PenEventFields.pointDoubleFields(for: s) { e.setDoubleValueField(f, value: v) }
        return e
    }
}

/// Owns posting and pen state. All posting is serialized under one lock together with the state update,
/// so `cancel()` (e.g. from a signal handler) can never interleave with a half-finished stroke and always
/// releases from the true state, at the last posted position.
public final class PenSession: @unchecked Sendable {
    private let lock = NSLock()
    private let injector = PenInjector()
    private let post: @Sendable (CGEvent) -> Void
    private var cancelled = false
    private var inContact = false
    private var inProximity = false
    private var last = CGPoint.zero

    /// Default poster posts to the HID tap (requires Accessibility).
    public init(post: @escaping @Sendable (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.post = post
    }

    /// Returns false (and posts nothing) once cancelled.
    @discardableResult
    public func setProximity(_ entering: Bool) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        if entering == inProximity { return true }
        post(try injector.buildProximity(entering: entering))
        inProximity = entering
        return true
    }

    /// Returns false (and posts nothing) once cancelled.
    @discardableResult
    public func send(_ s: PenSample) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        post(try injector.buildPoint(s, inContact: inContact))
        last = CGPoint(x: s.x, y: s.y)
        switch s.phase {
        case .down: inContact = true
        case .up: inContact = false
        case .move: break
        }
        return true
    }

    /// Releases anything held (contact, then proximity). Idempotent; does not block further sends.
    public func release() {
        lock.lock(); defer { lock.unlock() }
        releaseLocked()
    }

    /// Like `release()` but also rejects every later send. Safe to call from a signal handler queue.
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        releaseLocked()
    }

    private func releaseLocked() {
        if inContact, let e = try? injector.buildPoint(
            PenSample(x: last.x, y: last.y, pressure: 0, tiltX: 0, tiltY: 0, phase: .up), inContact: true) {
            post(e)
        }
        inContact = false
        if inProximity, let e = try? injector.buildProximity(entering: false) { post(e) }
        inProximity = false
    }
}
