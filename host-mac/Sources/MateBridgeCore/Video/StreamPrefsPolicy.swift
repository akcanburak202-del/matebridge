/// Host-side rules for `STREAM_PREFS` (T-049, T-214, docs/PROTOCOL.md 0x05). Pure: no clock, no I/O.
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

    /// Range a non-zero `STREAM_PREFS.bitrate_kbps` is clamped to (PROTOCOL.md 0x05, decision 0013).
    public static let userBitrateRangeKbps = 5_000...150_000

    /// `STREAM_PREFS.bitrate_kbps` as the host applies it: 0 = the mode default (nil), anything else clamped to
    /// `userBitrateRangeKbps`.
    public static func clampedUserBitrateKbps(_ raw: UInt32) -> Int? {
        guard raw != 0 else { return nil }
        return min(max(Int(raw), userBitrateRangeKbps.lowerBound), userBitrateRangeKbps.upperBound)
    }

    /// Scale of the encoded size relative to the native display, in permille: `scalePermille` on the native display;
    /// on a game display `1000 · encodedWidth / nativeWidth` (1848 of 2800 → 660), so the mode-default bitrate follows
    /// the encoded size the same way (PROTOCOL.md 0x05).
    public var effectiveScalePermille: Int {
        guard !displayHiDPI, nativeWidthPx > 0 else { return scalePermille }
        return Int((1000 * Double(encodedWidthPx) / Double(nativeWidthPx)).rounded())
    }

    /// The same settings on the native display (HELLO size, HiDPI): `self` unless a game display replaced it.
    var onNativeDisplay: VideoSettings {
        guard let n = replacedNative else { return self }
        var s = self
        s.widthPx = n.widthPx
        s.heightPx = n.heightPx
        s.widthPt = n.widthPt
        s.heightPt = n.heightPt
        s.replacedNative = nil
        return s
    }

    /// The settings a session runs with after the tablet's `STREAM_PREFS`. Without an accepted game display
    /// (`display_*` 0x0, rejected by `GameDisplayPolicy`, or `allowGameDisplay == false` after `game_display_failed`)
    /// the display is the native one: its size and point size never change, `scale_permille` sets the encoded size.
    /// With one (decision 0029) the display is `w x h` at 1x: points = pixels, the scale is ignored (encoded = display).
    /// Bitrate priority (decision 0013): `bitrateOverrideKbps` (env, T-086/T-088) > the tablet's `bitrate_kbps`
    /// (clamped, T-106) > the mode default (`effectiveScalePermille`). A change of the bitrate alone keeps the display
    /// mode and `displayRefreshHz`, so the virtual display is kept and only capture and encoder restart.
    /// The virtual display runs at 60 Hz below 120 fps; 120 and 144 fps put it at the same rate.
    /// `dynamic_range` (decision 0032): HDR10 when the tablet asks for it and `HDRPolicy` allows it (`allowHDR` false
    /// after an HDR failure in this process, or a non-HEVC codec, gives SDR). A change of it changes the display's
    /// transfer function, so the display is recreated (`DisplayReuse`).
    /// `chroma` (decision 0033): `chromaPreference` follows it on SDR and is `.normal` under HDR10; a change of it
    /// alone keeps the display (capture and encoder restart under a new `config_id`).
    /// `chroma = 2` (decision 0034, `FullChromaPolicy`): `.full` and `fullChromaGranted` only when the client has bit11,
    /// `fullChroma.prefsFromThisSession` (a remembered request counts as `chroma = 1`), the stream mode qualifies and
    /// `fullChroma.allowed` (no runtime fallback); a qualifying request after a fallback is `.normal` (not sharp),
    /// every other one is `.sharp`.
    public func applying(_ prefs: StreamPrefs,
                         allowGameDisplay: Bool = true, allowHDR: Bool = true,
                         fullChroma: FullChromaSession = FullChromaSession()) -> VideoSettings {
        let p = prefs.normalized
        var s = onNativeDisplay
        s.dynamicRange = HDRPolicy.decide(requested: p.requestedDynamicRange, codec: s.codec, allowed: allowHDR).applied
        // Decision 0033: ignored under HDR10 (re-applied without HDR after an `hdr_fallback`, so it then takes effect).
        s.chromaPreference = s.dynamicRange == .hdr10 ? .normal : p.requestedChroma
        s.fps = Int(p.fps)
        s.displayRefreshHz = s.fps >= 120 ? s.fps : 60
        if allowGameDisplay, let game = GameDisplayPolicy.size(of: p, nativeW: s.widthPx, nativeH: s.heightPx) {
            s.replacedNative = NativeDisplaySize(widthPx: s.widthPx, heightPx: s.heightPx,
                                                 widthPt: s.widthPt, heightPt: s.heightPt)
            s.widthPx = game.w
            s.heightPx = game.h
            s.widthPt = game.w
            s.heightPt = game.h
            s.scalePermille = 1000
        } else {
            s.scalePermille = Int(p.scalePermille)
        }
        s.fullChromaGranted = false
        s.fullChromaFellBack = false
        if s.chromaPreference == .full {
            if FullChromaPolicy.qualifies(s) && s.clientFullChroma && fullChroma.prefsFromThisSession {
                if fullChroma.allowed {
                    s.fullChromaGranted = true
                } else {
                    s.chromaPreference = .normal
                    s.fullChromaFellBack = true
                }
            } else {
                s.chromaPreference = .sharp
            }
        }
        s.userBitrateKbps = bitrateOverrideKbps == nil ? Self.clampedUserBitrateKbps(p.bitrateKbps) : nil
        s.bitrateKbps = bitrateOverrideKbps ?? s.userBitrateKbps
            ?? Self.defaultBitrateKbps(fps: s.fps, scalePermille: s.effectiveScalePermille)
        return s
    }
}

/// Session-level state of decision 0034's full colour that a `STREAM_PREFS` derivation needs.
public struct FullChromaSession: Equatable, Sendable {
    /// The prefs being applied arrived in this session (not remembered from an earlier one): only these may grant
    /// full colour (PROTOCOL.md 0x05, Codex T-257).
    public var prefsFromThisSession: Bool
    /// false after a runtime fallback (`chroma_fallback`) until the next stream mode change.
    public var allowed: Bool

    public init(prefsFromThisSession: Bool = false, allowed: Bool = true) {
        self.prefsFromThisSession = prefsFromThisSession
        self.allowed = allowed
    }
}

extension VideoSettings {
    /// Same stream mode: fps, encoded scale, display (size, HiDPI, game display) and dynamic range. Chroma and bitrate
    /// may differ. A change of mode retries a full colour that fell back (decision 0034).
    public func sameStreamMode(as other: VideoSettings) -> Bool {
        fps == other.fps && scalePermille == other.scalePermille && widthPx == other.widthPx
            && heightPx == other.heightPx && displayHiDPI == other.displayHiDPI && dynamicRange == other.dynamicRange
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
