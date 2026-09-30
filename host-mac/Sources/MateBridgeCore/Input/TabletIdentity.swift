/// The identity the synthetic tablet announces in its proximity events (T-031).
///
/// Qt on macOS decides the tablet device type from `vendorPointingDeviceType` (`QTabletEvent::Stylus` only for
/// Wacom-style codes) and Krita treats any input of unknown device type as a mouse, which makes pen-to-eraser
/// switching invisible to it. So a proximity event carries a Wacom-style pointer type and a fixed unique ID.
public enum TabletIdentity {
    /// Wacom pointer-type codes: a pen tip and an eraser tip. Qt maps both to `Stylus`.
    public static func vendorPointerType(_ tool: PenTool) -> Int64 {
        tool == .pen ? 0x0802 : 0x080A
    }

    /// One nonzero ID for both ends of the pen, like a real stylus. Krita remembers presets per device by this
    /// value (`LastPreset_<id>`), so it must never change between runs. ASCII "MBPEN".
    public static let vendorUniqueID: Int64 = 0x4D42_5045_4E

    /// Qt 5.15 `wacomTabletDevice` rule for the device being a stylus.
    static func qtTreatsAsStylus(_ vendorPointerType: Int64) -> Bool {
        (vendorPointerType & 0x0006) == 0x0002 && (vendorPointerType & 0x0F06) != 0x0902
    }
}
