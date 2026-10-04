import AppKit
import CoreGraphics
import MateBridgeCore

/// T-232: reads a display's EDR headroom from `NSScreen` (public AppKit), for `ev=vd_transfer`. 1.0 means SDR (no
/// headroom). Read-only; opens nothing.
enum DisplayEDR {
    /// The headroom of the screen backing `displayID`, or nil when AppKit does not (yet) list that screen.
    @MainActor
    static func headroom(displayID: CGDirectDisplayID) -> EDRHeadroom? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }) else { return nil }
        return EDRHeadroom(current: Double(screen.maximumExtendedDynamicRangeColorComponentValue),
                           potential: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
    }

    /// `headroom(displayID:)` on the main actor.
    static func read(displayID: CGDirectDisplayID) async -> EDRHeadroom? {
        await MainActor.run { headroom(displayID: displayID) }
    }
}
