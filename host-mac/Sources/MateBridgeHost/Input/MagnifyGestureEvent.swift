import CoreGraphics
import MateBridgeCore

/// Builds the trackpad magnify gesture event (decision 0009). There is no public CGEvent API for it, so this is the
/// ONE place that knows the undocumented event type and field numbers; nothing else in the project mentions them
/// (the same rule `VirtualDisplay` follows for its private API).
///
/// Technique from Mac Mouse Fix, `TouchSimulator.m` (github.com/noah-nuebling/mac-mouse-fix): a bare `CGEvent` of type
/// 29 (`NSEventTypeGesture`) with field 110 = 8 (the HID "zoom" gesture), field 132 = phase (began 1, changed 2,
/// ended 4) and field 113 = the magnification as a `Double`. Checked on this Mac in the spike of 2026-09-30
/// (docs/NOTES.md): Krita 5.3.4 zoomed from 176 to 452 percent on macOS 27. If a macOS update breaks it, the
/// fallbacks are in decision 0009.
enum MagnifyGestureEvent {
    private static let gestureEventType: UInt32 = 29
    private static let gestureKindField: UInt32 = 110
    private static let gestureKindZoom: Int64 = 8
    private static let gesturePhaseField: UInt32 = 132
    private static let magnificationField: UInt32 = 113

    /// Nil when the event cannot be built (the poster then reports it failed; an `ended` is retried, see `OwedRelease`).
    static func make(_ g: MacMagnify, source: CGEventSource?) -> CGEvent? {
        guard let type = CGEventType(rawValue: gestureEventType),
              let kind = CGEventField(rawValue: gestureKindField),
              let phase = CGEventField(rawValue: gesturePhaseField),
              let magnification = CGEventField(rawValue: magnificationField),
              let e = CGEvent(source: source) else { return nil }
        e.type = type
        e.location = CGPoint(x: g.position.x, y: g.position.y)
        e.setIntegerValueField(kind, value: gestureKindZoom)
        e.setIntegerValueField(phase, value: phaseValue(g.phase))
        e.setDoubleValueField(magnification, value: g.value.isFinite ? g.value : 0)
        return e
    }

    private static func phaseValue(_ phase: MacMagnify.Phase) -> Int64 {
        switch phase {
        case .began: 1
        case .changed: 2
        case .ended: 4
        }
    }
}
