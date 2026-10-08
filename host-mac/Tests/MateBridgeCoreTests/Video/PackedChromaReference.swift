import Foundation
@testable import MateBridgeCore

/// Full-resolution 8-bit planes (4:4:4), row-major, no padding.
struct Planes444: Equatable, Sendable {
    let width: Int
    let height: Int
    var y: [UInt8]
    var cb: [UInt8]
    var cr: [UInt8]

    init(width: Int, height: Int) {
        let n = width * height
        self.width = width
        self.height = height
        y = [UInt8](repeating: 0, count: n)
        cb = y
        cr = y
    }
}

/// An 8-bit 4:2:0 picture with separate Cb and Cr planes (`width / 2 x height / 2` each).
struct Planes420: Equatable, Sendable {
    let width: Int
    let height: Int
    var y: [UInt8]
    var cb: [UInt8]
    var cr: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        y = [UInt8](repeating: 0, count: width * height)
        cb = [UInt8](repeating: 0, count: (width / 2) * (height / 2))
        cr = cb
    }
}

/// CPU reference of the AVC444v2 sample layout (decision 0034; MS-RDPEGFX 3.3.8.3.3, FreeRDP `prim_YUV.c`; ported from the T-255 probe
/// `probes/yuv444-probe`), the reference `PackedChromaKernel` is compared with. `width % 4 == 0`, `height % 2 == 0`.
///
/// Main view (an ordinary 4:2:0 picture): Y = Y444; Cb, Cr = the (even column, even row) chroma sample (`pick`).
/// Auxiliary view (a 4:2:0 picture carrying the other 3/4 of Cb and Cr):
/// - aux Y, left half (x < W/2): Cb444[2x + 1, y]; right half: Cr444[2(x - W/2) + 1, y] (all odd columns)
/// - aux Cb, left half (x < W/4): Cb444[4x, 2j + 1]; right half: Cr444[4(x - W/4), 2j + 1]
/// - aux Cr, left half: Cb444[4x + 2, 2j + 1]; right half: Cr444[4(x - W/4) + 2, 2j + 1]
extension AVC444v2 {
    static func pack(_ p: Planes444) -> (main: Planes420, aux: Planes420) {
        let w = p.width, h = p.height
        precondition(isValid(width: w, height: h), "AVC444v2 needs width % 4 == 0 and height % 2 == 0")
        let cw = w / 2, ch = h / 2, q = w / 4
        var main = Planes420(width: w, height: h)
        var aux = Planes420(width: w, height: h)
        main.y = p.y
        for j in 0..<ch {
            for i in 0..<cw {
                main.cb[j * cw + i] = p.cb[2 * j * w + 2 * i]
                main.cr[j * cw + i] = p.cr[2 * j * w + 2 * i]
            }
        }
        for y in 0..<h {
            for x in 0..<cw {
                aux.y[y * w + x] = p.cb[y * w + 2 * x + 1]
                aux.y[y * w + cw + x] = p.cr[y * w + 2 * x + 1]
            }
        }
        for j in 0..<ch {
            let row = (2 * j + 1) * w
            for x in 0..<q {
                aux.cb[j * cw + x] = p.cb[row + 4 * x]
                aux.cr[j * cw + x] = p.cb[row + 4 * x + 2]
                aux.cb[j * cw + q + x] = p.cr[row + 4 * x]
                aux.cr[j * cw + q + x] = p.cr[row + 4 * x + 2]
            }
        }
        return (main, aux)
    }

    static func unpack(main: Planes420, aux: Planes420) -> Planes444 {
        let w = main.width, h = main.height
        precondition(aux.width == w && aux.height == h && isValid(width: w, height: h))
        let cw = w / 2, ch = h / 2, q = w / 4
        var out = Planes444(width: w, height: h)
        out.y = main.y
        for y in 0..<h {
            for x in 0..<cw {
                out.cb[y * w + 2 * x + 1] = aux.y[y * w + x]
                out.cr[y * w + 2 * x + 1] = aux.y[y * w + cw + x]
            }
        }
        for j in 0..<ch {
            let row = (2 * j + 1) * w
            for x in 0..<q {
                out.cb[row + 4 * x] = aux.cb[j * cw + x]
                out.cb[row + 4 * x + 2] = aux.cr[j * cw + x]
                out.cr[row + 4 * x] = aux.cb[j * cw + q + x]
                out.cr[row + 4 * x + 2] = aux.cr[j * cw + q + x]
            }
        }
        for j in 0..<ch {
            for i in 0..<cw {
                out.cb[2 * j * w + 2 * i] = main.cb[j * cw + i]
                out.cr[2 * j * w + 2 * i] = main.cr[j * cw + i]
            }
        }
        return out
    }

    /// BT.709 full-range Y'CbCr codes of sRGB-encoded `bgra` (`stride` bytes per row), the maths of the kernel:
    /// Y = floor(255 Y' + 0.5), C = floor(255 C' + 128.5), clamped. Float arithmetic like the GPU (safe math).
    static func planes444(bgra: [UInt8], width: Int, height: Int, stride: Int) -> Planes444 {
        var out = Planes444(width: width, height: height)
        let kr: Float = 0.2126, kg: Float = 0.7152, kb: Float = 0.0722
        func code(_ v: Float, _ bias: Float) -> UInt8 { UInt8(min(max((255 * v + bias).rounded(.down), 0), 255)) }
        for y in 0..<height {
            for x in 0..<width {
                let o = y * stride + x * 4
                let b = Float(bgra[o]) / 255, g = Float(bgra[o + 1]) / 255, r = Float(bgra[o + 2]) / 255
                let yp = kr * r + kg * g + kb * b
                let i = y * width + x
                out.y[i] = code(yp, 0.5)
                out.cb[i] = code((b - yp) / 1.8556, 128.5)
                out.cr[i] = code((r - yp) / 1.5748, 128.5)
            }
        }
        return out
    }
}
