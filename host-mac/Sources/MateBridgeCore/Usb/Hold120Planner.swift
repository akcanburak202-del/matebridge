import Foundation

/// Why the 120 Hz hold is off: the first broken condition, in this order (T-389, decision 0044). `rawValue` is the
/// `reason=` of `ev=hold120`.
public enum Hold120Reason: String, Equatable, Sendable {
    /// No USB tunnel up, or no adb serial known.
    case noDevice = "no_device"
    /// No session, or the session is not on USB (Wi-Fi, remote).
    case notUsb = "not_usb"
    /// No video connection is being served.
    case noVideo = "no_video"
    /// The game display (1x, decision 0029) is not in use.
    case notGame = "not_game"
    /// The stream is not 120 fps.
    case fpsNot120 = "fps_not_120"
}

/// The facts the hold needs (all must hold). The knob is not part of it: with the knob off nothing is constructed.
public struct Hold120Conditions: Equatable, Sendable {
    /// `UsbTunnelWatcher` reports the tunnels up and the device serial is known.
    public var deviceKnown: Bool
    /// The session's transport is USB.
    public var usbTransport: Bool
    /// A video sender is attached (frames are being sent).
    public var videoFlowing: Bool
    /// The game display (Oyun screen) is in use.
    public var gameScreen: Bool
    /// Stream (target) fps of the session.
    public var streamFps: Int

    public static let none = Hold120Conditions(deviceKnown: false, usbTransport: false, videoFlowing: false,
                                               gameScreen: false, streamFps: 0)

    public init(deviceKnown: Bool, usbTransport: Bool, videoFlowing: Bool, gameScreen: Bool, streamFps: Int) {
        self.deviceKnown = deviceKnown
        self.usbTransport = usbTransport
        self.videoFlowing = videoFlowing
        self.gameScreen = gameScreen
        self.streamFps = streamFps
    }

    public var firstBroken: Hold120Reason? {
        if !deviceKnown { return .noDevice }
        if !usbTransport { return .notUsb }
        if !videoFlowing { return .noVideo }
        if !gameScreen { return .notGame }
        if streamFps != 120 { return .fpsNot120 }
        return nil
    }
}

/// Which tablet messages count as real touch, pen or pointer input for the hold (T-389): a real touch already keeps
/// the panel at 120 Hz, so no fake tap is sent right after one. Keys do not count (a keyboard or gamepad does not wake
/// the panel). Never looks at the content of a message.
public enum Hold120Input {
    public static func counts(_ type: MessageType) -> Bool {
        switch type {
        case .pen, .pointerRel, .pointerAbs, .scroll, .penGesture, .pinch, .padSwipe: return true
        default: return false
        }
    }
}

/// Scheduler of the 120 Hz hold (T-389, decision 0044): when to send the next `input touchscreen tap 2 2`. Pure: the
/// caller passes the clock (microseconds) and executes the tap; at most one tap is in flight, a failed tap backs off
/// (2 s, then 5 s; a success resets), and a round is skipped while real input was seen in the last 1.5 s.
public struct Hold120Planner: Sendable {
    public static let intervalUs: UInt64 = 1_000_000
    public static let inputQuietUs: UInt64 = 1_500_000
    /// Wait after the 1st, then after every further consecutive failure.
    public static let backoffUs: [UInt64] = [2_000_000, 5_000_000]
    public static let statsIntervalUs: UInt64 = 30_000_000
    /// Deadline of one adb call.
    public static let tapTimeout: TimeInterval = 2

    public enum Action: Equatable, Sendable {
        /// The hold is off: no timer.
        case off
        /// A tap is running; its completion drives the next step.
        case waitForCompletion
        case sleep(untilUs: UInt64)
        /// Start one tap now; report it with `tapFinished`.
        case tap
    }

    public struct StateChange: Equatable, Sendable {
        public var on: Bool
        public var reason: Hold120Reason?
        /// `state=on` or `state=off reason=<reason>`.
        public var logFields: String { on ? "state=on" : "state=off reason=\((reason ?? .noDevice).rawValue)" }
    }

    public struct Stats: Equatable, Sendable {
        public var taps: Int
        public var skippedInput: Int
        public var failures: Int
        /// `taps= skipped_input= failures=` (totals since the controller started).
        public var logFields: String { "taps=\(taps) skipped_input=\(skippedInput) failures=\(failures)" }
    }

    public private(set) var isOn = false
    public private(set) var tapInFlight = false
    public private(set) var taps = 0
    public private(set) var skippedInput = 0
    public private(set) var failures = 0
    private var consecutiveFailures = 0
    private var nextDueUs: UInt64 = 0
    private var nextStatsUs: UInt64 = 0
    private var reported = false
    private var lastReason: Hold120Reason?

    public init() {}

    /// Applies the conditions; returns the state change to log (the first evaluation always reports, a change of the
    /// reason while off reports again). Going off resets the failure backoff but keeps the tap spacing, so flapping
    /// conditions cannot burst taps.
    public mutating func evaluate(nowUs: UInt64, conditions: Hold120Conditions) -> StateChange? {
        let reason = conditions.firstBroken
        let on = reason == nil
        let changed = !reported || on != isOn || (!on && reason != lastReason)
        if !on { consecutiveFailures = 0 }
        if on && !isOn { nextStatsUs = nowUs + Self.statsIntervalUs }
        isOn = on
        lastReason = reason
        reported = true
        return changed ? StateChange(on: on, reason: reason) : nil
    }

    /// What to do next. Only meaningful while on (`.off` otherwise). `lastInputUs`: the clock time of the latest real
    /// touch, pen or pointer message, nil = none yet.
    public mutating func next(nowUs: UInt64, lastInputUs: UInt64?) -> Action {
        guard isOn else { return .off }
        if tapInFlight { return .waitForCompletion }
        if nowUs < nextDueUs { return .sleep(untilUs: nextDueUs) }
        if let last = lastInputUs, last <= nowUs, nowUs - last < Self.inputQuietUs {
            skippedInput += 1
            nextDueUs = nowUs + Self.intervalUs
            return .sleep(untilUs: nextDueUs)
        }
        tapInFlight = true
        taps += 1
        return .tap
    }

    public mutating func tapFinished(nowUs: UInt64, success: Bool) {
        tapInFlight = false
        if success {
            consecutiveFailures = 0
            nextDueUs = nowUs + Self.intervalUs
        } else {
            failures += 1
            consecutiveFailures += 1
            nextDueUs = nowUs + Self.backoffUs[min(consecutiveFailures, Self.backoffUs.count) - 1]
        }
    }

    /// At most every 30 s while on.
    public mutating func takeStats(nowUs: UInt64) -> Stats? {
        guard isOn, nowUs >= nextStatsUs else { return nil }
        nextStatsUs = nowUs + Self.statsIntervalUs
        return Stats(taps: taps, skippedInput: skippedInput, failures: failures)
    }
}
