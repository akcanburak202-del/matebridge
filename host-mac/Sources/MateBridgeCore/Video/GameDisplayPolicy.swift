/// Game display (decision 0029, PROTOCOL.md 0x05 host rules): a 1x virtual display at a requested pixel size instead
/// of the native HiDPI display. Pure: no clock, no I/O.
public enum GameDisplayPolicy {
    /// Largest aspect difference to the native display: `|w·H − h·W| ≤ 0.005·h·W`.
    public static let aspectTolerance = 0.005

    /// Whether the host honours a requested game display `w x h` for a tablet whose native (HELLO) size is
    /// `nativeW x nativeH`: both non-zero and even, `native/2 ≤ size ≤ native` per edge, and the aspect within
    /// `aspectTolerance` of the native one. Anything else counts as 0x0 (the native display; not a protocol error).
    public static func accepts(w: Int, h: Int, nativeW: Int, nativeH: Int) -> Bool {
        guard w > 0, h > 0, w % 2 == 0, h % 2 == 0, nativeW > 0, nativeH > 0 else { return false }
        guard 2 * w >= nativeW, w <= nativeW, 2 * h >= nativeH, h <= nativeH else { return false }
        let diff = abs(Double(w) * Double(nativeH) - Double(h) * Double(nativeW))
        return diff <= aspectTolerance * Double(h) * Double(nativeW)
    }

    /// The game display size of `prefs` for this native size, or nil for the native display (0x0 or not accepted).
    public static func size(of prefs: StreamPrefs, nativeW: Int, nativeH: Int) -> (w: Int, h: Int)? {
        let w = Int(prefs.displayWidthPx), h = Int(prefs.displayHeightPx)
        return accepts(w: w, h: h, nativeW: nativeW, nativeH: nativeH) ? (w, h) : nil
    }

    /// What became of a request's `display_*` (log field `game_display=` of `ev=stream_prefs`).
    public enum Outcome: String, Equatable, Sendable {
        /// 0x0: the native display was asked for.
        case none
        case applied
        /// Not accepted by `accepts` (counted as 0x0; not a protocol error).
        case rejected
        /// Valid, but game displays are off for this process after `game_display_failed`.
        case disabled

        public var logName: String { rawValue }
    }

    public static func outcome(of prefs: StreamPrefs, nativeW: Int, nativeH: Int, allowed: Bool) -> Outcome {
        if prefs.displayWidthPx == 0 && prefs.displayHeightPx == 0 { return .none }
        guard size(of: prefs, nativeW: nativeW, nativeH: nativeH) != nil else { return .rejected }
        return allowed ? .applied : .disabled
    }
}

/// The mode of a virtual display: what decides whether an existing display can be kept for new settings.
public struct DisplayMode: Equatable, Sendable {
    public var widthPx: Int
    public var heightPx: Int
    public var hidpi: Bool
    public var refreshHz: Int
    /// The transfer function the display's mode was requested with (T-232, decision 0032): 0 = the legacy SDR mode,
    /// 1 = HDR (an HDR10 stream, or the `MATEBRIDGE_VD_TRANSFER` developer knob).
    public var transfer: UInt32
    /// The primaries the display's descriptor was created with (T-281): fixed at creation like the transfer function.
    public var primaries: VirtualDisplayPrimaries.Choice

    public init(widthPx: Int, heightPx: Int, hidpi: Bool, refreshHz: Int, transfer: UInt32 = 0,
                primaries: VirtualDisplayPrimaries.Choice = .default) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.hidpi = hidpi
        self.refreshHz = refreshHz
        self.transfer = transfer
        self.primaries = primaries
    }

    /// `2800x1840@2x` / `1848x1214@1x` (the refresh rate is logged separately).
    public var text: String { "\(widthPx)x\(heightPx)@\(hidpi ? 2 : 1)x" }

    /// Same pixel size and HiDPI (the refresh rate may differ).
    public func sameKind(as other: DisplayMode) -> Bool {
        widthPx == other.widthPx && heightPx == other.heightPx && hidpi == other.hidpi
    }
}

/// Whether a display handed over to a new pipeline (live mode change T-049, parked display T-165) can be kept. Only an
/// exact match is kept: ScreenCaptureKit keeps delivering at the creation rate after an in-place mode switch (T-049),
/// a different pixel size or HiDPI is a different display mode (decision 0029), and capture on an offline display
/// only fails (T-165).
public enum DisplayReuse {
    public enum Reason: String, Equatable, Sendable {
        /// Pixel size or HiDPI differs (native <-> game display, or another game size).
        case modeChange = "mode_change"
        case refreshChange = "refresh_change"
        /// The transfer function differs (SDR <-> HDR10 stream, decision 0032): the mode's EOTF is fixed at creation.
        /// T-281: also reported when only the primaries differ (fixed at creation too; they follow the transfer
        /// function, so that case is unreachable in practice).
        case transferChange = "transfer_change"
        /// Same mode, but the display went offline while it was parked (display sleep).
        case offline

        public var logName: String { rawValue }
    }

    public enum Decision: Equatable, Sendable {
        case reuse
        /// Remove the display, wait `DisplayRecreateGap`, create a new one.
        case recreate(Reason)
    }

    public static func decide(current: DisplayMode, online: Bool, wanted: DisplayMode) -> Decision {
        if !current.sameKind(as: wanted) { return .recreate(.modeChange) }
        if current.refreshHz != wanted.refreshHz { return .recreate(.refreshChange) }
        if current.transfer != wanted.transfer || current.primaries != wanted.primaries {
            return .recreate(.transferChange)
        }
        return online ? .reuse : .recreate(.offline)
    }
}

/// A virtual display with the same vendor/product/serial cannot be created right after the previous one was removed;
/// the system needs about 700 ms to finish removing it (T-049). Every new display waits out the rest of that gap.
public enum DisplayRecreateGap {
    public static let gapUs: UInt64 = 700_000

    /// How long to wait before creating a display at `nowUs`, the last one having been removed at `lastRemovedUs`
    /// (same clock; nil = none removed yet). A clock that went backwards waits the full gap.
    public static func remainingUs(lastRemovedUs: UInt64?, nowUs: UInt64, gapUs: UInt64 = gapUs) -> UInt64 {
        guard let last = lastRemovedUs else { return 0 }
        guard nowUs >= last else { return gapUs }
        let elapsed = nowUs - last
        return elapsed >= gapUs ? 0 : gapUs - elapsed
    }
}

/// The first `STREAM_CONFIG` each connection was told at HELLO (`streamConfig(for:)`), kept until that connection's
/// session is activated. The session machine sends that config at HELLO but the session's settings are derived again
/// at activation (after proof, for a reconnect). In between, the inputs can change: `game_display_failed` may switch
/// game displays off (T-214), or the previous session may store other prefs (T-049). Comparing both tells the owner to
/// announce a new `config_id` before the pipeline starts, so the announced config never disagrees with the pipeline.
///
/// Records are per connection, not per device: overlapping reconnects of one tablet can each be told a different
/// config. The connection is identified by its HELLO (`Key`: device + `client_nonce`, 16 fresh random bytes per
/// connection, PROTOCOL.md 9); the session machine hands the coordinator the same HELLO value at both points.
public struct AnnouncedStreamConfigs: Sendable {
    /// One connection's HELLO.
    public struct Key: Hashable, Sendable {
        public var deviceID: DeviceID
        public var clientNonce: [UInt8]

        public init(_ hello: Hello) {
            deviceID = hello.deviceID
            clientNonce = hello.clientNonce
        }
    }

    /// At most this many connections are remembered, oldest dropped first (HELLOs that never become a session, and
    /// connections that close before their proof, must not grow memory). A dropped record makes its activation
    /// re-announce (see `activationDiffers`), so eviction never hides a mismatch.
    public static let capacity = 64
    private var entries: [(key: Key, config: StreamConfig)] = []

    public init() {}

    public var count: Int { entries.count }

    /// `config` was announced for the connection that sent `hello` (replaces an older record of the same connection).
    public mutating func record(_ config: StreamConfig, for hello: Hello) {
        let key = Key(hello)
        entries.removeAll { $0.key == key }
        entries.append((key, config))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// The session of the connection that sent `hello` is activated with `activation` (its settings' `STREAM_CONFIG`
    /// under the session's `config_id`). True when the owner must announce `activation` under a new `config_id`
    /// before starting the pipeline: the config this connection was told differs (`differs`), or there is no record
    /// of it (evicted, or never recorded), so what it was told is unknown. Consumes this connection's record only.
    public mutating func activationDiffers(hello: Hello, activation: StreamConfig) -> Bool {
        let key = Key(hello)
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return true }
        let announced = entries.remove(at: index).config
        return Self.differs(announced, activation)
    }

    /// Two configs differ for the tablet: in anything but `config_id` and `bitrate_kbps` (the tablet does not use the
    /// first config's bitrate, and the transport knobs are applied only at activation).
    public static func differs(_ a: StreamConfig, _ b: StreamConfig) -> Bool {
        var a = a
        a.configID = b.configID
        a.bitrateKbps = b.bitrateKbps
        return a != b
    }
}

/// One fallback to the native display when a 1x game display cannot be set up (PROTOCOL.md 0x05,
/// `game_display_failed`). After the first failure no game display is offered again for the rest of the process.
public struct GameDisplayFallback: Equatable, Sendable {
    public private(set) var failed = false

    public init() {}

    /// Game displays may be derived (`VideoSettings.applying(_:allowGameDisplay:)`).
    public var allowsGameDisplay: Bool { !failed }

    /// A pipeline failed to start. Returns true when the caller must re-apply the prefs without the game display:
    /// the pipeline ran a game display and the failure concerns the display (not, e.g., a missing permission). The
    /// fallback settings are the native display, which never falls back again, so there is exactly one attempt.
    public mutating func startFailed(settings: VideoSettings, displayFailure: Bool) -> Bool {
        guard !settings.displayHiDPI, displayFailure else { return false }
        failed = true
        return true
    }

    /// Settings derived earlier (a session start waiting in the mailbox) re-checked against the current state: a game
    /// display derived before game displays were switched off becomes the native display, with the same `prefs`
    /// re-applied without it (and with `allowHDR`, so a switched-off HDR path stays off). nil = `settings` are still
    /// valid.
    public func revalidated(_ settings: VideoSettings, base: VideoSettings, prefs: StreamPrefs?,
                            allowHDR: Bool = true) -> VideoSettings? {
        guard !settings.displayHiDPI, !allowsGameDisplay else { return nil }
        guard let prefs else { return base }
        return base.applying(prefs, allowGameDisplay: false, allowHDR: allowHDR)
    }
}
