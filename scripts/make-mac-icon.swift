#!/usr/bin/env swift
// Generates host-mac/Resources/AppIcon.icns from the master icon geometry (concept C "M line",
// docs/design/icon-master.svg). System frameworks only; deterministic (no dates, no randomness).
//
// Usage: swift scripts/make-mac-icon.swift [--out PATH.icns] [--preview DIR]
//   --out      output .icns                         (default: host-mac/Resources/AppIcon.icns)
//   --preview  also write icon_1024.png into DIR for visual review
//
// Mac icon grid: the tile is an 824 px continuous-corner rounded square centred on the 1024 canvas
// (corner radius 22.5 % of the tile), transparent outside. The master SVG's full-bleed 100x100 tile
// maps onto that 824 px tile, so every master unit is 8.24 px at 1024.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Master geometry (docs/design/icon-master.svg)

/// Glyph path in the 100x100 glyph box, y pointing down (SVG coordinates).
let glyphStart = CGPoint(x: 16, y: 74)
let glyphCurves: [(c1: CGPoint, c2: CGPoint, end: CGPoint)] = [
    (CGPoint(x: 20, y: 46), CGPoint(x: 26, y: 30), CGPoint(x: 34, y: 30)),
    (CGPoint(x: 42, y: 30), CGPoint(x: 44, y: 56), CGPoint(x: 50, y: 56)),
    (CGPoint(x: 56, y: 56), CGPoint(x: 58, y: 30), CGPoint(x: 66, y: 30)),
    (CGPoint(x: 74, y: 30), CGPoint(x: 80, y: 46), CGPoint(x: 84, y: 74)),
]
let glyphDot = CGPoint(x: 84, y: 74)
/// App glyph placement inside the 100x100 tile: translate(17 17) scale(0.66).
let glyphOffset: CGFloat = 17
let glyphScale: CGFloat = 0.66
let glyphStroke: CGFloat = 9
let glyphDotRadius: CGFloat = 6.75

func srgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let tileTop = srgb(0x121820)
let tileBottom = srgb(0x050608)
let glyphColor = srgb(0x7FE0D0)

// MARK: - Mac icon grid (fractions of the canvas edge)

let tileInset: CGFloat = 100.0 / 1024.0   // 824 px tile on a 1024 canvas
let cornerFraction: CGFloat = 0.225       // corner radius / tile edge

// MARK: - Drawing

/// Continuous-corner ("squircle-like") rounded rect, the well-known Bezier approximation of Apple's
/// continuous corner curve. `rect` is in a y-down space; the shape is symmetric so orientation does not matter.
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    let p = CGMutablePath()
    // Corner helpers: (dx, dy) measured inward from the given corner, in units of r.
    func tl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * r, y: rect.minY + y * r) }
    func tr(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * r, y: rect.minY + y * r) }
    func br(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * r, y: rect.maxY - y * r) }
    func bl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * r, y: rect.maxY - y * r) }
    // One corner, walked from the edge it leaves (a, 0) to the edge it joins (0, a) via the diagonal.
    func corner(_ f: (CGFloat, CGFloat) -> CGPoint, swap: Bool) {
        func q(_ a: CGFloat, _ b: CGFloat) -> CGPoint { swap ? f(b, a) : f(a, b) }
        p.addCurve(to: q(0.63149399, 0.07491100), control1: q(1.08849323, 0), control2: q(0.86840689, 0))
        p.addCurve(to: q(0.07491100, 0.63149399), control1: q(0.37282392, 0.16905899), control2: q(0.16905899, 0.37282392))
        p.addCurve(to: q(0, 1.52866483), control1: q(0, 0.86840701), control2: q(0, 1.08849299))
    }
    p.move(to: tl(1.52866483, 0))
    p.addLine(to: tr(1.52866483, 0))
    corner(tr, swap: false)
    p.addLine(to: br(0, 1.52866483))
    corner(br, swap: true)
    p.addLine(to: bl(1.52866483, 0))
    corner(bl, swap: false)
    p.addLine(to: tl(0, 1.52866483))
    corner(tl, swap: true)
    p.closeSubpath()
    return p
}

/// Renders the app icon at `px` x `px` pixels.
func renderIcon(px: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let size = CGFloat(px)
    // Work in a y-down space (like the SVG) so master coordinates apply unchanged.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    let tile = CGRect(x: size * tileInset, y: size * tileInset,
                      width: size * (1 - 2 * tileInset), height: size * (1 - 2 * tileInset))
    let shape = continuousRoundedRect(tile, radius: tile.width * cornerFraction)

    // Tile: vertical gradient, top → bottom.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [tileTop, tileBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
    ctx.restoreGState()

    // Glyph: 100-unit tile → tile rect, then the master's translate/scale.
    let unit = tile.width / 100
    ctx.saveGState()
    ctx.translateBy(x: tile.minX, y: tile.minY)
    ctx.scaleBy(x: unit, y: unit)
    ctx.translateBy(x: glyphOffset, y: glyphOffset)
    ctx.scaleBy(x: glyphScale, y: glyphScale)
    let path = CGMutablePath()
    path.move(to: glyphStart)
    for c in glyphCurves { path.addCurve(to: c.end, control1: c.c1, control2: c.c2) }
    ctx.addPath(path)
    ctx.setStrokeColor(glyphColor)
    ctx.setLineWidth(glyphStroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.setFillColor(glyphColor)
    ctx.fillEllipse(in: CGRect(x: glyphDot.x - glyphDotRadius, y: glyphDot.y - glyphDotRadius,
                               width: 2 * glyphDotRadius, height: 2 * glyphDotRadius))
    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot create \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

// MARK: - Main

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
var outURL = repoRoot.appendingPathComponent("host-mac/Resources/AppIcon.icns")
var previewDir: URL?
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--out": outURL = URL(fileURLWithPath: args.popFirst() ?? { fatalError("--out needs a path") }())
    case "--preview": previewDir = URL(fileURLWithPath: args.popFirst() ?? { fatalError("--preview needs a dir") }())
    default: fatalError("unknown option: \(arg)")
    }
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("matebridge-icon-\(getpid())")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

for points in [16, 32, 128, 256, 512] {
    writePNG(renderIcon(px: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(renderIcon(px: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if let previewDir {
    try fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
    writePNG(renderIcon(px: 1024), to: previewDir.appendingPathComponent("icon_1024.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", outURL.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed (\(iconutil.terminationStatus))") }
print("OK: \(outURL.path)")
