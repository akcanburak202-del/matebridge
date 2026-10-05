import Foundation

/// Error metrics for 8-bit planes.
public enum Metrics {
    /// PSNR in dB (peak 255); `.infinity` when identical (or when the mask selects nothing).
    public static func psnr(_ a: [UInt8], _ b: [UInt8], mask: [Bool]? = nil) -> Double {
        precondition(a.count == b.count)
        var se = 0.0, n = 0.0
        for i in 0..<a.count {
            if let mask, !mask[i] { continue }
            let d = Double(Int(a[i]) - Int(b[i]))
            se += d * d
            n += 1
        }
        guard n > 0, se > 0 else { return .infinity }
        return 10 * log10(255 * 255 / (se / n))
    }

    /// Largest absolute difference and the mean absolute difference.
    public static func absError(_ a: [UInt8], _ b: [UInt8]) -> (max: Int, mean: Double) {
        precondition(a.count == b.count)
        var mx = 0, sum = 0
        for i in 0..<a.count {
            let d = abs(Int(a[i]) - Int(b[i]))
            mx = Swift.max(mx, d)
            sum += d
        }
        return (mx, a.isEmpty ? 0 : Double(sum) / Double(a.count))
    }

    /// Pixels at a colour edge: a Cb or Cr step above `threshold` to the right or lower neighbour, marking both sides.
    /// These are the pixels 4:2:0 gets wrong; flat areas dilute a whole-frame PSNR.
    public static func colourEdgeMask(cb: [UInt8], cr: [UInt8], width: Int, height: Int, threshold: Int = 24) -> [Bool] {
        var m = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                var edge = false
                if x + 1 < width {
                    edge = abs(Int(cb[i]) - Int(cb[i + 1])) > threshold || abs(Int(cr[i]) - Int(cr[i + 1])) > threshold
                }
                if !edge, y + 1 < height {
                    edge = abs(Int(cb[i]) - Int(cb[i + width])) > threshold
                        || abs(Int(cr[i]) - Int(cr[i + width])) > threshold
                }
                if edge {
                    m[i] = true
                    if x + 1 < width { m[i + 1] = true }
                    if y + 1 < height { m[i + width] = true }
                }
            }
        }
        return m
    }

    /// `p` in 0...100 of `values` (nearest rank); 0 for an empty array.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let rank = Int((p / 100 * Double(s.count)).rounded(.up)) - 1
        return s[Swift.min(Swift.max(rank, 0), s.count - 1)]
    }

    public static func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }

    /// `"p50/p95/p99/max"` of a series, two decimals.
    public static func summary(_ values: [Double]) -> String {
        String(format: "%.2f/%.2f/%.2f/%.2f", percentile(values, 50), percentile(values, 95), percentile(values, 99),
               values.max() ?? 0)
    }

    public static func db(_ v: Double) -> String { v.isInfinite ? "inf" : String(format: "%.2f", v) }
}
