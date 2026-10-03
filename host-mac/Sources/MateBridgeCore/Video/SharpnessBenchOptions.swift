import Foundation

/// Arguments of `MateBridgeApp --sharpness-bench [--fps N] [--motion-frames N] [--shift-px N] [--static-ms N]
/// [--resume-frames N]` (T-086, T-087). The encoder knobs come from the same environment variables as the app
/// (`MATEBRIDGE_*`). T-204 removed `--refresh-buffer` with the idle quality refresh.
public struct SharpnessBenchOptions: Equatable, Sendable {
    public static let motionFramesRange: ClosedRange<Int> = 1...1200

    public var fps = 120
    /// Frames of scrolling before the content stops. T-087: 240 (2 s at 120 fps), so the rate control has settled as in
    /// a running session. With T-086's 30 frames the opening keyframe's bit debt starved the motion frames (and made
    /// the since retired idle refresh look far more useful than it was in a running session).
    public var motionFrames = 240
    /// Vertical scroll per motion frame, in pixels.
    public var shiftPx = 6
    /// How long the bench waits on the static content (no new captures) before measuring `static_end`.
    public var staticMs = 600
    /// Frames of scrolling after the static stretch (T-087: shows how the encoder resumes after a static stretch).
    public var resumeFrames = 0

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
            case "--motion-frames": r = value("--motion-frames", motionFramesRange).map { o.motionFrames = $0 }
            case "--shift-px": r = value("--shift-px", 1...64).map { o.shiftPx = $0 }
            case "--static-ms": r = value("--static-ms", 0...10_000).map { o.staticMs = $0 }
            case "--resume-frames":
                r = value("--resume-frames", 0...motionFramesRange.upperBound).map { o.resumeFrames = $0 }
            default: r = .success(())
            }
            if case .failure(let e) = r { return .failure(e) }
            j += 1
        }
        return .success(o)
    }
}
