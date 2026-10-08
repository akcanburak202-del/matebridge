import CoreGraphics
import Foundation
import MateBridgeCore
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
// With hiDPI = 0 (the 1x game display, decision 0029) the mode is the pixel size itself.

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

    /// Backing pixel size and HiDPI the display was created with.
    let pixelWidth: Int
    let pixelHeight: Int
    let hidpi: Bool

    /// - Parameters:
    ///   - pixelWidth/pixelHeight: backing pixel size (e.g. 2800x1840, or a 1x game display such as 1848x1214).
    ///   - physicalPixelWidth/physicalPixelHeight: the panel's pixel size, for `sizeInMillimeters` (default: the
    ///     backing size). A game display passes the native size so the reported physical size stays the panel's.
    ///   - hidpi: when true, exposes a 2x mode (pixels/2 points) instead of a 1x mode.
    ///   - transfer: the transfer function requested by the stream (decision 0032, `VideoSettings.displayTransfer`: 1 for
    ///     HDR10, else 0). The default (0) uses the legacy
    ///     `initWithWidth:height:refreshRate:` mode initializer exactly as before. 1 uses
    ///     `initWithWidth:height:refreshRate:transferFunction:` and falls back to the legacy modes once when that
    ///     selector is missing, returns nil or its modes are rejected (`transferOutcome`).
    ///   - primariesKnob: T-281 developer knob `MATEBRIDGE_VD_PRIMARIES` (default: read from the process environment,
    ///     like `VideoSettings.vdPrimariesKnob`). A display created for an HDR transfer function (`transfer` != 0) gets Display P3 primaries in its descriptor, before `initWithDescriptor:`, so macOS counts it as wide
    ///     gamut and Safari/YouTube offer HDR (`VirtualDisplayPrimaries`). An SDR display gets none (as before).
    init(name: String, pixelWidth: Int, pixelHeight: Int, physicalPixelWidth: Int? = nil,
         physicalPixelHeight: Int? = nil, hidpi: Bool, refreshRate: Double = 60,
         transfer: UInt32 = 0,
         primariesKnob: VirtualDisplayPrimaries.Knob = VirtualDisplayPrimaries.parse(env: ProcessInfo.processInfo.environment))
        throws {
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
        let mmW = Double(physicalPixelWidth ?? pixelWidth) / 264.0 * 25.4
        let mmH = Double(physicalPixelHeight ?? pixelHeight) / 264.0 * 25.4
        descriptor.setValue(NSValue(size: CGSize(width: mmW, height: mmH)), forKey: "sizeInMillimeters")
        descriptor.setValue(VirtualDisplay.vendorID, forKey: "vendorID")
        descriptor.setValue(VirtualDisplay.productID, forKey: "productID")
        descriptor.setValue(UInt32(1), forKey: "serialNum")
        descriptor.setValue(queue, forKey: "queue")

        // T-281: primaries are only honored at creation, so they go in before `initWithDescriptor:`. A missing setter
        // creates the display without them (`primaries_fallback=selector_missing`); creation never fails over this.
        let primariesWanted = VirtualDisplayPrimaries.decide(transferRequested: transfer, knob: primariesKnob)
        let primariesApplied = VirtualDisplayPrimaries.resolve(choice: primariesWanted, invalidKnob: primariesKnob.invalid) {
            descriptorClass.instancesRespond(to: NSSelectorFromString($0))
        }
        for property in VirtualDisplayPrimaries.properties(for: primariesApplied.choice) {
            descriptor.setValue(NSValue(point: CGPoint(x: property.value.x, y: property.value.y)), forKey: property.key)
        }

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
        // A display object that is dropped on a later error removes whatever it created: count it as a removal so
        // the next creation waits out `DisplayRecreateGap`.
        var kept = false
        defer { if !kept { VirtualDisplay.removals.mark() } }

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
        // The one mode's size: points for HiDPI (pixels / 2), pixels for a 1x display.
        let modeW = hidpi ? pixelWidth / 2 : pixelWidth
        let modeH = hidpi ? pixelHeight / 2 : pixelHeight
        func legacyModes() -> [NSObject] { makeMode(modeW, modeH).map { [$0] } ?? [] }

        let settings = settingsClass.init()
        settings.setValue(UInt32(hidpi ? 1 : 0), forKey: "hiDPI")

        let applySel = NSSelectorFromString("applySettings:")
        guard created.responds(to: applySel) else { throw VirtualDisplayError.apiUnavailable("applySettings:") }
        typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let applyImp = unsafeBitCast(class_getMethodImplementation(displayClass, applySel), to: ApplyFn.self)
        func apply(_ modes: [NSObject]) -> Bool {
            settings.setValue(modes, forKey: "modes")
            return applyImp(created, applySel, settings)
        }

        // T-232: a transfer function only when the knob asks for one; the default path below is the pre-T-232 code.
        let tfSel = NSSelectorFromString("initWithWidth:height:refreshRate:transferFunction:")
        var applied: UInt32 = 0
        var fallback: VirtualDisplayTransfer.FallbackReason?
        switch VirtualDisplayTransfer.decide(requested: transfer,
                                             selectorAvailable: modeClass.instancesRespond(to: tfSel)) {
        case .legacy:
            break
        case .fallback(let reason):
            fallback = reason
        case .transfer(let tf):
            typealias ModeTfInitFn = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double, UInt32)
                -> Unmanaged<AnyObject>?
            let tfImp = unsafeBitCast(class_getMethodImplementation(modeClass, tfSel), to: ModeTfInitFn.self)
            let mode = modeClass.perform(NSSelectorFromString("alloc")).flatMap {
                tfImp($0.takeUnretainedValue(), tfSel, UInt32(modeW), UInt32(modeH), refreshRate, tf)?
                    .takeRetainedValue() as? NSObject
            }
            let accepted = mode.map { apply([$0]) } ?? false
            fallback = VirtualDisplayTransfer.fallbackAfterAttempt(modeCreated: mode != nil, settingsAccepted: accepted)
            if fallback == nil { applied = tf }
        }
        if applied == 0 {
            guard apply(legacyModes()) else { throw VirtualDisplayError.settingsRejected }
        }
        self.transferOutcome = VirtualDisplayTransfer.Outcome(requested: transfer, applied: applied,
                                                              fallback: fallback,
                                                              primaries: primariesApplied)
        self.primariesWanted = primariesWanted

        guard let id = created.value(forKey: "displayID") as? UInt32 else { throw VirtualDisplayError.creationFailed }
        kept = true
        self.display = created
        self.displayID = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hidpi = hidpi
        self.requestedRefreshHz = refreshRate
        self.modeSelected = VirtualDisplay.selectMode(id, pixelWidth: pixelWidth, pixelHeight: pixelHeight, hidpi: hidpi,
                                                      refreshRate: refreshRate)
    }

    /// Refresh rate the display mode was created with.
    let requestedRefreshHz: Double

    /// T-232: the transfer function requested and applied to the display's mode (`ev=vd_transfer`); T-281: also the
    /// primaries the descriptor was given.
    let transferOutcome: VirtualDisplayTransfer.Outcome

    /// T-281: the primaries the display was meant to be created with (`DisplayMode.primaries`). Not the applied ones:
    /// a missing setter must not make `DisplayReuse` recreate the display on every pipeline start.
    private let primariesWanted: VirtualDisplayPrimaries.Choice

    /// T-281: whether macOS treats the display's colour space as wide gamut (`CGColorSpace.isWideGamutRGB` of
    /// `CGDisplayCopyColorSpace`), the condition `MTShouldPlayHDRVideo` checks for an external display. Read once after
    /// a short delay (the system installs the display's colour space shortly after creation); suspends, never blocks a
    /// thread. nil when the display is not online by then.
    static func readWideGamut(displayID: CGDirectDisplayID) async -> Bool? {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard CGDisplayIsOnline(displayID) != 0 else { return nil }
        return CGDisplayCopyColorSpace(displayID).isWideGamutRGB
    }

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

    /// The mode this display was created with (`DisplayReuse` compares it with the wanted one). `transfer` is the
    /// requested transfer function (an HDR10 stream checks `transferOutcome.applied` separately).
    var mode: DisplayMode {
        DisplayMode(widthPx: pixelWidth, heightPx: pixelHeight, hidpi: hidpi, refreshHz: Int(requestedRefreshHz.rounded()),
                    transfer: transferOutcome.requested, primaries: primariesWanted)
    }

    /// Releases the retained object, which removes the virtual display. The removal time is recorded so the next
    /// display (same vendor/product/serial) is created only after `DisplayRecreateGap`.
    func invalidate() {
        guard display != nil else { return }
        display = nil
        Self.removals.mark()
    }

    deinit {
        if display != nil {
            display = nil
            Self.removals.mark()
        }
    }

    // MARK: Recreate gap

    /// Host-clock time of the last display removal, shared by all instances (there is one serial number).
    private final class RemovalClock: @unchecked Sendable {
        private let lock = NSLock()
        private var lastUs: UInt64?
        func mark() { let now = HostClock.nowUs(); lock.withLock { lastUs = now } }
        var last: UInt64? { lock.withLock { lastUs } }
    }
    private static let removals = RemovalClock()

    /// How long a new display must still wait after the last removal (0 when none is recent).
    static func recreateWaitUs() -> UInt64 {
        DisplayRecreateGap.remainingUs(lastRemovedUs: removals.last, nowUs: HostClock.nowUs())
    }
}
