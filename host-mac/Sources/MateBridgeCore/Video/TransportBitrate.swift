import Foundation

/// Origin of the bitrate a session runs with (`bitrate_source=` in the logs).
public enum BitrateSource: String, Equatable, Sendable {
    /// The stream-mode default (`defaultBitrateKbps`, or the HELLO default before any `STREAM_PREFS`).
    case prefs
    /// `MATEBRIDGE_BITRATE_KBPS` (T-086): wins over everything.
    case env
    /// The tablet's `STREAM_PREFS.bitrate_kbps` (decision 0013, T-106): wins over the mode default, loses to env.
    case user
}
