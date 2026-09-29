import CoreGraphics
import Foundation
import ObjectiveC

// The ONLY file that touches the private CGVirtualDisplay API (AGENTS.md hard rule).
//
// The classes are looked up at runtime (NSClassFromString) and driven via KVC / IMP calls,
// so no private headers are needed and a missing class yields a clear error instead of a
// link failure. Class/selector names and the descriptor/settings shape follow
// LukeLogix/android-display (Apache-2.0) and the widely documented CGVirtualDisplay
// interface (CGVirtualDisplayDescriptor, CGVirtualDisplaySettings, CGVirtualDisplayMode).
//
// The display disappears when the CGVirtualDisplay object is deallocated, so this type
// retains it until `invalidate()` or deinit.

enum VirtualDisplayError: Error, CustomStringConvertible {
    case apiUnavailable(String)
    case creationFailed
    case settingsRejected

    var description: String {
        switch self {
        case .apiUnavailable(let c): return "private API \(c) not found (macOS changed?)"
        case .creationFailed: return "CGVirtualDisplay initWithDescriptor: returned nil"
        case .settingsRejected: return "CGVirtualDisplay applySettings: returned false"
        }
    }
}

final class VirtualDisplay: @unchecked Sendable {
    private var display: NSObject?
    private let queue = DispatchQueue(label: "vdisplay-probe.virtualdisplay")
    let displayID: CGDirectDisplayID

    /// - Parameters:
    ///   - pixelWidth/pixelHeight: backing pixel size (e.g. 2800x1840).
    ///   - hidpi: when true, exposes a 2x mode (pixels/2 points) in addition to 1x.
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
        descriptor.setValue(UInt32(0x4D42), forKey: "vendorID")   // "MB"
        descriptor.setValue(UInt32(0x0001), forKey: "productID")
        descriptor.setValue(UInt32(1), forKey: "serialNum")
        descriptor.setValue(queue, forKey: "queue")

        let initSel = NSSelectorFromString("initWithDescriptor:")
        guard let initMethod = class_getMethodImplementation(displayClass, initSel) as IMP?,
              displayClass.instancesRespond(to: initSel) else {
            throw VirtualDisplayError.apiUnavailable("initWithDescriptor:")
        }
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
        let initImp = unsafeBitCast(initMethod, to: InitFn.self)
        guard let allocated = displayClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let created = initImp(allocated, initSel, descriptor)?.takeRetainedValue() as? NSObject else {
            throw VirtualDisplayError.creationFailed
        }

        // Modes: 1x at full pixel size; with hidpi also the 2x mode (half the points).
        typealias ModeInitFn = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        let modeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard modeClass.instancesRespond(to: modeSel) else { throw VirtualDisplayError.apiUnavailable("initWithWidth:height:refreshRate:") }
        let modeImp = unsafeBitCast(class_getMethodImplementation(modeClass, modeSel), to: ModeInitFn.self)
        func makeMode(_ w: Int, _ h: Int) -> NSObject? {
            guard let a = modeClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
            return modeImp(a, modeSel, UInt32(w), UInt32(h), refreshRate)?.takeRetainedValue() as? NSObject
        }
        var modes: [NSObject] = []
        if hidpi, let m = makeMode(pixelWidth / 2, pixelHeight / 2) { modes.append(m) }
        if let m = makeMode(pixelWidth, pixelHeight) { modes.append(m) }

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
    }

    /// Releases the retained object, which removes the virtual display.
    func invalidate() {
        display = nil
    }

    deinit { display = nil }
}
