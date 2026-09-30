/// Host-side rules for `STREAM_PREFS` (T-049, docs/PROTOCOL.md 0x05). Pure: no clock, no I/O.
extension VideoSettings {
    /// Encoded width: `widthPx x scale`, rounded to an even number (at least 2).
    public var encodedWidthPx: Int { Self.encodedSize(widthPx, scalePermille: scalePermille) }

    /// Encoded height: follows the encoded width so the aspect ratio stays as close as even sizes allow.
    public var encodedHeightPx: Int {
        guard widthPx > 0 else { return Self.evenRounded(Double(heightPx)) }
        if scalePermille >= 1000 { return heightPx }
        return Self.evenRounded(Double(heightPx) * Double(encodedWidthPx) / Double(widthPx))
    }

    static func encodedSize(_ px: Int, scalePermille: Int) -> Int {
        scalePermille >= 1000 ? px : evenRounded(Double(px) * Double(scalePermille) / 1000)
    }

    static func evenRounded(_ v: Double) -> Int {
        max(2, Int((v / 2).rounded()) * 2)
    }

    /// Bitrate for a stream mode: 30 Mbps at 60 fps and full size, linear in fps, quadratic in the scale (pixel count),
    /// limited to 20...80 Mbps.
    public static func defaultBitrateKbps(fps: Int, scalePermille: Int) -> Int {
        let scale = Double(scalePermille) / 1000
        let kbps = 30_000 * Double(fps) / 60 * scale * scale
        return min(max(Int(kbps.rounded()), 20_000), 80_000)
    }

    /// The settings a session runs with after the tablet's `STREAM_PREFS`. The display size and point size never
    /// change. `defaultRefreshHz` is the refresh rate used for 60 fps (`MATEBRIDGE_REFRESH` or 60); 120 and 144 fps
    /// put the virtual display at the same rate.
    public func applying(_ prefs: StreamPrefs, defaultRefreshHz: Int = 60) -> VideoSettings {
        let p = prefs.normalized
        var s = self
        s.fps = Int(p.fps)
        s.scalePermille = Int(p.scalePermille)
        s.displayRefreshHz = s.fps >= 120 ? s.fps : defaultRefreshHz
        s.bitrateKbps = Self.defaultBitrateKbps(fps: s.fps, scalePermille: s.scalePermille)
        return s
    }
}

/// The next `config_id` after `id`: increments, never 0 (PROTOCOL.md: config_id starts at 1).
public func nextConfigID(after id: UInt16) -> UInt16 { id == UInt16.max ? 1 : id + 1 }

/// At most one reconfiguration per `minIntervalUs`; a request that arrives earlier waits and the newest wait wins.
public struct StreamPrefsGate: Sendable {
    public let minIntervalUs: UInt64
    private var lastAppliedUs: UInt64?
    private var pending: StreamPrefs?

    public init(minIntervalUs: UInt64 = 1_000_000) { self.minIntervalUs = minIntervalUs }

    public var hasPending: Bool { pending != nil }

    private func allowed(_ now: UInt64) -> Bool {
        guard let last = lastAppliedUs else { return true }
        return now >= last &+ minIntervalUs
    }

    /// A request arrived. Returns it if it may be tried now; otherwise it replaces the waiting one and nil is returned.
    public mutating func offer(_ prefs: StreamPrefs, now: UInt64) -> StreamPrefs? {
        if allowed(now) {
            pending = nil
            return prefs
        }
        pending = prefs
        return nil
    }

    /// Call periodically: returns the waiting request once the interval has passed.
    public mutating func poll(now: UInt64) -> StreamPrefs? {
        guard let p = pending, allowed(now) else { return nil }
        pending = nil
        return p
    }

    /// The caller really reconfigured (a request that changed nothing does not count).
    public mutating func markApplied(now: UInt64) { lastAppliedUs = now }
}
