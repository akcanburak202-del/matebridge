/// The test pattern (T-230): vertical bands of known luma code values, neutral chroma.
public enum Bands {
    /// Luma code values written into the input buffer, left to right.
    public static let values: [UInt8] = [0, 8, 16, 32, 64, 128, 235, 255]
    /// Neutral chroma (Cb = Cr = 128).
    public static let neutralChroma: UInt8 = 128
    /// Pixels skipped at each band edge when measuring (compression rings at the band boundaries).
    public static let edgeMargin = 48

    /// Band index for column `x` of a `width`-wide frame.
    public static func band(x: Int, width: Int) -> Int {
        min(values.count - 1, x * values.count / max(width, 1))
    }

    /// Columns of band `index`: `[start, end)`.
    public static func columns(index: Int, width: Int) -> Range<Int> {
        let n = values.count
        let start = (index * width + n - 1) / n   // first x with band(x) == index
        let end = ((index + 1) * width + n - 1) / n
        return start..<min(end, width)
    }

    /// Columns measured for band `index`: the band without `edgeMargin` on each side (whole band if too narrow).
    public static func measuredColumns(index: Int, width: Int) -> Range<Int> {
        let c = columns(index: index, width: width)
        guard c.count > 2 * edgeMargin + 1 else { return c }
        return (c.lowerBound + edgeMargin)..<(c.upperBound - edgeMargin)
    }

    /// Rows measured: the middle half of the frame.
    public static func measuredRows(height: Int) -> Range<Int> {
        let r = (height / 4)..<(height - height / 4)
        return r.isEmpty ? 0..<height : r
    }

    /// Writes the band pattern into a luma plane.
    public static func fillLuma(_ p: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int) {
        var row = [UInt8](repeating: 0, count: width)
        for x in 0..<width { row[x] = values[band(x: x, width: width)] }
        for y in 0..<height {
            row.withUnsafeBufferPointer { (p + y * stride).update(from: $0.baseAddress!, count: width) }
        }
    }

    /// Writes neutral chroma into an interleaved CbCr plane (`width` bytes per row, `height` rows).
    public static func fillChroma(_ p: UnsafeMutablePointer<UInt8>, widthBytes: Int, height: Int, stride: Int) {
        for y in 0..<height { (p + y * stride).update(repeating: neutralChroma, count: widthBytes) }
    }

    /// Luma statistics of one band.
    public struct Stat: Equatable, Sendable {
        public var median: UInt8
        public var min: UInt8
        public var max: UInt8
        public init(median: UInt8, min: UInt8, max: UInt8) { self.median = median; self.min = min; self.max = max }
        /// `median` alone when flat, else `median (min-max)`.
        public var text: String { min == max ? "\(median)" : "\(median) (\(min)-\(max))" }
    }

    /// Per-band luma statistics over the measured area of a luma plane.
    public static func measureLuma(_ p: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> [Stat] {
        let rows = measuredRows(height: height)
        return values.indices.map { i in
            var hist = [Int](repeating: 0, count: 256)
            let cols = measuredColumns(index: i, width: width)
            for y in rows {
                let row = p + y * stride
                for x in cols { hist[Int(row[x])] += 1 }
            }
            return stat(histogram: hist)
        }
    }

    /// Median (lower median), min and max of a 256-bin histogram. All zero for an empty histogram.
    public static func stat(histogram h: [Int]) -> Stat {
        let total = h.reduce(0, +)
        guard total > 0 else { return Stat(median: 0, min: 0, max: 0) }
        let lo = h.firstIndex { $0 > 0 }!
        let hi = h.lastIndex { $0 > 0 }!
        var acc = 0, med = 0
        for (v, c) in h.enumerated() {
            acc += c
            if acc * 2 >= total { med = v; break }
        }
        return Stat(median: UInt8(med), min: UInt8(lo), max: UInt8(hi))
    }
}
