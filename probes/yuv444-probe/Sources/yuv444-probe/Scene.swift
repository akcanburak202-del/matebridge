import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import YUV444Core

/// Deterministic synthetic "desktop" at 2800x1840 scene pixels, drawn as vectors (so smaller frame sizes are a true
/// re-rendering at that size, like a smaller virtual display): menu bar, wallpaper, saturated Dock icons, an IDE window
/// (dark theme, syntax-coloured Menlo text, line numbers), a document window (black text with thin red and blue words
/// and underlined links), a chart with thin coloured labels and a photo panel.
///
/// Four phases (`ScenePhase`, a quarter of the clip each): still, typing (one character per frame in the editor),
/// scroll (editor 12 px and document 8 px per frame) and video (the photo pans 3 / 1.5 px per frame, sub-pixel).
final class Scene {
    static let sceneWidth = 2800.0
    static let sceneHeight = 1840.0

    private let frames: Int
    private let ideLines: [NSAttributedString]
    private let docLines: [NSAttributedString]
    private let typedLines: [String]       // the three lines that get typed (editor lines 24...26)
    private let photo: CGImage
    private let ideLineHeight = 32.0
    private let docLineHeight = 30.0
    private let typedFirstLine = 24

    private static let ideFont = CTFontCreateWithName("Menlo" as CFString, 22, nil)
    private static let uiFont = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
    private static let smallFont = CTFontCreateWithName("Helvetica" as CFString, 16, nil)

    private static let colors: [String: CGColor] = [
        "plain": CGColor(gray: 0.90, alpha: 1),
        "keyword": CGColor(red: 0.99, green: 0.37, blue: 0.64, alpha: 1),
        "type": CGColor(red: 0.36, green: 0.85, blue: 1.0, alpha: 1),
        "string": CGColor(red: 0.99, green: 0.42, blue: 0.36, alpha: 1),
        "number": CGColor(red: 0.82, green: 0.75, blue: 0.41, alpha: 1),
        "comment": CGColor(red: 0.42, green: 0.47, blue: 0.52, alpha: 1),
    ]

    init(frames: Int, grain: Int = 4) {
        self.frames = frames
        var rng = LCG(seed: 0x255)
        let n = 40 + Int(Double(frames / 4) * 12 / 32) + 60
        ideLines = (0..<n).map { Scene.codeLine(&rng, index: $0) }
        typedLines = (0..<3).map { _ in Scene.codeLine(&rng, index: 99).string.trimmingCharacters(in: .whitespaces) }
        docLines = (0..<(30 + Int(Double(frames / 4) * 8 / 30) + 60)).map { Scene.docLine(&rng, index: $0) }
        let q = max(1, frames / 4)
        photo = Scene.makePhoto(width: 760 + Int(ceil(Double(q) * 3)) + 12, height: 710 + Int(ceil(Double(q) * 1.5)) + 12, grain: grain)
    }

    // MARK: Frame state

    private func phaseFrame(_ frame: Int, _ phase: ScenePhase) -> Int { max(0, min(frame - phase.start(frames: frames), frames / 4)) }

    /// Characters typed so far (typing phase 1 per frame, all of them afterwards).
    private func typedCount(_ frame: Int) -> Int {
        let total = typedLines.reduce(0) { $0 + $1.count }
        switch ScenePhase.of(frame: frame, frames: frames) {
        case .still: return 0
        case .typing: return min(total, phaseFrame(frame, .typing))
        default: return total
        }
    }

    // MARK: Drawing

    /// Draws `frame` into `ctx`, whose bitmap is `size` pixels (the scene is scaled to fit; top-left origin).
    func draw(frame: Int, into ctx: CGContext, size: FrameSize) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: CGFloat(Double(size.width) / Scene.sceneWidth), y: -CGFloat(Double(size.height) / Scene.sceneHeight))
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // glyphs upright in the flipped space
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(true)
        ctx.interpolationQuality = .medium
        let phase = ScenePhase.of(frame: frame, frames: frames)
        let scrollFrames = frame < ScenePhase.scroll.start(frames: frames) ? 0
            : phaseFrame(frame, .scroll)
        let videoFrames = phase == .video ? phaseFrame(frame, .video) : 0

        wallpaper(ctx)
        menuBar(ctx)
        ideWindow(ctx, frame: frame, scrollPx: Double(scrollFrames) * 12, typed: typedCount(frame),
                  caret: phase == .typing && (frame / 15) % 2 == 0)
        docWindow(ctx, scrollPx: Double(scrollFrames) * 8)
        mediaWindow(ctx, panX: Double(videoFrames) * 3, panY: Double(videoFrames) * 1.5)
        dock(ctx)
        ctx.restoreGState()
    }

    private func wallpaper(_ ctx: CGContext) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
            CGColor(red: 0.10, green: 0.16, blue: 0.35, alpha: 1), CGColor(red: 0.45, green: 0.20, blue: 0.40, alpha: 1),
            CGColor(red: 0.85, green: 0.45, blue: 0.30, alpha: 1)] as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: Scene.sceneWidth, y: Scene.sceneHeight), options: [])
    }

    private func menuBar(_ ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: 0.94, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Scene.sceneWidth, height: 56))
        var x = 40.0
        for (i, t) in ["MateBridge", "File", "Edit", "View", "Window", "Help"].enumerated() {
            x += text(ctx, t, font: Scene.uiFont, color: CGColor(gray: i == 0 ? 0 : 0.15, alpha: 1), at: CGPoint(x: x, y: 38)) + 36
        }
        // Status icons on the right: small saturated glyphs.
        let palette: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.1, 0.1), (0.1, 0.5, 0.95), (0.1, 0.7, 0.3), (0.95, 0.6, 0.0)]
        for (i, c) in palette.enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 2500 + Double(i) * 60, y: 14, width: 28, height: 28))
        }
        _ = text(ctx, "Mon 19:53", font: Scene.uiFont, color: CGColor(gray: 0.1, alpha: 1), at: CGPoint(x: 2720 - 140, y: 38))
    }

    private func windowChrome(_ ctx: CGContext, _ r: CGRect, title: String, dark: Bool) {
        ctx.setFillColor(CGColor(gray: dark ? 0.20 : 0.90, alpha: 1))
        let path = CGPath(roundedRect: r, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ctx.addPath(path); ctx.fillPath()
        for (i, c) in [(0.99, 0.37, 0.33), (0.99, 0.74, 0.18), (0.16, 0.78, 0.25)].enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: r.minX + 22 + Double(i) * 38, y: r.minY + 16, width: 24, height: 24))
        }
        _ = text(ctx, title, font: Scene.uiFont, color: CGColor(gray: dark ? 0.8 : 0.2, alpha: 1),
                 at: CGPoint(x: r.midX - 90, y: r.minY + 36))
    }

    private func ideWindow(_ ctx: CGContext, frame: Int, scrollPx: Double, typed: Int, caret: Bool) {
        let r = CGRect(x: 60, y: 100, width: 1420, height: 1550)
        windowChrome(ctx, r, title: "Renderer.swift", dark: true)
        let content = CGRect(x: r.minX, y: r.minY + 56, width: r.width, height: r.height - 56)
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(content)
        ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
        ctx.fill(CGRect(x: content.minX, y: content.minY, width: 90, height: content.height))
        ctx.saveGState()
        ctx.clip(to: content)
        let first = Int(scrollPx / ideLineHeight)
        let frac = scrollPx - Double(first) * ideLineHeight
        let visible = Int(content.height / ideLineHeight) + 2
        var typedLeft = typed
        for k in 0..<visible {
            let idx = first + k
            guard idx < ideLines.count else { break }
            let baseline = content.minY + 28 + Double(k) * ideLineHeight - frac
            _ = text(ctx, String(idx + 1), font: Scene.ideFont, color: CGColor(gray: 0.45, alpha: 1),
                     at: CGPoint(x: content.minX + 20, y: baseline))
            var caretX: Double? = nil
            if idx >= typedFirstLine && idx < typedFirstLine + 3 {
                // Typed lines: blank before, a growing prefix while typing, complete afterwards.
                let full = typedLines[idx - typedFirstLine]
                let shown = min(typedLeft, full.count)
                typedLeft -= shown
                if shown > 0 {
                    let w = textAttributed(ctx, Scene.attributed(String(full.prefix(shown))), at: CGPoint(x: content.minX + 110, y: baseline))
                    caretX = content.minX + 110 + w
                } else if typedLeft == 0 && idx == typedFirstLine { caretX = content.minX + 110 }
                if caret, let cx = caretX, shown < full.count || idx == typedFirstLine + 2 {
                    ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
                    ctx.fill(CGRect(x: cx + 2, y: baseline - 22, width: 3, height: 28))
                }
            } else {
                _ = textAttributed(ctx, ideLines[idx], at: CGPoint(x: content.minX + 110, y: baseline))
            }
        }
        ctx.restoreGState()
    }

    private func docWindow(_ ctx: CGContext, scrollPx: Double) {
        let r = CGRect(x: 1520, y: 100, width: 1220, height: 720)
        windowChrome(ctx, r, title: "Notes", dark: false)
        let content = CGRect(x: r.minX, y: r.minY + 56, width: r.width, height: r.height - 56)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(content)
        ctx.saveGState()
        ctx.clip(to: content)
        let first = Int(scrollPx / docLineHeight)
        let frac = scrollPx - Double(first) * docLineHeight
        for k in 0..<(Int(content.height / docLineHeight) + 2) {
            let idx = first + k
            guard idx < docLines.count else { break }
            _ = textAttributed(ctx, docLines[idx], at: CGPoint(x: content.minX + 36, y: content.minY + 34 + Double(k) * docLineHeight - frac))
        }
        ctx.restoreGState()
    }

    private func mediaWindow(_ ctx: CGContext, panX: Double, panY: Double) {
        let r = CGRect(x: 1520, y: 860, width: 1220, height: 790)
        windowChrome(ctx, r, title: "Media", dark: false)
        let content = CGRect(x: r.minX, y: r.minY + 56, width: r.width, height: r.height - 56)
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
        ctx.fill(content)
        // Photo panel (pans in the video phase).
        let panel = CGRect(x: content.minX + 20, y: content.minY + 20, width: 760, height: 710)
        ctx.saveGState()
        ctx.clip(to: panel)
        // The image is drawn flipped back upright inside the flipped space.
        ctx.translateBy(x: panel.minX - panX, y: panel.minY - panY + Double(photo.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(photo, in: CGRect(x: 0, y: 0, width: Double(photo.width), height: Double(photo.height)))
        ctx.restoreGState()
        // Chart: saturated bars, thin grid lines and thin coloured labels (red and blue, ~1 px strokes).
        let chart = CGRect(x: panel.maxX + 40, y: panel.minY, width: content.maxX - panel.maxX - 60, height: 710)
        ctx.setStrokeColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        ctx.setLineWidth(1)
        for i in 0...8 {
            let y = chart.minY + Double(i) * chart.height / 8
            ctx.move(to: CGPoint(x: chart.minX, y: y)); ctx.addLine(to: CGPoint(x: chart.maxX, y: y)); ctx.strokePath()
        }
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.1, 0.1), (0.1, 0.35, 0.9), (0.1, 0.7, 0.3), (0.95, 0.6, 0.0), (0.6, 0.2, 0.8)]
        for (i, c) in bars.enumerated() {
            let h = chart.height * [0.35, 0.8, 0.55, 0.9, 0.62][i]
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: chart.minX + 12 + Double(i) * 66, y: chart.maxY - h, width: 48, height: h))
            _ = text(ctx, "Q\(i + 1)", font: Scene.smallFont,
                     color: i % 2 == 0 ? CGColor(red: 0.8, green: 0, blue: 0.05, alpha: 1) : CGColor(red: 0, green: 0.25, blue: 0.85, alpha: 1),
                     at: CGPoint(x: chart.minX + 14 + Double(i) * 66, y: chart.maxY + 24))
        }
    }

    private func dock(_ ctx: CGContext) {
        let bar = CGRect(x: 520, y: 1690, width: 1760, height: 130)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.45))
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 34, cornerHeight: 34, transform: nil)); ctx.fillPath()
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.95, 0.15, 0.15), (0.98, 0.55, 0.05), (0.98, 0.85, 0.1), (0.2, 0.75, 0.3), (0.1, 0.75, 0.8), (0.1, 0.4, 0.95),
            (0.5, 0.25, 0.9), (0.95, 0.3, 0.6), (0.15, 0.15, 0.2), (0.9, 0.9, 0.95), (0.0, 0.55, 0.45), (0.8, 0.1, 0.35)]
        for (i, c) in palette.enumerated() {
            let r = CGRect(x: bar.minX + 28 + Double(i) * 144, y: bar.minY + 17, width: 96, height: 96)
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 24, cornerHeight: 24, transform: nil)); ctx.fillPath()
            ctx.setFillColor(CGColor(gray: i == 9 ? 0.2 : 1, alpha: 1))
            let g = r.insetBy(dx: 28, dy: 28)
            switch i % 3 {
            case 0: ctx.fillEllipse(in: g)
            case 1: ctx.fill(g)
            default:
                ctx.move(to: CGPoint(x: g.midX, y: g.minY)); ctx.addLine(to: CGPoint(x: g.maxX, y: g.maxY))
                ctx.addLine(to: CGPoint(x: g.minX, y: g.maxY)); ctx.closePath(); ctx.fillPath()
            }
        }
    }

    // MARK: Text helpers

    @discardableResult
    private func text(_ ctx: CGContext, _ s: String, font: CTFont, color: CGColor, at p: CGPoint) -> Double {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return textAttributed(ctx, NSAttributedString(string: s, attributes: attrs), at: p)
    }

    /// Draws a line with its baseline at `p`; returns its width.
    @discardableResult
    private func textAttributed(_ ctx: CGContext, _ s: NSAttributedString, at p: CGPoint) -> Double {
        let line = CTLineCreateWithAttributedString(s)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    // MARK: Content generation

    private static let keywords = ["let", "var", "func", "return", "if", "else", "guard", "for", "in", "while", "struct", "final", "class", "import"]
    private static let types = ["CVPixelBuffer", "MTLTexture", "Int", "UInt8", "Float", "FrameSize", "CMSampleBuffer", "Planes444", "String"]
    private static let idents = ["frame", "packer", "main", "aux", "stream", "width", "height", "queue", "buffer", "pixel", "decoder", "latency", "chroma", "plane"]

    static func attributed(_ s: String) -> NSAttributedString {
        // Colour by token class, re-derived from the text so a typed prefix colours like the full line.
        let out = NSMutableAttributedString()
        func add(_ t: String, _ cls: String) {
            out.append(NSAttributedString(string: t, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): ideFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): colors[cls]!,
            ]))
        }
        if s.trimmingCharacters(in: .whitespaces).hasPrefix("//") { add(s, "comment"); return out }
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            let cls: String
            if keywords.contains(token) { cls = "keyword" } else if types.contains(token) { cls = "type" }
            else if token.hasPrefix("\"") { cls = "string" } else if Int(token) != nil { cls = "number" } else { cls = "plain" }
            add(token, cls)
            token = ""
        }
        var inString = false
        for ch in s {
            if inString { token.append(ch); if ch == "\"" { flush(); inString = false }; continue }
            if ch == "\"" { flush(); token = "\""; inString = true; continue }
            if ch == " " || ch == "(" || ch == ")" || ch == "," || ch == ":" || ch == "." || ch == "{" || ch == "}" || ch == "=" {
                flush(); add(String(ch), "plain")
            } else { token.append(ch) }
        }
        flush()
        return out
    }

    private static func codeLine(_ rng: inout LCG, index: Int) -> NSAttributedString {
        let indent = String(repeating: " ", count: Int(rng.next() % 4) * 4)
        func pick(_ a: [String]) -> String { a[Int(rng.next() % UInt64(a.count))] }
        let kind = rng.next() % 6
        let body: String
        switch kind {
        case 0: body = "// \(pick(idents)) \(pick(idents)) update for frame \(rng.next() % 600)"
        case 1: body = "let \(pick(idents)) = \(pick(idents)).\(pick(idents))(\(pick(idents)): \(rng.next() % 4096))"
        case 2: body = "func \(pick(idents))(_ \(pick(idents)): \(pick(types))) -> \(pick(types)) {"
        case 3: body = "guard let \(pick(idents)) = \(pick(idents)) else { return \"\(pick(idents))_failed\" }"
        case 4: body = "for \(pick(idents)) in 0..<\(rng.next() % 2000) { \(pick(idents)) += \(rng.next() % 9) }"
        default: body = "return \(pick(idents)).\(pick(idents)) * \(rng.next() % 255) + \(pick(idents))"
        }
        return attributed(indent + body)
    }

    private static func docLine(_ rng: inout LCG, index: Int) -> NSAttributedString {
        let words = ["The", "stream", "keeps", "chroma", "sharp", "while", "the", "pen", "draws", "thin", "lines", "over", "text",
                     "colour", "edges", "decode", "frame", "budget", "latency", "tablet", "display", "pressure", "tilt", "and", "red", "blue"]
        let out = NSMutableAttributedString()
        let n = 7 + Int(rng.next() % 6)
        for k in 0..<n {
            let w = words[Int(rng.next() % UInt64(words.count))]
            let roll = rng.next() % 10
            let color: CGColor
            var underline = false
            switch roll {
            case 0: color = CGColor(red: 0.82, green: 0.0, blue: 0.05, alpha: 1)          // thin red
            case 1: color = CGColor(red: 0.0, green: 0.25, blue: 0.85, alpha: 1)          // thin blue
            case 2: color = CGColor(red: 0.0, green: 0.25, blue: 0.85, alpha: 1); underline = true  // link
            default: color = CGColor(gray: 0.05, alpha: 1)
            }
            var attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): uiFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            if underline { attrs[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: w + (k + 1 < n ? " " : ""), attributes: attrs))
        }
        return out
    }

    /// Smooth sky gradient, soft blobs, thin branches and light grain: photo-like mid and high frequencies.
    private static func makePhoto(width w: Int, height h: Int, grain: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        var rng = LCG(seed: 0x2255)
        let sky = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.20, green: 0.35, blue: 0.62, alpha: 1), CGColor(red: 0.85, green: 0.72, blue: 0.55, alpha: 1),
            CGColor(red: 0.25, green: 0.38, blue: 0.20, alpha: 1)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: Double(h)), end: CGPoint(x: Double(w) / 3, y: 0), options: [])
        for _ in 0..<260 {
            let r = 20 + rng.unit() * 200
            let c = CGPoint(x: rng.unit() * Double(w), y: rng.unit() * Double(h))
            let col = CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 0.25 + rng.unit() * 0.5)
            let g = CGGradient(colorsSpace: space, colors: [col, col.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
        }
        ctx.setLineCap(.round)
        for _ in 0..<120 {
            ctx.setStrokeColor(CGColor(gray: rng.unit() * 0.4, alpha: 0.6))
            ctx.setLineWidth(1 + rng.unit() * 4)
            var p = CGPoint(x: rng.unit() * Double(w), y: rng.unit() * Double(h))
            ctx.move(to: p)
            for _ in 0..<6 {
                p = CGPoint(x: p.x + (rng.unit() - 0.5) * 200, y: p.y + (rng.unit() - 0.5) * 200)
                ctx.addLine(to: p)
            }
            ctx.strokePath()
        }
        if let base = ctx.data {
            let stride = ctx.bytesPerRow
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<(w * 4) where x & 3 != 3 {
                    row[x] = UInt8(clamping: Int(row[x]) + Int(rng.next() % UInt64(2 * grain + 1)) - grain)
                }
            }
        }
        return ctx.makeImage()!
    }

    // MARK: Output

    /// Renders `frame` into a BGRA pixel buffer of `size`.
    func render(frame: Int, into pb: CVPixelBuffer, size: FrameSize) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: size.width, height: size.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        draw(frame: frame, into: ctx, size: size)
    }

    /// Writes `frame` as a PNG (reference image for the tablet side).
    func writePNG(frame: Int, size: FrameSize, to url: URL) throws {
        guard let ctx = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              true else { throw ProbeError("png context") }
        draw(frame: frame, into: ctx, size: size)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ProbeError("png destination") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ProbeError("png write") }
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
