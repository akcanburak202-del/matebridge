import AppKit
import CoreGraphics
import CursorProbeCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Read-only samplers for the cursor candidates. Nothing here moves the pointer, posts events or opens a window.
// Only public API: NSCursor, CGEvent(source: nil) (read), NSEvent.mouseLocation, CGCursorIsVisible (looked up with
// dlsym because it is deprecated), CGWindowListCopyWindowInfo. No CGS* symbols.

@inline(__always) func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// Everything needed to describe one cursor image, plus the rendered bitmap for PNG dumps.
struct ShapeSample {
    var info: ShapeInfo
    var image: CGImage
}

enum CursorSampling {
    static func repPixelSize(_ rep: NSImageRep) -> (Int, Int) {
        if let b = rep as? NSBitmapImageRep { return (b.pixelsWide, b.pixelsHigh) }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    /// Full description: renders the largest representation to sRGB RGBA8 and hashes the bytes.
    static func shape(_ c: NSCursor) -> ShapeSample? {
        let img = c.image
        let sorted = img.representations.sorted { a, b in
            let (aw, ah) = repPixelSize(a), (bw, bh) = repPixelSize(b)
            return aw * ah > bw * bh
        }
        guard let best = sorted.first else { return nil }
        var rect = NSRect(x: 0, y: 0, width: img.size.width, height: img.size.height)
        guard let src = best.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let w = src.width, h = src.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data, let rendered = ctx.makeImage() else { return nil }
        let digest = Digest.wordHash64(UnsafeRawBufferPointer(start: data, count: w * h * 4))
        let hs = c.hotSpot
        let info = ShapeInfo(digest: digest, pixelWidth: w, pixelHeight: h, pointWidth: Double(img.size.width),
                             pointHeight: Double(img.size.height), hotSpotX: Double(hs.x), hotSpotY: Double(hs.y),
                             reps: sorted.map { let (rw, rh) = repPixelSize($0); return "\(rw)x\(rh)" })
        return ShapeSample(info: info, image: rendered)
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: Visibility

    private typealias CGCursorIsVisibleFn = @convention(c) () -> UInt32
    private static let cursorIsVisibleFn: CGCursorIsVisibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(sym, to: CGCursorIsVisibleFn.self)
    }()

    /// Deprecated public CoreGraphics call. nil when the symbol is gone.
    static var cgCursorIsVisible: Bool? { cursorIsVisibleFn.map { $0() != 0 } }

    // MARK: Position

    static var cgEventLocation: CGPoint? { CGEvent(source: nil)?.location }
    static var nsMouseLocation: CGPoint { NSEvent.mouseLocation }

    // MARK: Window list

    struct CursorWindow: Equatable {
        var present: Bool
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var alpha: Double
    }

    /// Window Server publishes a window for the cursor on some systems. Look for it by owner and layer.
    static func windowListCursor() -> CursorWindow {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return CursorWindow(present: false, x: 0, y: 0, w: 0, h: 0, alpha: 0) }
        for d in list {
            let name = d[kCGWindowName as String] as? String
            let layer = d[kCGWindowLayer as String] as? Int ?? 0
            if name == "Cursor" || layer >= 2_147_483_600 {
                let b = d[kCGWindowBounds as String] as? [String: Double] ?? [:]
                return CursorWindow(present: true, x: b["X"] ?? 0, y: b["Y"] ?? 0, w: b["Width"] ?? 0, h: b["Height"] ?? 0,
                                    alpha: d[kCGWindowAlpha as String] as? Double ?? 0)
            }
        }
        return CursorWindow(present: false, x: 0, y: 0, w: 0, h: 0, alpha: 0)
    }

    /// Discovery helper for `once`: windows owned by Window Server (name, layer, size). No titles of other apps.
    static func windowServerWindows() -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var out: [String] = []
        for d in list where (d[kCGWindowOwnerName as String] as? String) == "Window Server" {
            let b = d[kCGWindowBounds as String] as? [String: Double] ?? [:]
            out.append("name=\(d[kCGWindowName as String] as? String ?? "nil") layer=\(d[kCGWindowLayer as String] as? Int ?? 0)"
                       + " size=\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) alpha=\(d[kCGWindowAlpha as String] as? Double ?? -1)")
        }
        return out
    }
}
