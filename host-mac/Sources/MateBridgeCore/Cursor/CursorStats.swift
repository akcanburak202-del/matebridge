/// Counters of the local cursor flow for the once-a-second `ev=cursor_stats` line (docs/LOGGING.md). Counts, bytes and
/// times only: never a position or an image. A value type for one context.
public struct CursorStats: Sendable {
    public static let reportIntervalUs: UInt64 = 1_000_000
    /// Sample costs kept per window (120 Hz for a second, with room for the extra samples after injections).
    static let maxCostSamples = 512

    private var windowStartUs: UInt64?
    private var states = 0
    private var shapes = 0
    private var shapeBytes = 0
    private var shapesBuilt = 0
    private var shapeFailures = 0
    private var shapeChecks = 0
    private var samples = 0
    private var sampleFailures = 0
    private var costsUs: [UInt64] = []
    private var replacedBefore = 0

    public init() {}

    public mutating func recordState() { states += 1 }
    public mutating func recordShapeSent(bytes: Int) {
        shapes += 1
        shapeBytes += bytes
    }
    /// Shape work since the previous call, as deltas: `built` new shapes rendered and encoded (cache misses in the
    /// tracker, not sends), `failures` renders that failed, `checks` cursor image reads to compute the shape id (rate
    /// limited, T-309).
    public mutating func recordShapeWork(built: Int, failures: Int, checks: Int) {
        shapesBuilt += built
        shapeFailures += failures
        shapeChecks += checks
    }
    /// One poll or injection sample took `costUs`; `ok` false when the cursor could not be read.
    public mutating func recordSample(costUs: UInt64, ok: Bool) {
        samples += 1
        if !ok { sampleFailures += 1 }
        if costsUs.count < Self.maxCostSamples { costsUs.append(costUs) }
    }

    /// Once per interval, and only when something happened: the fields of `ev=cursor_stats`, then a fresh window.
    /// `replaced` is the outbox's running total of replaced units.
    public mutating func takeReport(nowUs: UInt64, replaced: Int) -> String? {
        guard let start = windowStartUs else {
            windowStartUs = nowUs
            replacedBefore = replaced
            return nil
        }
        guard nowUs >= start, nowUs - start >= Self.reportIntervalUs else { return nil }
        defer {
            windowStartUs = nowUs
            states = 0; shapes = 0; shapeBytes = 0; shapesBuilt = 0; shapeFailures = 0; shapeChecks = 0
            samples = 0; sampleFailures = 0
            costsUs.removeAll(keepingCapacity: true)
            replacedBefore = replaced
        }
        guard states + shapes + samples + shapeFailures > 0 else { return nil }
        return "states=\(states) shapes=\(shapes) shape_bytes=\(shapeBytes) shapes_built=\(shapesBuilt) "
            + "shape_failed=\(shapeFailures) shape_checks=\(shapeChecks) replaced=\(max(0, replaced - replacedBefore)) samples=\(samples) "
            + "sample_failed=\(sampleFailures) sample_us_p50=\(CadenceWindow.percentile(costsUs, 50)) "
            + "sample_us_p95=\(CadenceWindow.percentile(costsUs, 95))"
    }

    /// Starts a fresh window now (the flow was just turned on).
    public mutating func restart(nowUs: UInt64, replaced: Int) {
        self = CursorStats()
        windowStartUs = nowUs
        replacedBefore = replaced
    }
}
