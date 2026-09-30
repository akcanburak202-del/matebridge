/// Keeps the virtual display alive across short disconnects (NOTES 2026-09-29: the tablet is the main screen, so
/// windows must not be dumped onto another display when Wi-Fi blips). Pure and clock-free: `now` is monotonic
/// microseconds.
///
/// A session end starts a grace period (default 10 s). The same device coming back with the same settings reuses
/// the display; a different device or different settings replaces it; when the grace period runs out the display
/// is torn down.
public struct DisplayLease: Sendable {
    public static let defaultGraceUs: UInt64 = 10_000_000

    public enum Action: Equatable, Sendable {
        /// Tear down the current display and pipeline.
        case teardown
        /// Create a display and pipeline with these settings.
        case create(VideoSettings)
        /// Keep the existing display.
        case reuse
        /// Keep the display (same device and size) but restart capture and encoder with these settings (fps, scale,
        /// refresh rate changed; T-049).
        case reconfigure(VideoSettings)
    }

    private enum State: Equatable {
        case idle
        case active(DeviceID, VideoSettings)
        case grace(DeviceID, VideoSettings, deadline: UInt64)
    }

    public let graceUs: UInt64
    private var state = State.idle

    public init(graceUs: UInt64 = DisplayLease.defaultGraceUs) { self.graceUs = graceUs }

    public var hasDisplay: Bool { if case .idle = state { false } else { true } }
    public var isInGrace: Bool { if case .grace = state { true } else { false } }

    public mutating func sessionStarted(device: DeviceID, settings: VideoSettings) -> [Action] {
        switch state {
        case .idle:
            state = .active(device, settings)
            return [.create(settings)]
        case .active(let d, let s), .grace(let d, let s, _):
            state = .active(device, settings)
            guard d == device, s.sameDisplay(as: settings) else { return [.teardown, .create(settings)] }
            return s == settings ? [.reuse] : [.reconfigure(settings)]
        }
    }

    /// A live session changed its stream mode. No display work unless the settings really differ; the display size
    /// never changes this way (a different size would be replaced).
    public mutating func reconfigure(settings: VideoSettings) -> [Action] {
        guard case .active(let d, let s) = state else { return [] }
        guard s != settings else { return [] }
        state = .active(d, settings)
        return s.sameDisplay(as: settings) ? [.reconfigure(settings)] : [.teardown, .create(settings)]
    }

    /// The control session ended (or was taken over: a new `sessionStarted` follows).
    public mutating func sessionEnded(now: UInt64) {
        if case .active(let d, let s) = state { state = .grace(d, s, deadline: now &+ graceUs) }
    }

    public mutating func tick(now: UInt64) -> [Action] {
        guard case .grace(_, _, let deadline) = state, now >= deadline else { return [] }
        state = .idle
        return [.teardown]
    }

    /// The pipeline died on its own; nothing is left to tear down.
    public mutating func displayLost() { state = .idle }

    public mutating func shutdown() -> [Action] {
        defer { state = .idle }
        return hasDisplay ? [.teardown] : []
    }
}
