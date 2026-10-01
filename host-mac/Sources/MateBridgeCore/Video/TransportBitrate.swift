import Foundation

/// Origin of the bitrate a session runs with (`bitrate_source=` in the logs).
public enum BitrateSource: String, Equatable, Sendable {
    /// The stream-mode default (`defaultBitrateKbps`, or the HELLO default before any `STREAM_PREFS`).
    case prefs
    /// `MATEBRIDGE_BITRATE_KBPS` (T-086): wins over everything.
    case env
    /// `MATEBRIDGE_WIFI_BITRATE_KBPS` on a Wi-Fi session (T-088).
    case wifiEnv = "wifi_env"
    /// The tablet's `STREAM_PREFS.bitrate_kbps` (decision 0013, T-106): wins over the mode default, loses to env.
    case user
}

extension VideoSettings {
    /// Transport-dependent knobs (T-088), applied after `applyingExperimentKnobs`. On a Wi-Fi (non-loopback) session
    /// `MATEBRIDGE_WIFI_BITRATE_KBPS` (5 000...150 000, same range as `MATEBRIDGE_BITRATE_KBPS`) replaces the
    /// stream-mode default and survives later `STREAM_PREFS` like the env bitrate does. `MATEBRIDGE_BITRATE_KBPS`
    /// wins when both are set. USB sessions, and an absent or invalid value, leave `self` unchanged.
    public func applyingTransportKnobs(_ env: [String: String], transport: SessionTransport) -> VideoSettings {
        guard transport == .network, bitrateOverrideKbps == nil,
              let kbps = Self.parseBitrateKbps(env["MATEBRIDGE_WIFI_BITRATE_KBPS"]) else { return self }
        var s = self
        s.bitrateKbps = kbps
        s.bitrateOverrideKbps = kbps
        s.bitrateOverrideSource = .wifiEnv
        return s
    }
}
