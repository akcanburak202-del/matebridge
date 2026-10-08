import Foundation
@testable import MateBridgeCore

/// CPU reference of the T-235 chroma pass: sRGB-encoded `BGRA` -> full-range BT.709 8-bit 4:2:0 (`420f`), with or
/// without a per-pixel luma adjustment ("sharp YUV"; Ström, Samuelsson, Dovstam, "Luma Adjustment for High Dynamic
/// Range Video", DCC 2016; libwebp `sharpyuv`). Research `docs/research/2026-10-05-yuv444.md` §3b.
///
/// At a saturated edge (red on grey) 4:2:0 averages chroma across the edge, so the RGB a decoder rebuilds from a
/// pixel's own Y' and the averaged chroma has the wrong luminance: light and dark dots along the edge. The adjusted
/// Y' of each pixel is chosen so that, with the chroma the decoder will upsample at that pixel, the rebuilt pixel has
/// the source's linear luminance. Hue fringes (~1 px) remain.
///
/// The Metal kernel (`SharpYUVKernel.metalSource`) implements exactly these steps in `Float`; XCTest compares the two
/// (within one code value: `pow` and rounding ties may differ on the GPU).
///
/// Definitions (shared with the kernel):
/// - Y' = 0.2126 R' + 0.7152 G' + 0.0722 B'; Cb' = (B' - Y') / 1.8556; Cr' = (R' - Y') / 1.5748 (R'G'B' in 0...1).
/// - Full-range codes: Y = floor(255 Y' + 0.5), C = floor(255 C' + 128 + 0.5), clamped to 0...255.
/// - Chroma: the mean Cb'/Cr' of the 2x2 block (pixels past the edge repeat the last column/row), i.e. centred siting.
/// - Decoder model: R' = Y' + 1.5748 Cr', G' = Y' - 0.187324 Cb' - 0.468124 Cr', B' = Y' + 1.8556 Cb', each clamped
///   to 0...1, then the sRGB EOTF (`eotfTable`, interpolated); luminance = 0.2126 R + 0.7152 G + 0.0722 B (linear).
/// - Chroma upsampling at a pixel: `nearest` = its own block (T-302 removed the bilinear model, decision 0033).
/// - Flat pixels keep the plain Y code: every contributing chroma sample equals the pixel's own chroma code (the decoder
///   then sees the pixel's own chroma; most of a desktop, and it skips the search there).
/// - Adjusted Y: the code 0...255 whose rebuilt luminance is closest to the source's (integer bisection on the
///   monotonic luminance; ties go to the lower code). The kernel gallops out from the plain Y code instead of bisecting
///   0...255; on a monotonic function both find the same code, in ~3 evaluations on flat content instead of 10.
extension SharpYUV {
    static let kr: Float = 0.2126, kg: Float = 0.7152, kb: Float = 0.0722
    static let crToR: Float = 1.5748, cbToG: Float = 0.187324, crToG: Float = 0.468124, cbToB: Float = 1.8556

    /// One 8-bit 4:2:0 image: `y` is `width x height`, `cbcr` interleaved Cb, Cr at `chromaWidth x chromaHeight`.
    struct Planes: Equatable, Sendable {
        let width: Int
        let height: Int
        var y: [UInt8]
        var cbcr: [UInt8]

        var chromaWidth: Int { (width + 1) / 2 }
        var chromaHeight: Int { (height + 1) / 2 }

        init(width: Int, height: Int, y: [UInt8], cbcr: [UInt8]) {
            self.width = width
            self.height = height
            self.y = y
            self.cbcr = cbcr
        }
    }

    /// `bgra`: tightly packed `width x height x 4` bytes (B, G, R, A). `adjustFor` nil = plain 4:2:0 (each pixel's own
    /// Y'), otherwise luma adjusted for that decoder upsampling.
    static func convert(bgra: [UInt8], width: Int, height: Int, adjustFor: Upsample?) -> Planes {
        precondition(width > 0 && height > 0 && bgra.count >= width * height * 4)
        let cw = (width + 1) / 2, ch = (height + 1) / 2
        var cbcr = [UInt8](repeating: 128, count: cw * ch * 2)
        for j in 0..<ch {
            for i in 0..<cw {
                var cb: Float = 0, cr: Float = 0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let x = min(2 * i + dx, width - 1), y = min(2 * j + dy, height - 1)
                        let p = rgb(bgra, x, y, width)
                        let yp = kr * p.r + kg * p.g + kb * p.b
                        cb += (p.b - yp) / cbToB
                        cr += (p.r - yp) / crToR
                    }
                }
                cbcr[(j * cw + i) * 2] = chromaCode(cb * 0.25)
                cbcr[(j * cw + i) * 2 + 1] = chromaCode(cr * 0.25)
            }
        }
        var planes = Planes(width: width, height: height, y: [UInt8](repeating: 0, count: width * height), cbcr: cbcr)
        for y in 0..<height {
            for x in 0..<width {
                let p = rgb(bgra, x, y, width)
                let plain = code(kr * p.r + kg * p.g + kb * p.b)
                guard let up = adjustFor else { planes.y[y * width + x] = plain; continue }
                let c = upsampledChroma(planes, x: x, y: y, up)
                // Flat: the decoder sees this pixel's own chroma, so 4:2:0 adds no luma error to correct.
                if let u = c.uniform, u == ownChromaCodes(p) {
                    planes.y[y * width + x] = plain
                } else {
                    planes.y[y * width + x] = adjustedLuma(target: luminance(p.r, p.g, p.b), cb: c.cb, cr: c.cr)
                }
            }
        }
        return planes
    }

    /// The code 0...255 whose rebuilt luminance (with chroma `cb`, `cr` in -0.5...0.5) is closest to `target`.
    static func adjustedLuma(target: Float, cb: Float, cr: Float) -> UInt8 {
        var lo = 0, hi = 255
        while lo < hi {
            let mid = (lo + hi) / 2
            if rebuiltLuminance(yCode: mid, cb: cb, cr: cr) < target { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0 {
            let above = rebuiltLuminance(yCode: lo, cb: cb, cr: cr) - target
            let below = target - rebuiltLuminance(yCode: lo - 1, cb: cb, cr: cr)
            if below <= above { lo -= 1 }
        }
        return UInt8(lo)
    }

    static func rebuiltLuminance(yCode: Int, cb: Float, cr: Float) -> Float {
        let rgb = rebuild(y: Float(yCode) / 255, cb: cb, cr: cr)
        return luminance(rgb.r, rgb.g, rgb.b)
    }

    /// Decoder model: R'G'B' (clamped to 0...1) from Y' and chroma.
    static func rebuild(y: Float, cb: Float, cr: Float) -> (r: Float, g: Float, b: Float) {
        (clamp01(y + crToR * cr), clamp01(y - cbToG * cb - crToG * cr), clamp01(y + cbToB * cb))
    }

    /// The pixel's own chroma codes (what a 4:4:4 chroma sample at this pixel would be).
    static func ownChromaCodes(_ p: (r: Float, g: Float, b: Float)) -> [Float] {
        let yp = kr * p.r + kg * p.g + kb * p.b
        return [Float(chromaCode((p.b - yp) / cbToB)), Float(chromaCode((p.r - yp) / crToR))]
    }

    /// Chroma (Cb', Cr' in -0.5...0.5) the decoder sees at luma pixel (x, y); `uniform` holds the (Cb, Cr) codes when
    /// every chroma sample that contributes is the same (then the upsampled chroma is exactly that code).
    static func upsampledChroma(_ p: Planes, x: Int, y: Int, _ up: Upsample) -> (cb: Float, cr: Float, uniform: [Float]?) {
        let cw = p.chromaWidth, ch = p.chromaHeight
        func at(_ i: Int, _ j: Int) -> (Float, Float) {
            let ii = min(max(i, 0), cw - 1), jj = min(max(j, 0), ch - 1)
            return (Float(p.cbcr[(jj * cw + ii) * 2]), Float(p.cbcr[(jj * cw + ii) * 2 + 1]))
        }
        let i = x >> 1, j = y >> 1
        switch up {
        case .nearest:
            let c = at(i, j)
            return ((c.0 - 128) / 255, (c.1 - 128) / 255, [c.0, c.1])
        }
    }

    /// What a decoder with upsampling `up` displays: R'G'B' per pixel (3 floats, 0...1).
    static func reconstruct(_ p: Planes, upsample up: Upsample) -> [Float] {
        var out = [Float](repeating: 0, count: p.width * p.height * 3)
        for y in 0..<p.height {
            for x in 0..<p.width {
                let c = upsampledChroma(p, x: x, y: y, up)
                let rgb = rebuild(y: Float(p.y[y * p.width + x]) / 255, cb: c.cb, cr: c.cr)
                let o = (y * p.width + x) * 3
                out[o] = rgb.r; out[o + 1] = rgb.g; out[o + 2] = rgb.b
            }
        }
        return out
    }

    /// PSNR (dB, peak 100) of CIE L* between the source `bgra` and a reconstruction (`reconstruct`); `.infinity` when
    /// identical. The "lightness" error that luma adjustment removes.
    static func lightnessPSNR(source bgra: [UInt8], width: Int, height: Int, reconstructed: [Float]) -> Double {
        var se = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let s = rgb(bgra, x, y, width)
                let o = (y * width + x) * 3
                let a = lightness(exactLuminance(s.r, s.g, s.b))
                let b = lightness(exactLuminance(reconstructed[o], reconstructed[o + 1], reconstructed[o + 2]))
                se += Double((a - b) * (a - b))
            }
        }
        let mse = se / Double(width * height)
        return mse == 0 ? .infinity : 10 * log10(100 * 100 / mse)
    }

    /// CIE L* (0...100) of a relative luminance.
    static func lightness(_ y: Float) -> Float {
        let e: Float = 216.0 / 24389.0, k: Float = 24389.0 / 27.0
        return y > e ? 116 * Foundation.cbrt(y) - 16 : k * y
    }

    /// The EOTF as the pass computes it: `eotfTable` interpolated linearly (error < 1e-6).
    static func linear(_ v: Float) -> Float {
        let c = clamp01(v) * Float(eotfTableSize - 1)
        let i = min(Int(c), eotfTableSize - 2)
        let f = c - Float(i)
        return eotfTable[i] + f * (eotfTable[i + 1] - eotfTable[i])
    }

    /// Linear luminance as the pass computes it (table EOTF).
    static func luminance(_ r: Float, _ g: Float, _ b: Float) -> Float {
        kr * linear(r) + kg * linear(g) + kb * linear(b)
    }

    /// Linear luminance with the exact EOTF (the PSNR metric).
    static func exactLuminance(_ r: Float, _ g: Float, _ b: Float) -> Float {
        kr * srgbToLinear(r) + kg * srgbToLinear(g) + kb * srgbToLinear(b)
    }

    static func rgb(_ bgra: [UInt8], _ x: Int, _ y: Int, _ width: Int) -> (r: Float, g: Float, b: Float) {
        let o = (y * width + x) * 4
        return (Float(bgra[o + 2]) / 255, Float(bgra[o + 1]) / 255, Float(bgra[o]) / 255)
    }

    static func code(_ v: Float) -> UInt8 { UInt8(min(max((255 * v + 0.5).rounded(.down), 0), 255)) }
    static func chromaCode(_ c: Float) -> UInt8 { UInt8(min(max((255 * c + 128 + 0.5).rounded(.down), 0), 255)) }
}
