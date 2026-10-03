/// Which network surface the host exposes (decision 0027, T-189).
///
/// - `all` ("USB + Wi-Fi", the default): listeners on every interface, Bonjour advertised, every peer admitted.
/// - `usbOnly` ("Yalnız USB"): listeners on IPv4 loopback only (the `adb reverse` target), no Bonjour record (so no TXT
///   `wol=` either), and non-loopback peers refused at accept (defence in depth; the loopback bind already keeps
///   them out). Wi-Fi fallback and the wake flows are unavailable in this mode.
public enum NetworkProfile: String, Equatable, Sendable, CaseIterable {
    case all
    case usbOnly = "usb_only"

    /// UserDefaults key of the menu preference.
    public static let defaultsKey = "networkProfile"

    /// The stored preference. Missing, non-string or unknown values mean `.all`.
    public init(storedValue: Any?) {
        self = (storedValue as? String).flatMap(NetworkProfile.init(rawValue:)) ?? .all
    }

    /// The value written to UserDefaults; `init(storedValue:)` reads it back.
    public var storedValue: String { rawValue }

    /// `profile=` log field value: `all` or `usb_only`.
    public var logName: String { rawValue }

    /// Where both listeners bind. USB-only binds `::ffff:127.0.0.1` (IPv4 loopback on the dual-stack socket): the
    /// Mac's adb server opens the `adb reverse` target as an IPv4 loopback client (127.0.0.1 first; ::1 only when
    /// IPv4 fails, which it cannot while this listener is bound).
    public var bindAddress: BsdTcpListener.BindAddress {
        switch self {
        case .all: .any
        case .usbOnly: .loopbackV4Mapped
        }
    }

    /// Whether the control listener may be advertised over Bonjour.
    public var advertisesBonjour: Bool { self == .all }

    /// Whether a connection from `peerHost` may proceed. In USB-only mode only loopback peers (as
    /// `SessionTransport.classify` sees them, `%scope` ignored) are admitted; an unknown peer address is refused.
    public func admits(peerHost: String?) -> Bool {
        switch self {
        case .all: true
        case .usbOnly: SessionTransport.classify(peerHost: peerHost) == .usb
        }
    }

    /// The `adb reverse` watcher state for the stored "USB modu" choice: USB-only forces it on (without the tunnels
    /// the mode would leave no working transport); the stored choice is kept for when the mode is turned off.
    public func effectiveUsbMode(stored: Bool) -> Bool { self == .usbOnly || stored }

    /// Whether the "USB modu" menu toggle may be changed (it is shown on and locked in USB-only mode).
    public var allowsUsbModeToggle: Bool { self == .all }

    /// The `adb reverse` watcher state while a switch may be waiting (`applied` is in force, `requested` is the menu
    /// choice). The tunnels stay up while EITHER profile needs them: a session preserved by a deferred switch away from
    /// USB-only keeps its tunnels until the switch takes effect (its video reconnect after a STREAM_PREFS change needs
    /// them), and a switch into USB-only gets them at once (adding tunnels never hurts a live session).
    public static func usbWatcherEnabled(stored: Bool, applied: NetworkProfile, requested: NetworkProfile) -> Bool {
        applied.effectiveUsbMode(stored: stored) || requested.effectiveUsbMode(stored: stored)
    }

    /// The "USB modu" toggle is locked (shown on) while either the applied or the requested profile is USB-only.
    public static func usbModeToggleAllowed(applied: NetworkProfile, requested: NetworkProfile) -> Bool {
        applied.allowsUsbModeToggle && requested.allowsUsbModeToggle
    }
}

/// What the server is doing when a profile switch is requested.
public enum NetworkActivity: Equatable, Sendable {
    /// No session: at most unauthenticated connections.
    case idle
    /// A pairing waits for the user's approval; no session is live.
    case pendingApproval
    /// A live session over this transport.
    case active(SessionTransport)
}

/// The pure part of a profile switch (T-189). Restarting the listeners while a session is live could move its video
/// port (port fallback) and, for a Wi-Fi session entering USB-only mode, would cut the tablet that is this Mac's only
/// screen. So any live session defers the switch until it ends; otherwise the listeners restart at once (half-open
/// connections and a pending approval are closed with them).
public enum NetworkProfileSwitch: Equatable, Sendable {
    /// The requested profile is already applied.
    case unchanged
    /// Close half-open connections, restart both listeners (and Bonjour) with the requested profile now.
    case restartNow
    /// Keep the current listeners; apply the requested profile once no session is live.
    case deferred

    public static func decide(current: NetworkProfile, requested: NetworkProfile,
                              activity: NetworkActivity) -> NetworkProfileSwitch {
        guard current != requested else { return .unchanged }
        switch activity {
        case .idle, .pendingApproval: return .restartNow
        case .active: return .deferred  // USB: never cut; Wi-Fi: see the type comment
        }
    }
}

/// The profile switch state of the session server (T-189), pure so the sequencing is unit-tested. The server owns
/// one, on its queue, and carries out the returned steps.
///
/// A restart is two steps: close the old listeners, and only once their descriptors are closed start the new ones (a
/// listener's descriptor closes asynchronously; binding before that finds the fixed ports 47001/47002 still taken and
/// falls back to system-assigned ports that `adb reverse` does not forward). Requests arriving while the old listeners
/// close are coalesced: the restart starts the latest requested profile, once.
public struct NetworkProfileController: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Nothing to do (unchanged, coalesced into a running restart, or stored for the next listener start).
        case none
        /// A live session holds the switch; `applied` stays until it ends (call `evaluate` again then).
        case deferred
        /// Close half-open connections and both listeners; call `listenersClosed()` once both descriptors closed.
        case closeListeners
        /// Start both listeners (and Bonjour) under this profile.
        case startListeners(NetworkProfile)
    }

    /// In force: the listeners (and Bonjour) run under it.
    public private(set) var applied: NetworkProfile
    /// The menu choice.
    public private(set) var requested: NetworkProfile
    /// The old listeners are closing for a restart.
    public private(set) var restarting = false

    public init(profile: NetworkProfile) {
        applied = profile
        requested = profile
    }

    /// The requested profile while it waits (deferred, or a restart in progress); nil when it is in force.
    public var pending: NetworkProfile? { requested != applied ? requested : nil }

    /// The menu asked for `profile`.
    /// - Parameter listening: listeners are up (false: not started, stopped, or a failure restart is pending).
    public mutating func request(_ profile: NetworkProfile, activity: NetworkActivity, listening: Bool) -> Step {
        requested = profile
        return evaluate(activity: activity, listening: listening)
    }

    /// Re-decides a waiting switch (after a session ended, or after `request`).
    public mutating func evaluate(activity: NetworkActivity, listening: Bool) -> Step {
        if restarting { return .none }  // coalesced: `listenersClosed` starts the latest request
        guard listening else {
            applied = requested  // the next listener start uses it
            return .none
        }
        switch NetworkProfileSwitch.decide(current: applied, requested: requested, activity: activity) {
        case .unchanged: return .none
        case .deferred: return .deferred
        case .restartNow:
            restarting = true
            return .closeListeners
        }
    }

    /// Both old listeners' descriptors are closed: start the latest requested profile.
    public mutating func listenersClosed() -> Step {
        guard restarting else { return .none }
        restarting = false
        applied = requested
        return .startListeners(applied)
    }
}
