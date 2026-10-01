import Foundation

/// 8-bit luma plane: `width` x `height` samples, rows `stride` bytes apart.
public struct LumaPlane: Sendable {
    public var width: Int
    public var height: Int
    public var stride: Int
    public var data: [UInt8]

    public init(width: Int, height: Int, stride: Int? = nil, data: [UInt8]) {
        self.width = width
        self.height = height
        self.stride = stride ?? width
        self.data = data
    }

    public subscript(x: Int, y: Int) -> UInt8 { data[y * stride + x] }
}

/// Full-reference image quality for `--sharpness-bench` (T-086). Pure, no dependencies.
public enum ImageQuality {
    /// PSNR of the luma plane in dB over the common area. `infinity` for identical planes.
    public static func psnr(_ a: LumaPlane, _ b: LumaPlane) -> Double {
        let w = min(a.width, b.width), h = min(a.height, b.height)
        guard w > 0, h > 0 else { return 0 }
        var sum: UInt64 = 0
        a.data.withUnsafeBufferPointer { pa in
            b.data.withUnsafeBufferPointer { pb in
                for y in 0..<h {
                    let ra = y * a.stride, rb = y * b.stride
                    var row: UInt64 = 0
                    for x in 0..<w {
                        let d = Int(pa[ra + x]) - Int(pb[rb + x])
                        row &+= UInt64(d * d)
                    }
                    sum &+= row
                }
            }
        }
        if sum == 0 { return .infinity }
        let mse = Double(sum) / Double(w * h)
        return 10 * log10(255 * 255 / mse)
    }

    /// Mean SSIM over non-overlapping `window` x `window` blocks (uniform weights, C1 = (0.01 L)^2,
    /// C2 = (0.03 L)^2, L = 255). Partial blocks at the right/bottom edge are skipped. 1 for identical planes.
    /// `a` is the reference: with `minReferenceVariance` > 0 only blocks whose reference variance reaches it count
    /// (e.g. text and lines, not the flat page background); 0 when no block qualifies.
    public static func ssim(_ a: LumaPlane, _ b: LumaPlane, window: Int = 8, minReferenceVariance: Double = 0) -> Double {
        let w = min(a.width, b.width), h = min(a.height, b.height)
        guard window > 0, w >= window, h >= window else { return 0 }
        let c1 = (0.01 * 255) * (0.01 * 255), c2 = (0.03 * 255) * (0.03 * 255)
        let n = Double(window * window)
        var total = 0.0
        var blocks = 0
        a.data.withUnsafeBufferPointer { pa in
            b.data.withUnsafeBufferPointer { pb in
                var by = 0
                while by + window <= h {
                    var bx = 0
                    while bx + window <= w {
                        var sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0
                        for y in by..<(by + window) {
                            let ra = y * a.stride, rb = y * b.stride
                            for x in bx..<(bx + window) {
                                let va = Int(pa[ra + x]), vb = Int(pb[rb + x])
                                sa += va; sb += vb; saa += va * va; sbb += vb * vb; sab += va * vb
                            }
                        }
                        let ma = Double(sa) / n, mb = Double(sb) / n
                        let va = Double(saa) / n - ma * ma, vb = Double(sbb) / n - mb * mb
                        let cov = Double(sab) / n - ma * mb
                        bx += window
                        if minReferenceVariance > 0, va < minReferenceVariance { continue }
                        total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                        blocks += 1
                    }
                    by += window
                }
            }
        }
        return blocks > 0 ? total / Double(blocks) : 0
    }
}
