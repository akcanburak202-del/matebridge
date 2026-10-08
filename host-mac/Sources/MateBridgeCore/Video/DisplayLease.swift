import Foundation

/// Keeps the virtual display alive across disconnects (NOTES 2026-09-29: the tablet is the main screen, so windows
/// must not be dumped onto another display when Wi-Fi blips). Pure and clock-free: `now` is monotonic microseconds
/// (the coordinator passes a continuous clock, so the keep time is wall time, T-165).
///
/// A session end **parks** the display (T-165): capture and encoder stop at once, only the display stays alive for the
/// keep time (default 10 s, `MATEBRIDGE_DISPLAY_KEEP_S`). The same device coming back with the same native display
/// size gets the display back (`reuse` / `reconfigure`, the owner builds a new pipeline on the parked display); a
/// different device or native size replaces it; when the keep time runs out the display is torn down.
///
/// Display identity is device + native (HELLO) size (`VideoSettings.sameNative`). A different display mode of the
/// same identity (native HiDPI <-> 1x game display, decision 0029, or another refresh rate) is a `.reconfigure`: the
/// pipeline built for it decides whether the display can be kept (`DisplayReuse`) and otherwise removes it and waits
/// `DisplayRecreateGap` before creating the new one. `.teardown` + `.create` is only for another device or native
/// size.
public struct DisplayLease: Sendable {
    /// `MATEBRIDGE_DISPLAY_KEEP_S` bounds and default (T-165). The upper bound is one day.
    public static let defaultKeepSeconds = 10
    public static let defaultGraceUs = UInt64(defaultKeepSeconds) * 1_000_000
    public static let keepSecondsRange = 10...86_400

    public enum Action: Equatable, Sendable {
        /// Tear down the current display and pipeline (also a parked display). Why: `lastTeardownReason`.
        case teardown
        /// Create a display and pipeline with these settings.
        case create(VideoSettings)
        /// Keep the existing display. If it is parked, build a new pipeline on it with the session's settings.
        case reuse
        /// Keep the display identity (same device and native size) but restart capture and encoder with these settings
        /// (fps, scale, refresh rate, display mode changed; T-049, T-214). If it is parked, build a new pipeline on it
        /// with these settings. The pipeline recreates the display when its mode or refresh rate differs.
        case reconfigure(VideoSettings)
        /// The session ended: stop capture and encoder now, keep only the virtual display (T-165).
        case park
    }

    /// Why the last `.teardown` was returned (log field `reason=`).
    public enum TeardownReason: String, Equatable, Sendable {
        case keepExpired = "keep_expired"
        case deviceChanged = "device_changed"
        /// Another native (HELLO) size; a game display of the same tablet is not a size change.
        case sizeChanged = "size_changed"
        case shutdown

        public var logName: String { rawValue }
    }

    private enum State: Equatable {
        case idle
        case active(DeviceID, VideoSettings)
        case parked(DeviceID, VideoSettings, deadline: UInt64)
    }

    /// Keep time of a parked display, in microseconds (name kept from the grace period it replaces).
    public let graceUs: UInt64
    private var state = State.idle
    /// Set whenever a call returns `.teardown`; read by the owner right after that call.
    public private(set) var lastTeardownReason: TeardownReason?

    public init(graceUs: UInt64 = DisplayLease.defaultGraceUs) { self.graceUs = graceUs }

    public var hasDisplay: Bool { if case .idle = state { false } else { true } }
    public var isParked: Bool { if case .parked = state { true } else { false } }

    public mutating func sessionStarted(device: DeviceID, settings: VideoSettings) -> [Action] {
        switch state {
        case .idle:
            state = .active(device, settings)
            return [.create(settings)]
        case .active(let d, let s), .parked(let d, let s, _):
            state = .active(device, settings)
            guard d == device else { return teardownAndCreate(settings, .deviceChanged) }
            guard s.sameNative(as: settings) else { return teardownAndCreate(settings, .sizeChanged) }
            return s == settings ? [.reuse] : [.reconfigure(settings)]
        }
    }

    /// A live session changed its stream mode. No display work unless the settings really differ. A game display
    /// on/off or size change keeps the native size, so it is a `.reconfigure` (the pipeline recreates the display);
    /// a different native size would be replaced.
    public mutating func reconfigure(settings: VideoSettings) -> [Action] {
        guard case .active(let d, let s) = state else { return [] }
        guard s != settings else { return [] }
        state = .active(d, settings)
        return s.sameNative(as: settings) ? [.reconfigure(settings)] : teardownAndCreate(settings, .sizeChanged)
    }

    /// The control session ended (or was taken over: a new `sessionStarted` follows). Returns `[.park]` when a
    /// display was active; the keep time starts at `now`.
    @discardableResult
    public mutating func sessionEnded(now: UInt64) -> [Action] {
        guard case .active(let d, let s) = state else { return [] }
        state = .parked(d, s, deadline: now &+ graceUs)
        return [.park]
    }

    public mutating func tick(now: UInt64) -> [Action] {
        guard case .parked(_, _, let deadline) = state, now >= deadline else { return [] }
        state = .idle
        lastTeardownReason = .keepExpired
        return [.teardown]
    }

    /// The pipeline died on its own, or there was nothing to park; nothing is left to tear down.
    public mutating func displayLost() { state = .idle }

    public mutating func shutdown() -> [Action] {
        defer { state = .idle }
        guard hasDisplay else { return [] }
        lastTeardownReason = .shutdown
        return [.teardown]
    }

    private mutating func teardownAndCreate(_ settings: VideoSettings, _ reason: TeardownReason) -> [Action] {
        lastTeardownReason = reason
        return [.teardown, .create(settings)]
    }

    // MARK: Keep time (T-165)

    /// `MATEBRIDGE_DISPLAY_KEEP_S`: whole seconds in `keepSecondsRange`; anything else (missing, empty, non-numeric,
    /// out of range) is `defaultKeepSeconds`.
    public static func keepSeconds(_ text: String?) -> Int {
        guard let text, let v = Int(text.trimmingCharacters(in: .whitespaces)), keepSecondsRange.contains(v) else {
            return defaultKeepSeconds
        }
        return v
    }

    /// The keep time from the environment, in microseconds.
    public static func keepUs(env: [String: String]) -> UInt64 {
        UInt64(keepSeconds(env["MATEBRIDGE_DISPLAY_KEEP_S"])) * 1_000_000
    }
}
