import CoreGraphics
import CoreText
import Foundation

/// Deterministic "desktop" scene at 2800x1840: a procedural photo (soft colour blobs plus grain) panning under the
/// whole frame, and one white text panel per half with lines scrolling up at different speeds. Clips draw the same
/// scene through a translated context, so every crop is pixel-identical to that region of the full clip.
final class Scene {
    static let width = 2800
    static let height = 1840

    private let photo: CGImage
    private let columns: [(image: CGImage, rect: CGRect, speed: Double)]
    private let panX = 2.5   // px per frame
    private let panY = 1.5

    /// `grain` = per-channel grain amplitude (+-grain) of the photo; more grain means more bits at a given quality.
    init(frames: Int, grain: Int = 6) {
        let maxPan = Int(ceil(Double(frames) * 2.5)) + 8
        photo = Scene.makePhoto(width: Scene.width + maxPan, height: Scene.height + Int(ceil(Double(frames) * 1.5)) + 8,
                               grain: grain)
        // Panels in scene coordinates (CG origin bottom-left); one in each half, not touching the split line.
        let left = CGRect(x: 90, y: 110, width: 1180, height: 1580)
        let right = CGRect(x: 1520, y: 170, width: 1200, height: 1500)
        let leftSpeed = 4.0, rightSpeed = 7.0
        columns = [
            (Scene.makeText(width: Int(left.width), height: Int(left.height) + Int(Double(frames) * leftSpeed) + 64,
                            font: "Menlo", size: 22, seed: 1), left, leftSpeed),
            (Scene.makeText(width: Int(right.width), height: Int(right.height) + Int(Double(frames) * rightSpeed) + 64,
                            font: "Helvetica", size: 27, seed: 2), right, rightSpeed),
        ]
    }

    /// Draws frame `index` into `ctx`, whose pixel (0,0) top-left is scene pixel (`originX`, `originY`) top-left.
    func draw(frame index: Int, into ctx: CGContext, originX: Int, originY: Int, clipHeight: Int) {
        ctx.saveGState()
        // Scene y is bottom-up in CG; shift so the clip shows rows originY ..< originY + clipHeight from the top.
        let dy = -(Scene.height - originY - clipHeight)
        ctx.translateBy(x: CGFloat(-originX), y: CGFloat(dy))
        ctx.interpolationQuality = .medium

        // Photo: pans right-to-left and upward (sub-pixel offsets, as a real moving image would).
        let ox = Double(index) * panX, oy = Double(index) * panY
        ctx.draw(photo, in: CGRect(x: -ox, y: -oy, width: Double(photo.width), height: Double(photo.height)))

        for col in columns {
            ctx.saveGState()
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(col.rect.insetBy(dx: -16, dy: -16))
            ctx.clip(to: col.rect)
            // The text strip scrolls up: its top starts at the panel top and moves by `speed` px per frame.
            let scrolled = Double(index) * col.speed
            let stripH = Double(col.image.height)
            let y = col.rect.maxY - stripH + scrolled
            ctx.draw(col.image, in: CGRect(x: col.rect.minX, y: y, width: col.rect.width, height: stripH))
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: Assets

    private static func rgbContext(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }

    /// Smooth gradient sky plus a few hundred soft radial blobs, then per-pixel grain: photo-like mid and high
    /// frequency content, not a flat synthetic pattern.
    private static func makePhoto(width w: Int, height h: Int, grain: Int) -> CGImage {
        let ctx = rgbContext(w, h)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var rng = LCG(seed: 0x248)
        let sky = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.20, green: 0.35, blue: 0.62, alpha: 1), CGColor(red: 0.85, green: 0.72, blue: 0.55, alpha: 1),
            CGColor(red: 0.25, green: 0.38, blue: 0.20, alpha: 1)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: w / 3, y: 0), options: [])
        for _ in 0..<420 {
            let r = 20 + rng.unit() * 260
            let c = CGPoint(x: rng.unit() * Double(w), y: rng.unit() * Double(h))
            let col = CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 0.25 + rng.unit() * 0.5)
            let clear = col.copy(alpha: 0)!
            let g = CGGradient(colorsSpace: space, colors: [col, clear] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
        }
        // Thin "branches": antialiased strokes give edges like a real photo.
        ctx.setLineCap(.round)
        for _ in 0..<160 {
            ctx.setStrokeColor(CGColor(gray: rng.unit() * 0.4, alpha: 0.6))
            ctx.setLineWidth(1 + rng.unit() * 5)
            var p = CGPoint(x: rng.unit() * Double(w), y: rng.unit() * Double(h))
            ctx.move(to: p)
            for _ in 0..<6 {
                p = CGPoint(x: p.x + (rng.unit() - 0.5) * 220, y: p.y + (rng.unit() - 0.5) * 220)
                ctx.addLine(to: p)
            }
            ctx.strokePath()
        }
        // Grain: +-grain per channel.
        if let base = ctx.data {
            let stride = ctx.bytesPerRow
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<(w * 4) where x & 3 != 3 {
                    let v = Int(row[x]) + Int(rng.next() % UInt64(2 * grain + 1)) - grain
                    row[x] = UInt8(clamping: v)
                }
            }
        }
        return ctx.makeImage()!
    }

    /// A tall strip of black text lines (code-like and prose-like) on white.
    private static func makeText(width w: Int, height h: Int, font: String, size: CGFloat, seed: UInt64) -> CGImage {
        let ctx = rgbContext(w, h)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(true)
        let ctFont = CTFontCreateWithName(font as CFString, size, nil)
        let words = ["matebridge", "decoder", "frame", "the", "surface", "let", "var", "return", "pixel", "latency",
                     "stream", "func", "if", "else", "codec", "buffer", "queue", "display", "pen", "pressure", "tilt",
                     "0x2800", "1840", "{", "}", "=", "+=", "->", "//", "HEVC", "Annex-B", "keyframe", "slice"]
        var rng = LCG(seed: seed)
        let lineH = size * 1.45
        var y = CGFloat(h) - lineH
        var line = 0
        let colors = [CGColor(gray: 0.05, alpha: 1), CGColor(red: 0.1, green: 0.25, blue: 0.6, alpha: 1),
                      CGColor(red: 0.55, green: 0.1, blue: 0.15, alpha: 1)]
        while y > 0 {
            let indent = Int(rng.next() % 5) * 4
            var text = String(repeating: " ", count: indent)
            let n = 3 + Int(rng.next() % 9)
            for _ in 0..<n { text += words[Int(rng.next() % UInt64(words.count))] + " " }
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): colors[line % colors.count],
            ]
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            ctx.textPosition = CGPoint(x: 18, y: y)
            CTLineDraw(ctLine, ctx)
            y -= lineH
            line += 1
        }
        return ctx.makeImage()!
    }
}

/// Small deterministic PRNG (the clips must be reproducible).
struct LCG {
    private var s: UInt64
    init(seed: UInt64) { s = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return s >> 33
    }
    mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
}
