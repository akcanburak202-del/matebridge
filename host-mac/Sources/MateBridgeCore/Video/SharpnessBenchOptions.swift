import Foundation

/// Arguments of `MateBridgeApp --sharpness-bench [--fps N] [--motion-frames N] [--shift-px N] [--static-ms N]`
/// (T-086). The encoder knobs come from the same environment variables as the app (`MATEBRIDGE_*`).
public struct SharpnessBenchOptions: Equatable, Sendable {
    public var fps = 120
    /// Frames of scrolling before the content stops.
    public var motionFrames = 30
    /// Vertical scroll per motion frame, in pixels.
    public var shiftPx = 6
    /// How long the bench waits on the static content (no new captures) before measuring `static_end`.
    public var staticMs = 600

    public typealias ParseError = EncodeBenchOptions.ParseError

    /// nil when `--sharpness-bench` is absent.
    public static func parse(_ args: [String]) -> Result<SharpnessBenchOptions, ParseError>? {
        guard args.contains("--sharpness-bench") else { return nil }
        var o = SharpnessBenchOptions()
        var j = 0
        func value(_ name: String, _ range: ClosedRange<Int>) -> Result<Int, ParseError> {
            guard j + 1 < args.count, let v = Int(args[j + 1]), range.contains(v) else {
                return .failure(ParseError(message: "\(name) needs an integer \(range.lowerBound)...\(range.upperBound)"))
            }
            j += 1
            return .success(v)
        }
        while j < args.count {
            let r: Result<Void, ParseError>
            switch args[j] {
            case "--fps": r = value("--fps", 1...240).map { o.fps = $0 }
            case "--motion-frames": r = value("--motion-frames", 1...240).map { o.motionFrames = $0 }
            case "--shift-px": r = value("--shift-px", 1...64).map { o.shiftPx = $0 }
            case "--static-ms": r = value("--static-ms", 0...10_000).map { o.staticMs = $0 }
            default: r = .success(())
            }
            if case .failure(let e) = r { return .failure(e) }
            j += 1
        }
        return .success(o)
    }

    /// The static wait is extended so an enabled idle refresh (delay + `count` frame intervals) completes in it,
    /// with 250 ms to spare for encode and decode.
    public func effectiveStaticMs(idleRefresh: IdleRefreshConfig) -> Int {
        guard idleRefresh.isEnabled else { return staticMs }
        let frames = idleRefresh.keyframe ? 1 : idleRefresh.count
        let needed = idleRefresh.delayMs + (frames * 1000 + fps - 1) / max(1, fps) + 250
        return max(staticMs, needed)
    }
}
