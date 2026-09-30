import CoreGraphics
import Foundation
import MateBridgeCore

/// Where the virtual display is right now, in global coordinates. `nil` means there is none.
public protocol DisplayProviding: Sendable {
    func geometry() -> DisplayGeometry?
}

/// Finds the MateBridge virtual display with PUBLIC CoreGraphics calls only (`VirtualDisplay` stays the one file
/// that touches the private API). The display is recognized by the vendor and product numbers `VirtualDisplay`
/// gives its descriptor; `VideoPipeline` does not expose the display ID and is outside T-023's files.
///
/// Input must never land on another display, so when nothing matches the answer is nil and the injector drops input.
///
/// Called from one queue by `InputController`. The result is cached; a cached display that went away is rescanned
/// at most every 250 ms so a missing display costs almost nothing per message.
public final class VirtualDisplayLocator: DisplayProviding, @unchecked Sendable {
    /// Must equal the descriptor values in `VirtualDisplay.swift` ("MB" and product 1).
    public static let vendorID: UInt32 = 0x4D42
    public static let productID: UInt32 = 0x0001

    private let lock = NSLock()
    private var cachedID: CGDirectDisplayID?
    private var lastScanNs: UInt64 = 0
    private static let rescanIntervalNs: UInt64 = 250_000_000

    public init() {}

    public func geometry() -> DisplayGeometry? {
        guard let id = currentID() else { return nil }
        return Self.geometry(of: id)
    }

    private func currentID() -> CGDirectDisplayID? {
        lock.lock()
        defer { lock.unlock() }
        if let id = cachedID {
            if Self.isOurs(id) { return id }
            cachedID = nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastScanNs >= Self.rescanIntervalNs else { return nil }
        lastScanNs = now
        cachedID = Self.scan()
        return cachedID
    }

    private static func isOurs(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(id) != 0 && CGDisplayVendorNumber(id) == vendorID && CGDisplayModelNumber(id) == productID
    }

    /// The newest matching display (largest ID) if a stale one is still listed while its replacement comes up.
    private static func scan() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).filter(isOurs).max()
    }

    /// `CGDisplayBounds` (global points, origin top-left) and the backing scale of the current mode.
    static func geometry(of id: CGDirectDisplayID) -> DisplayGeometry? {
        let bounds = CGDisplayBounds(id)
        var scale = 1.0
        if let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 {
            scale = Double(mode.pixelWidth) / Double(mode.width)
        }
        return DisplayGeometry(originX: Double(bounds.origin.x), originY: Double(bounds.origin.y),
                               widthPt: Double(bounds.width), heightPt: Double(bounds.height), scale: scale)
    }
}
