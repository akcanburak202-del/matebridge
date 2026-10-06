/// Duration statistics in microseconds, built from nanosecond samples. Used for per-call cost and tick jitter.
public struct DurationStats: Equatable, Sendable {
    public let count: Int
    public let minUs: Double
    public let p50Us: Double
    public let p99Us: Double
    public let maxUs: Double
    public let meanUs: Double

    public init?(nanoseconds: [UInt64]) {
        guard !nanoseconds.isEmpty else { return nil }
        let sorted = nanoseconds.sorted()
        func pick(_ q: Double) -> Double {
            let idx = Int((Double(sorted.count - 1) * q).rounded())
            return Double(sorted[idx]) / 1000
        }
        count = sorted.count
        minUs = Double(sorted[0]) / 1000
        maxUs = Double(sorted[sorted.count - 1]) / 1000
        p50Us = pick(0.5)
        p99Us = pick(0.99)
        meanUs = Double(sorted.reduce(0, +)) / Double(sorted.count) / 1000
    }

    /// One-line summary, e.g. `n=2000 min=0.9 p50=1.2 p99=3.4 max=20.1 mean=1.4 us`.
    public var summary: String {
        "n=\(count) min=\(f(minUs)) p50=\(f(p50Us)) p99=\(f(p99Us)) max=\(f(maxUs)) mean=\(f(meanUs)) us"
    }
}

/// One decimal, locale independent (rounds half away from zero; negative values are not needed here).
public func f(_ v: Double) -> String {
    let tenths = Int((v * 10).rounded())
    return "\(tenths / 10).\(abs(tenths % 10))"
}
