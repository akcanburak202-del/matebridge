import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MateBridgeCore
import UniformTypeIdentifiers

/// Reads the Mac's cursor with public API only and read-only calls (T-271, NOTES 2026-10-06 ~13:50): the position from
/// `CGEvent(source: nil)` (via `CursorLocating`), hidden or not from `CGCursorIsVisible` (via
/// `CursorVisibilityChecking`), and the shape from `NSCursor.currentSystem`: the image, its hotspot and its
/// representations, whatever application owns the pointer. Nothing is posted, moved or shown; no window is opened.
///
/// `NSCursor.currentSystem` answered from a background queue in a probe (first call about 16 ms, then ~50 µs), so this
/// runs on the cursor queue, never the main thread. One context only (the cursor queue).
///
/// A new shape is rendered to straight-sized RGBA, shrunk to at most 128 x 128 px, encoded to PNG with ImageIO and
/// put into the shared `CursorShapeStore`; a shape seen before costs one render and one hash (about 25 µs measured in
/// the probe). Builds are capped per second so an image that never repeats cannot flood the tablet with shapes.
final class CursorSampler: @unchecked Sendable {
    /// What one reading is made of, for the cost line and the tests of the host shell.
    struct Reading {
        var snapshot: CursorSnapshot
    }

    private let locator: CursorLocating
    private let visibility: CursorVisibilityChecking
    private let displays: DisplayProviding
    private let store: SharedShapeStore
    private let logger = SessionLogger(component: "cursor")

    /// Geometry is read at most every 250 ms (`CGDisplayCopyDisplayMode` allocates; a mode change is rare).
    private var geometry: DisplayGeometry?
    private var geometryAtNs: UInt64 = 0
    private static let geometryTtlNs: UInt64 = 250_000_000

    private var lastShapeID: UInt32 = 0
    /// The shape is looked at ~15 Hz at most (T-309); position and visibility are read on every sample.
    private var shapeGate = CursorShapeCheckGate()
    /// Shape checks since the start of the run (window deltas are made by `CursorService`).
    var shapeChecks: Int { shapeGate.checks }
    /// Shape builds in the current one-second window, and the cap.
    private var buildWindowStartNs: UInt64 = 0
    private var buildsInWindow = 0
    private static let maxBuildsPerSecond = 20
    private(set) var shapesBuilt = 0
    private(set) var shapeFailures = 0
    private var loggedFlood = false

    init(locator: CursorLocating = SystemCursor(), visibility: CursorVisibilityChecking = SystemCursorVisibility(),
         displays: DisplayProviding = VirtualDisplayLocator(), store: SharedShapeStore) {
        self.locator = locator
        self.visibility = visibility
        self.displays = displays
        self.store = store
    }

    /// First call connects to WindowServer and AppKit (milliseconds): call it before the first real sample.
    func warmUp() {
        _ = locator.location()
        _ = NSCursor.currentSystem
    }

    func resetSession() {
        lastShapeID = 0
        loggedFlood = false
        shapeGate.reset()
    }

    /// The cursor now, or nil when it cannot be placed (no virtual display, no position).
    func sample() -> CursorSnapshot? {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if geometry == nil || nowNs &- geometryAtNs >= Self.geometryTtlNs {
            geometry = displays.geometry()
            geometryAtNs = nowNs
        }
        guard let geometry, let location = locator.location() else { return nil }
        let position = geometry.normalizedPosition(of: location)
        let hidden = visibility.isHidden()
        // Shape work (WindowServer image copy, render, hash) only when the gate allows it; between checks the last
        // shape stays. A hidden cursor needs no new image until it shows again (the gate knows).
        if shapeGate.shouldCheck(nowNs: nowNs, hidden: hidden, hasShape: lastShapeID != 0) {
            lastShapeID = currentShapeID(nowNs: nowNs)
        }
        return CursorSnapshot(x: position.x, y: position.y, visible: !hidden, shapeID: lastShapeID)
    }

    // MARK: Shape

    private func currentShapeID(nowNs: UInt64) -> UInt32 {
        guard let cursor = NSCursor.currentSystem else { return lastShapeID }
        let image = cursor.image
        let reps = image.representations
        let sizes = reps.map { rep -> CursorShapeLayout.Size in
            if let bitmap = rep as? NSBitmapImageRep {
                return CursorShapeLayout.Size(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            }
            return CursorShapeLayout.Size(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        let points = image.size
        guard let index = CursorShapeLayout.chooseRepresentation(sizes, pointWidth: Double(points.width),
                                                                  pointHeight: Double(points.height)),
              let rendered = Self.render(reps[index], imageSize: points) else {
            shapeFailures += 1
            return lastShapeID
        }
        let hot = cursor.hotSpot
        let widthPt16 = CursorShapeLayout.pt16(Double(points.width)), heightPt16 = CursorShapeLayout.pt16(Double(points.height))
        let hotX = CursorShapeLayout.pt16(Double(hot.x)), hotY = CursorShapeLayout.pt16(Double(hot.y))
        let id = CursorShapeLayout.shapeID(pixelHash: rendered.hash, widthPt16: widthPt16, heightPt16: heightPt16,
                                           hotXPt16: hotX, hotYPt16: hotY)
        if store.touch(id) { return id }  // seen before: nothing to build
        guard allowBuild(nowNs: nowNs) else { return lastShapeID }
        guard let data = Self.encodePNG(rendered.image, size: CursorShapeLayout.Size(width: rendered.image.width,
                                                                                    height: rendered.image.height)) else {
            shapeFailures += 1
            logger.log(.warning, "cursor_shape_failed", sessionID: 0, generation: 0,
                       fields: "px=\(sizes[index].width)x\(sizes[index].height)")
            return lastShapeID
        }
        store.put(CursorShape(shapeID: id, widthPt16: widthPt16, heightPt16: heightPt16, hotXPt16: hotX,
                              hotYPt16: hotY, format: .png, data: data))
        shapesBuilt += 1
        return id
    }

    /// At most `maxBuildsPerSecond` new shapes per second (a flood guard); the rest keep the last shape.
    private func allowBuild(nowNs: UInt64) -> Bool {
        if nowNs &- buildWindowStartNs >= 1_000_000_000 {
            buildWindowStartNs = nowNs
            buildsInWindow = 0
        }
        guard buildsInWindow < Self.maxBuildsPerSecond else {
            if !loggedFlood {
                loggedFlood = true
                logger.log(.warning, "cursor_shape_flood", sessionID: 0, generation: 0,
                           fields: "max_per_s=\(Self.maxBuildsPerSecond)")
            }
            return false
        }
        buildsInWindow += 1
        return true
    }

    /// The representation as an sRGB RGBA bitmap at its own pixel size (premultiplied, the layout `CGContext`
    /// supports), cleared first so the bytes, and their hash, are the same every time for the same image.
    private static func render(_ rep: NSImageRep, imageSize: NSSize) -> (image: CGImage, hash: UInt64)? {
        var rect = NSRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
        guard let source = rep.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let w = source.width, h = source.height
        guard w > 0, h > 0, w <= 4096, h <= 4096, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        let hash = CursorShapeLayout.pixelHash(UnsafeRawBufferPointer(start: bytes, count: w * h * 4))
        guard let image = context.makeImage() else { return nil }
        return (image, hash)
    }

    /// PNG of at most `CursorShape.maxDataBytes`: the image shrunk to the wire size (128 px at most), and smaller still
    /// until it fits. nil when even a tiny one does not.
    private static func encodePNG(_ image: CGImage, size: CursorShapeLayout.Size) -> [UInt8]? {
        var target: CursorShapeLayout.Size? = CursorShapeLayout.sentSize(of: size)
        while let t = target {
            if let scaled = t == size ? image : scale(image, to: t), let data = png(scaled),
               data.count <= CursorShape.maxDataBytes {
                return data
            }
            target = CursorShapeLayout.smaller(t)
        }
        return nil
    }

    private static func scale(_ image: CGImage, to size: CursorShapeLayout.Size) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    /// ImageIO writes a PNG with straight alpha whatever the bitmap's premultiplication.
    private static func png(_ image: CGImage) -> [UInt8]? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return [UInt8](data as Data)
    }
}

/// `CursorShapeStore` behind a lock: the cursor queue writes, the session queue reads.
final class SharedShapeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var store = CursorShapeStore()

    /// True when the shape is held (counted as used).
    func touch(_ id: UInt32) -> Bool { lock.withLock { store.use(id) != nil } }
    func put(_ shape: CursorShape) { lock.withLock { store.put(shape) } }
    func shape(_ id: UInt32) -> CursorShape? { lock.withLock { store.use(id) } }
    func removeAll() { lock.withLock { store.removeAll() } }
}
