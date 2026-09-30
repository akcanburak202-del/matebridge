import Foundation

/// Which VideoToolbox configuration the host encoder uses (T-047/T-053).
public enum EncoderProfile: String, Equatable, Sendable {
    /// Low-latency rate control + RealTime=true: smooth frame sizes, ~9-13 ms per frame at 2800x1840.
    case llrc
    /// No LLRC, RealTime=false: ~6 ms per frame.
    case fast

    /// `MATEBRIDGE_ENCODER`: "llrc" or "fast" (case-insensitive); anything else is nil (use the default).
    public static func parse(_ value: String?) -> EncoderProfile? {
        guard let v = value?.lowercased() else { return nil }
        return EncoderProfile(rawValue: v)
    }

    /// An explicit override wins; otherwise 120 fps and above needs `.fast` (LLRC tops out near 100 fps) and
    /// lower rates use `defaultProfile`.
    public static func resolve(fps: Int, override: EncoderProfile?, defaultProfile: EncoderProfile) -> EncoderProfile {
        override ?? (fps >= 120 ? .fast : defaultProfile)
    }
}
