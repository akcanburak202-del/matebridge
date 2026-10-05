import Foundation

/// BT.709 full-range Y'CbCr maths shared by the CPU reference and the Metal kernel (`PackerKernel`): sRGB-encoded
/// R'G'B' in 0...1, Y' = 0.2126 R' + 0.7152 G' + 0.0722 B', Cb' = (B' - Y') / 1.8556, Cr' = (R' - Y') / 1.5748, codes
/// Y = floor(255 Y' + 0.5), C = floor(255 C' + 128.5), clamped to 0...255 (the same definitions as host `SharpYUV`).
public enum ColorMath {
    static let kr: Float = 0.2126, kg: Float = 0.7152, kb: Float = 0.0722
    static let crToR: Float = 1.5748, cbToG: Float = 0.187324, crToG: Float = 0.468124, cbToB: Float = 1.8556

    /// `bgra`: `height` rows of `stride` bytes (B, G, R, A per pixel; `stride >= width * 4`).
    public static func planes444(bgra: [UInt8], width: Int, height: Int, stride: Int? = nil) -> Planes444 {
        let stride = stride ?? width * 4
        var out = Planes444(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let o = y * stride + x * 4
                let b = Float(bgra[o]) / 255, g = Float(bgra[o + 1]) / 255, r = Float(bgra[o + 2]) / 255
                let yp = kr * r + kg * g + kb * b
                let i = y * width + x
                out.y[i] = code(yp)
                out.cb[i] = chromaCode((b - yp) / cbToB)
                out.cr[i] = chromaCode((r - yp) / crToR)
            }
        }
        return out
    }

    /// The R'G'B' (0...255 each, rounded and clamped) a decoder rebuilds from full-resolution planes.
    public static func rgb(_ p: Planes444) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: p.width * p.height * 3)
        for i in 0..<(p.width * p.height) {
            let y = Float(p.y[i]) / 255, cb = (Float(p.cb[i]) - 128) / 255, cr = (Float(p.cr[i]) - 128) / 255
            out[3 * i] = byte(y + crToR * cr)
            out[3 * i + 1] = byte(y - cbToG * cb - crToG * cr)
            out[3 * i + 2] = byte(y + cbToB * cb)
        }
        return out
    }

    /// The source `bgra` as tightly packed R, G, B bytes.
    public static func rgb(bgra: [UInt8], width: Int, height: Int, stride: Int? = nil) -> [UInt8] {
        let stride = stride ?? width * 4
        var out = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let o = y * stride + x * 4, i = y * width + x
                out[3 * i] = bgra[o + 2]
                out[3 * i + 1] = bgra[o + 1]
                out[3 * i + 2] = bgra[o]
            }
        }
        return out
    }

    /// A 4:2:0 picture as full-resolution planes, chroma upsampled.
    public static func upsample(_ p: Planes420, _ mode: ChromaUpsample) -> Planes444 {
        Planes444(width: p.width, height: p.height, y: p.y,
                  cb: upsamplePlane(p.cb, cw: p.chromaWidth, ch: p.chromaHeight, width: p.width, height: p.height, mode),
                  cr: upsamplePlane(p.cr, cw: p.chromaWidth, ch: p.chromaHeight, width: p.width, height: p.height, mode))
    }

    static func upsamplePlane(_ c: [UInt8], cw: Int, ch: Int, width: Int, height: Int, _ mode: ChromaUpsample) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let j = y >> 1
            let nj = min(max(y & 1 == 0 ? j - 1 : j + 1, 0), ch - 1)
            for x in 0..<width {
                let i = x >> 1
                switch mode {
                case .nearest:
                    out[y * width + x] = c[j * cw + i]
                case .bilinear:
                    // Centred siting: an even pixel sits 1/4 sample left of its block centre, an odd one 1/4 right.
                    let ni = min(max(x & 1 == 0 ? i - 1 : i + 1, 0), cw - 1)
                    let v = 9 * Int(c[j * cw + i]) + 3 * Int(c[j * cw + ni]) + 3 * Int(c[nj * cw + i]) + Int(c[nj * cw + ni])
                    out[y * width + x] = UInt8((v + 8) >> 4)
                }
            }
        }
        return out
    }

    static func code(_ v: Float) -> UInt8 { UInt8(min(max((255 * v + 0.5).rounded(.down), 0), 255)) }
    static func chromaCode(_ c: Float) -> UInt8 { UInt8(min(max((255 * c + 128 + 0.5).rounded(.down), 0), 255)) }
    static func byte(_ v: Float) -> UInt8 { UInt8(min(max((255 * v + 0.5).rounded(.down), 0), 255)) }
}

/// Chroma upsampling of a 4:2:0 picture to full resolution.
public enum ChromaUpsample: String, Sendable, CaseIterable {
    case nearest
    /// Centred-siting bilinear (weights 9/3/3/1 over 16).
    case bilinear
}
