import CoreGraphics
import Foundation
import ObjectiveC

// The ONLY file in this probe that touches the private CGVirtualDisplay API (AGENTS.md hard rule, mirrored here).
//
// macOS 27 adds `-[CGVirtualDisplayMode initWithWidth:height:refreshRate:transferFunction:]` (uint32) and
// `-[CGVirtualDisplaySettings setIsReference:]`. Apple's SidecarDisplayAgent calls the former with
// transferFunction = 1 right after setIsReference:YES (Sidecar Reference Mode, which Apple documents as EDR-capable).
// The value is forwarded to the window server as `CDVirtualDisplayModeEOTF`. Other values are unknown; this probe
// tries them. Classes are looked up at runtime so a missing selector gives a clear error, not a link failure.

enum HDRVirtualDisplayError: Error, CustomStringConvertible {
    case apiUnavailable(String)
    case creationFailed
    case settingsRejected

    var description: String {
        switch self {
        case .apiUnavailable(let c): return "private API \(c) not found"
        case .creationFailed: return "CGVirtualDisplay initWithDescriptor: returned nil"
        case .settingsRejected: return "CGVirtualDisplay applySettings: returned false"
        }
    }
}

struct VirtualDisplayRequest {
    var pixelWidth: Int
    var pixelHeight: Int
    var refreshRate: Double
    /// nil = the old 3-argument initializer (SDR baseline).
    var transferFunction: UInt32?
    var isReference: Bool
    /// Display P3 primaries on the descriptor (nil = system default, sRGB-like).
    var p3Primaries: Bool
    /// Distinct from MateBridge's own display (vendor 0x4D42, product 1, serial 1) so the two never collide.
    var serial: UInt32
}

final class HDRVirtualDisplay: @unchecked Sendable {
    private var display: NSObject?
    private let queue = DispatchQueue(label: "hdr-probe.virtualdisplay")
    let displayID: CGDirectDisplayID

    static var hasTransferFunctionInit: Bool {
        guard let c = NSClassFromString("CGVirtualDisplayMode") else { return false }
        return c.instancesRespond(to: NSSelectorFromString("initWithWidth:height:refreshRate:transferFunction:"))
    }

    init(_ r: VirtualDisplayRequest) throws {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type else {
            throw HDRVirtualDisplayError.apiUnavailable("CGVirtualDisplay* classes")
        }

        let descriptor = descriptorClass.init()
        descriptor.setValue("MateBridge HDR probe", forKey: "name")
        descriptor.setValue(UInt32(r.pixelWidth), forKey: "maxPixelsWide")
        descriptor.setValue(UInt32(r.pixelHeight), forKey: "maxPixelsHigh")
        let mmW = Double(r.pixelWidth) / 264.0 * 25.4
        let mmH = Double(r.pixelHeight) / 264.0 * 25.4
        descriptor.setValue(NSValue(size: CGSize(width: mmW, height: mmH)), forKey: "sizeInMillimeters")
        descriptor.setValue(UInt32(0x4D42), forKey: "vendorID")
        descriptor.setValue(UInt32(0x0226), forKey: "productID")
        descriptor.setValue(r.serial, forKey: "serialNum")
        if r.p3Primaries {
            descriptor.setValue(NSValue(point: CGPoint(x: 0.680, y: 0.320)), forKey: "redPrimary")
            descriptor.setValue(NSValue(point: CGPoint(x: 0.265, y: 0.690)), forKey: "greenPrimary")
            descriptor.setValue(NSValue(point: CGPoint(x: 0.150, y: 0.060)), forKey: "bluePrimary")
            descriptor.setValue(NSValue(point: CGPoint(x: 0.3127, y: 0.3290)), forKey: "whitePoint")
        }
        descriptor.setValue(queue, forKey: "queue")

        let initSel = NSSelectorFromString("initWithDescriptor:")
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
        let initImp = unsafeBitCast(class_getMethodImplementation(displayClass, initSel), to: InitFn.self)
        guard let allocated = displayClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let created = initImp(allocated, initSel, descriptor)?.takeRetainedValue() as? NSObject else {
            throw HDRVirtualDisplayError.creationFailed
        }

        guard let modeAlloc = modeClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else {
            throw HDRVirtualDisplayError.creationFailed
        }
        let mode: NSObject?
        if let tf = r.transferFunction {
            let sel = NSSelectorFromString("initWithWidth:height:refreshRate:transferFunction:")
            guard modeClass.instancesRespond(to: sel) else {
                throw HDRVirtualDisplayError.apiUnavailable("initWithWidth:height:refreshRate:transferFunction:")
            }
            typealias Fn = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double, UInt32) -> Unmanaged<AnyObject>?
            let imp = unsafeBitCast(class_getMethodImplementation(modeClass, sel), to: Fn.self)
            mode = imp(modeAlloc, sel, UInt32(r.pixelWidth), UInt32(r.pixelHeight), r.refreshRate, tf)?
                .takeRetainedValue() as? NSObject
        } else {
            let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
            typealias Fn = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
            let imp = unsafeBitCast(class_getMethodImplementation(modeClass, sel), to: Fn.self)
            mode = imp(modeAlloc, sel, UInt32(r.pixelWidth), UInt32(r.pixelHeight), r.refreshRate)?
                .takeRetainedValue() as? NSObject
        }
        guard let mode else { throw HDRVirtualDisplayError.creationFailed }

        let settings = settingsClass.init()
        settings.setValue(UInt32(0), forKey: "hiDPI")  // 1x, like the game display (decision 0029)
        settings.setValue([mode], forKey: "modes")
        if r.isReference {
            guard settings.responds(to: NSSelectorFromString("setIsReference:")) else {
                throw HDRVirtualDisplayError.apiUnavailable("setIsReference:")
            }
            settings.setValue(true, forKey: "isReference")
        }

        let applySel = NSSelectorFromString("applySettings:")
        typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let applyImp = unsafeBitCast(class_getMethodImplementation(displayClass, applySel), to: ApplyFn.self)
        guard applyImp(created, applySel, settings) else { throw HDRVirtualDisplayError.settingsRejected }

        guard let id = created.value(forKey: "displayID") as? UInt32 else { throw HDRVirtualDisplayError.creationFailed }
        display = created
        displayID = id
    }

    /// Releases the object, which removes the virtual display.
    func invalidate() { display = nil }

    deinit { display = nil }
}
