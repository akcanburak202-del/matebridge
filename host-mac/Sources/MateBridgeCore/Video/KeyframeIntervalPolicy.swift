import Foundation

/// Periodic (safety) keyframe interval for the HEVC encoder (T-075).
///
/// Transport is TCP (reliable) and the client asks for keyframes on demand (STARTUP, DECODE_ERROR, queue drops),
/// so a periodic keyframe is only a long safety net. A 10 s interval cost a ~430 KB keyframe (slow decrypt and
/// decode on the tablet) every 10 s. Default 300 s: effectively never during a session, yet still bounds recovery
/// if a request is ever lost. `0` means keyframes only on request (VideoToolbox: 0 = no limit).
public enum KeyframeIntervalPolicy {
    public static let defaultSeconds = 300
    public static let maxSeconds = 3600

    /// `MATEBRIDGE_KEYFRAME_INTERVAL_S`: a non-negative integer (clamped to `maxSeconds`); anything else is the default.
    public static func resolve(_ value: String?) -> Int {
        guard let v = value?.trimmingCharacters(in: .whitespaces), let n = Int(v), n >= 0 else { return defaultSeconds }
        return min(n, maxSeconds)
    }

    public static func fromEnvironment() -> Int {
        resolve(ProcessInfo.processInfo.environment["MATEBRIDGE_KEYFRAME_INTERVAL_S"])
    }
}
