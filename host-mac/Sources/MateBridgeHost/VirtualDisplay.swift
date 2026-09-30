import CoreGraphics
import Foundation
import ObjectiveC

// The ONLY file that touches the private CGVirtualDisplay API (AGENTS.md hard rule).
//
// The classes are looked up at runtime (NSClassFromString) and driven via KVC / IMP calls,
// so no private headers are needed and a missing class yields a clear error instead of a
// link failure. Written from the publicly known CGVirtualDisplay interface (class and
// selector names as used by DeskPad and LukeLogix/android-display); no code was copied.
//
// The display disappears when the CGVirtualDisplay object is deallocated, so this type
// retains it until `invalidate()` or deinit.
//
// HiDPI note (docs/NOTES.md 2026-09-29): with hiDPI = 1 the mode sizes are in POINTS
// (pixels = 2x), so only the half-size mode is registered while maxPixels stays at the full
// pixel size. A 1400x920 mode + 2800x1840 maxPixels yields 2800x1840 px frames.

public enum VirtualDisplayError: Error, CustomStringConvertible {
    case apiUnavailable(String)
    case creationFailed
    case settingsRejected

    public var description: String {
        switch self {
        case .apiUnavailable(let c): return "private API \(c) not found (macOS changed?)"
        case .creationFailed: return "CGVirtualDisplay initWithDescriptor: returned nil"
        case .settingsRejected: return "CGVirtualDisplay applySettings: returned false"
        }
    }
}

final class VirtualDisplay: @unchecked Sendable {
    private var display: NSObject?
    private let queue = DispatchQueue(label: "matebridge.virtualdisplay")
    let displayID: CGDirectDisplayID

    /// The vendor and product numbers the display is created with. `VirtualDisplayLocator` recognizes the display by
    /// exactly these numbers (public CoreGraphics calls only), so they live in one place.
    static let vendorID: UInt32 = 0x4D42  // "MB"
    static let productID: UInt32 = 0x0001

    /// - Parameters:
    ///   - pixelWidth/pixelHeight: backing pixel size (e.g. 2800x1840).
    ///   - hidpi: when true, exposes a 2x mode (pixels/2 points) instead of a 1x mode.
    init(name: String, pixelWidth: Int, pixelHeight: Int, hidpi: Bool, refreshRate: Double = 60) throws {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type else {
            throw VirtualDisplayError.apiUnavailable("CGVirtualDisplayDescriptor")
        }
        guard let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type else {
            throw VirtualDisplayError.apiUnavailable("CGVirtualDisplaySettings")
        }
        guard let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type else {
            throw VirtualDisplayError.apiUnavailable("CGVirtualDisplay")
        }
        guard let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type else {
            throw VirtualDisplayError.apiUnavailable("CGVirtualDisplayMode")
        }

        let descriptor = descriptorClass.init()
        descriptor.setValue(name, forKey: "name")
        descriptor.setValue(UInt32(pixelWidth), forKey: "maxPixelsWide")
        descriptor.setValue(UInt32(pixelHeight), forKey: "maxPixelsHigh")
        // ~264 dpi panel (12.2 inch tablet, 2800x1840).
        let mmW = Double(pixelWidth) / 264.0 * 25.4
        let mmH = Double(pixelHeight) / 264.0 * 25.4
        descriptor.setValue(NSValue(size: CGSize(width: mmW, height: mmH)), forKey: "sizeInMillimeters")
        descriptor.setValue(VirtualDisplay.vendorID, forKey: "vendorID")
        descriptor.setValue(VirtualDisplay.productID, forKey: "productID")
        descriptor.setValue(UInt32(1), forKey: "serialNum")
        descriptor.setValue(queue, forKey: "queue")

        let initSel = NSSelectorFromString("initWithDescriptor:")
        guard displayClass.instancesRespond(to: initSel) else {
            throw VirtualDisplayError.apiUnavailable("initWithDescriptor:")
        }
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
        let initImp = unsafeBitCast(class_getMethodImplementation(displayClass, initSel), to: InitFn.self)
        guard let allocated = displayClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let created = initImp(allocated, initSel, descriptor)?.takeRetainedValue() as? NSObject else {
            throw VirtualDisplayError.creationFailed
        }

        typealias ModeInitFn = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        let modeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard modeClass.instancesRespond(to: modeSel) else {
            throw VirtualDisplayError.apiUnavailable("initWithWidth:height:refreshRate:")
        }
        let modeImp = unsafeBitCast(class_getMethodImplementation(modeClass, modeSel), to: ModeInitFn.self)
        func makeMode(_ w: Int, _ h: Int) -> NSObject? {
            guard let a = modeClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
            return modeImp(a, modeSel, UInt32(w), UInt32(h), refreshRate)?.takeRetainedValue() as? NSObject
        }
        var modes: [NSObject] = []
        if hidpi {
            if let m = makeMode(pixelWidth / 2, pixelHeight / 2) { modes.append(m) }
        } else if let m = makeMode(pixelWidth, pixelHeight) {
            modes.append(m)
        }

        let settings = settingsClass.init()
        settings.setValue(UInt32(hidpi ? 1 : 0), forKey: "hiDPI")
        settings.setValue(modes, forKey: "modes")

        let applySel = NSSelectorFromString("applySettings:")
        guard created.responds(to: applySel) else { throw VirtualDisplayError.apiUnavailable("applySettings:") }
        typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let applyImp = unsafeBitCast(class_getMethodImplementation(displayClass, applySel), to: ApplyFn.self)
        guard applyImp(created, applySel, settings) else { throw VirtualDisplayError.settingsRejected }

        guard let id = created.value(forKey: "displayID") as? UInt32 else { throw VirtualDisplayError.creationFailed }
        self.display = created
        self.displayID = id
        self.requestedRefreshHz = refreshRate
        self.modeSelected = VirtualDisplay.selectMode(id, pixelWidth: pixelWidth, pixelHeight: pixelHeight, hidpi: hidpi,
                                                      refreshRate: refreshRate)
    }

    /// Refresh rate the display mode was created with.
    let requestedRefreshHz: Double

    /// Current mode as the system reports it, e.g. "2800x1840px 1400x920pt 120Hz" (0 Hz = the system reports none).
    var appliedModeDescription: String {
        guard let m = CGDisplayCopyDisplayMode(displayID) else { return "unknown" }
        return "\(m.pixelWidth)x\(m.pixelHeight)px \(m.width)x\(m.height)pt \(String(format: "%.0f", m.refreshRate))Hz"
    }

    /// True if the requested pixel-size mode was made current (best effort; capture works either way
    /// only if the default mode already matches).
    private(set) var modeSelected = false

    /// Makes the mode with the wanted pixel size current (HiDPI: 2x, i.e. points = pixels / 2),
    /// refresh rate closest to the requested one first. The mode list appears shortly after creation, so retry for up to ~2 s.
    private static func selectMode(_ id: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, hidpi: Bool, refreshRate: Double) -> Bool {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        for _ in 0..<20 {
            let all = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
            let match = all
                .filter { $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight
                    && ($0.pixelWidth > $0.width) == hidpi }
                .min { abs($0.refreshRate - refreshRate) < abs($1.refreshRate - refreshRate) }
            if let match { return CGDisplaySetDisplayMode(id, match, nil) == .success }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// Releases the retained object, which removes the virtual display.
    func invalidate() {
        display = nil
    }

    deinit { display = nil }
}
