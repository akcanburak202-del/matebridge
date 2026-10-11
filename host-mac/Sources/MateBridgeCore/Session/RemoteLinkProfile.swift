// Remote (least data) link profile, decision 0038 section 3, docs/PROTOCOL.md 0x05 "Uzak profil" and section 6.
// Pure: no clock, no I/O. `STREAM_PREFS.link = 1` selects it for the session, per the last applied STREAM_PREFS;
// until one arrives the normal timings apply.

public enum RemoteLinkProfile {
    /// Host PING interval of an active control connection (normal: 500 ms, `SessionMachine.Configuration`).
    public static let hostPingIntervalUs: UInt64 = 2_000_000
    /// Silence after which the host closes the connection (normal: 5 s). The release-all silence stays 1.5 s:
    /// a held key must still be let go (AGENTS.md, input state never gets stuck).
    public static let closeSilenceUs: UInt64 = 15_000_000
    /// `CURSOR_STATE` keep-alive interval (normal: 500 ms).
    public static let cursorKeepAliveUs: UInt64 = 2_000_000
    /// Still-screen refinement train budget and video socket low-water mark: this long at the target bit rate.
    public static let byteWindowMs = 250
    /// ... but never below this many bytes.
    public static let minBytes = 16 * 1024

    /// `byteWindowMs` of `bitrateKbps` in bytes, at least `minBytes`. `bitrateKbps <= 0` gives `minBytes`.
    public static func bytes(bitrateKbps: Int) -> Int {
        max(minBytes, max(0, bitrateKbps) * 1000 / 8 * byteWindowMs / 1000)
    }

    /// Whether the session's `STREAM_PREFS` may be remembered per device (T-049): a remote session never writes the
    /// remembered preference, so the next ordinary connection does not open with the remote settings.
    public static func persistsPrefs(_ prefs: StreamPrefs) -> Bool { !prefs.isRemote }
}
