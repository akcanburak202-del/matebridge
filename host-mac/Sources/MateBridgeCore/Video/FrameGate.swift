/// Host-side guard that keeps the send rate at or below the stream fps (T-017).
///
/// ScreenCaptureKit runs with `minimumFrameInterval` = 1 / (2 x stream fps) so it never discards a frame that
/// arrives a hair early. That allows bursts faster than the stream fps; this gate spaces accepted frames by at least
/// `minGapUs`. A frame that arrives too early is not dropped: the caller holds it as the single pending frame
/// (newest wins) and submits it after `waitUs`, so a static screen never ends on a stale image.
public struct FrameGate: Sendable {
    /// Fraction of the stream frame interval that must pass between two accepted frames. Below 1 so that ordinary
    /// arrival jitter does not delay frames, above 0.5 so a 2x burst is still spaced out.
    public static let defaultGapFraction = 0.75

    public let minGapUs: UInt64
    public private(set) var lastAcceptedUs: UInt64?

    public init(streamFps: Int, gapFraction: Double = FrameGate.defaultGapFraction) {
        let interval = 1_000_000 / UInt64(max(1, streamFps))
        minGapUs = UInt64(Double(interval) * gapFraction)
    }

    /// Microseconds a frame captured at `ptsUs` must still wait; 0 = accept now.
    public func waitUs(forPtsUs ptsUs: UInt64) -> UInt64 {
        guard let last = lastAcceptedUs, ptsUs >= last else { return 0 }
        let elapsed = ptsUs - last
        return elapsed >= minGapUs ? 0 : minGapUs - elapsed
    }

    public mutating func accept(ptsUs: UInt64) { lastAcceptedUs = ptsUs }
}
