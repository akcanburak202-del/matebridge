import CoreGraphics
import Foundation
import MateBridgeCore

/// The one place where `MacEvent`s leave the process (T-023). Everything before it is pure and unit-tested in
/// `MateBridgeCore`; this seam exists so that a fake can stand in for it and nothing is posted.
public protocol MacEventPoster: Sendable {
    /// Posts the events in order. Never throws; an event that cannot be built is skipped (and counted by the poster).
    func post(_ events: [MacEvent])
}

/// Posts through `CGEvent` at the HID tap (needs Accessibility permission; without it macOS drops the events
/// silently, which is why `InputController` gates on the permission itself).
///
/// The tablet method is the one validated in Phase 0 (`probes/pen-sink-probe`, docs/NOTES.md 2026-09-29, Krita
/// accepted it): a tablet proximity event, then mouse events carrying the `tabletPoint` subtype with pressure and
/// tilt, and a leaving proximity event. That approach follows LukeLogix/android-display (Apache-2.0).
///
/// Confined to one queue by its owner (`InputController`); not thread-safe on its own.
public final class CGEventPoster: MacEventPoster, @unchecked Sendable {
    private let logger = SessionLogger(component: "input")
    private var failures = 0

    public init() {}

    public func post(_ events: [MacEvent]) {
        for event in events {
            // A fresh HID-system-state source per event, exactly as the probe did.
            guard let cg = CGEventFactory.make(event, source: CGEventSource(stateID: .hidSystemState)) else {
                failures += 1
                // Counts only; the first failure and then every 100th.
                if failures == 1 || failures % 100 == 0 {
                    logger.log(.error, "event_create_failed", sessionID: 0, generation: 0, fields: "count=\(failures)")
                }
                continue
            }
            cg.post(tap: .cghidEventTap)
        }
    }
}

/// `MacEvent` to `CGEvent`. Builds, never posts. Field choices are copied from the Phase 0 probe.
enum CGEventFactory {
    // Identity of the synthetic tablet (probe: PenDevice).
    static let deviceID: Int64 = 1
    static let vendorID: Int64 = 0x4D42  // "MB"
    static let tabletID: Int64 = 1
    static let pointerID: Int64 = 1
    static let systemTabletID: Int64 = 1
    /// NX_TABLET_POINTER_PEN and NX_TABLET_POINTER_ERASER (IOKit `IOLLEvent.h`).
    static func pointerType(_ tool: PenTool) -> Int64 { tool == .pen ? 1 : 3 }
    /// NX_TABLET_CAPABILITY_ DEVICEID | ABSX | ABSY | BUTTONS | TILTX | TILTY | PRESSURE | ROTATION.
    static let capabilityMask: Int64 = 0x0001 | 0x0002 | 0x0004 | 0x0040 | 0x0080 | 0x0100 | 0x0400 | 0x2000

    static func make(_ event: MacEvent, source: CGEventSource?) -> CGEvent? {
        switch event {
        case .tabletProximity(let tool, let entering):
            return proximity(tool: tool, entering: entering, source: source)
        case .tabletPoint(let p):
            return tabletPoint(p, source: source)
        case .mouse(let m):
            return mouse(m, source: source)
        case .scroll(let s):
            return scroll(s, source: source)
        }
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v.isNaN ? 0 : min(max(v, lo), hi)
    }

    private static func proximity(tool: PenTool, entering: Bool, source: CGEventSource?) -> CGEvent? {
        guard let e = CGEvent(source: source) else { return nil }
        e.type = .tabletProximity
        e.setIntegerValueField(.tabletProximityEventVendorID, value: vendorID)
        e.setIntegerValueField(.tabletProximityEventTabletID, value: tabletID)
        e.setIntegerValueField(.tabletProximityEventPointerID, value: pointerID)
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: systemTabletID)
        e.setIntegerValueField(.tabletProximityEventPointerType, value: pointerType(tool))
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        return e
    }

    private static func tabletPoint(_ p: MacTabletPoint, source: CGEventSource?) -> CGEvent? {
        let type: CGEventType
        switch p.kind {
        case .hover: type = .mouseMoved
        case .down: type = .leftMouseDown
        case .drag: type = .leftMouseDragged
        case .up: type = .leftMouseUp
        }
        // Drag versus move depends on contact, never on pressure (probe: `mouseType`).
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: CGPoint(x: p.position.x, y: p.position.y),
                              mouseButton: .left) else { return nil }
        e.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        e.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        e.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        if p.clickState != 0 { e.setIntegerValueField(.mouseEventClickState, value: Int64(p.clickState)) }
        let pressure = clamp(p.pressure, 0, 1)
        e.setDoubleValueField(.mouseEventPressure, value: pressure)
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        e.setDoubleValueField(.tabletEventTiltX, value: clamp(p.tiltX, -1, 1))
        e.setDoubleValueField(.tabletEventTiltY, value: clamp(p.tiltY, -1, 1))
        e.setDoubleValueField(.tabletEventRotation, value: 0)
        return e
    }

    private static func mouse(_ m: MacMouse, source: CGEventSource?) -> CGEvent? {
        let type: CGEventType
        let button: CGMouseButton
        switch (m.kind, m.button) {
        case (.moved, _): (type, button) = (.mouseMoved, .left)
        case (.down, .left): (type, button) = (.leftMouseDown, .left)
        case (.up, .left): (type, button) = (.leftMouseUp, .left)
        case (.dragged, .left): (type, button) = (.leftMouseDragged, .left)
        case (.down, .right): (type, button) = (.rightMouseDown, .right)
        case (.up, .right): (type, button) = (.rightMouseUp, .right)
        case (.dragged, .right): (type, button) = (.rightMouseDragged, .right)
        case (.down, _): (type, button) = (.otherMouseDown, .center)
        case (.up, _): (type, button) = (.otherMouseUp, .center)
        case (.dragged, _): (type, button) = (.otherMouseDragged, .center)
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: CGPoint(x: m.position.x, y: m.position.y),
                              mouseButton: button) else { return nil }
        // Back and forward are "other" buttons 3 and 4; the constructor only knows left, right and center.
        e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(m.button.rawValue))
        if m.clickState != 0 { e.setIntegerValueField(.mouseEventClickState, value: Int64(m.clickState)) }
        if m.kind == .moved || m.kind == .dragged {
            e.setIntegerValueField(.mouseEventDeltaX, value: Int64(m.deltaX.rounded()))
            e.setIntegerValueField(.mouseEventDeltaY, value: Int64(m.deltaY.rounded()))
        }
        return e
    }

    /// Pixel-unit scroll. Direction and feel are phase 3 work and unverified on hardware.
    private static func scroll(_ s: MacScroll, source: CGEventSource?) -> CGEvent? {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: s.dy, wheel2: s.dx, wheel3: 0) else { return nil }
        // `kCGScrollWheelEventScrollPhase` takes CGScrollPhase values (began 1, changed 2, ended 4, cancelled 8),
        // not NSEventPhase. No momentum phase is ever set: the injector generates no momentum.
        let phase: Int64
        switch s.phase {
        case .none: phase = 0
        case .began: phase = 1
        case .changed: phase = 2
        case .ended: phase = 4
        case .cancelled: phase = 8
        }
        if phase != 0 {
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        }
        return e
    }
}
