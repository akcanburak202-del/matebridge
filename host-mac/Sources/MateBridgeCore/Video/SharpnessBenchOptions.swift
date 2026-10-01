import Foundation

/// Arguments of `MateBridgeApp --sharpness-bench [--fps N] [--motion-frames N] [--shift-px N] [--static-ms N]
/// [--resume-frames N] [--refresh-buffer same|copy]` (T-086, T-087). The encoder knobs come from the same environment
/// variables as the app (`MATEBRIDGE_*`).
public struct SharpnessBenchOptions: Equatable, Sendable {
    public static let motionFramesRange: ClosedRange<Int> = 1...1200

    public var fps = 120
    /// Frames of scrolling before the content stops. T-087: 240 (2 s at 120 fps), so the rate control has settled as in
    /// a running session. With T-086's 30 frames the opening keyframe's bit debt starved the motion frames, and the
    /// idle refresh looked far more useful than it is in a running session.
    public var motionFrames = 240
    /// Vertical scroll per motion frame, in pixels.
    public var shiftPx = 6
    /// How long the bench waits on the static content (no new captures) before measuring `static_end`.
    public var staticMs = 600
    /// Frames of scrolling after the static stretch (T-087: shows whether the refresh left the encoder as it was).
    public var resumeFrames = 0
    /// Overrides `MATEBRIDGE_IDLE_REFRESH_BUFFER` (nil: the environment decides).
    public var refreshBuffer: IdleRefreshBuffer?

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
        func buffer() -> Result<Void, ParseError> {
            guard j + 1 < args.count, let b = IdleRefreshBuffer(rawValue: args[j + 1].lowercased()) else {
                return .failure(ParseError(message: "--refresh-buffer needs same or copy"))
            }
            j += 1
            o.refreshBuffer = b
            return .success(())
        }
        while j < args.count {
            let r: Result<Void, ParseError>
            switch args[j] {
            case "--fps": r = value("--fps", 1...240).map { o.fps = $0 }
            case "--motion-frames": r = value("--motion-frames", motionFramesRange).map { o.motionFrames = $0 }
            case "--shift-px": r = value("--shift-px", 1...64).map { o.shiftPx = $0 }
            case "--static-ms": r = value("--static-ms", 0...10_000).map { o.staticMs = $0 }
            case "--resume-frames":
                r = value("--resume-frames", 0...motionFramesRange.upperBound).map { o.resumeFrames = $0 }
            case "--refresh-buffer": r = buffer()
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
