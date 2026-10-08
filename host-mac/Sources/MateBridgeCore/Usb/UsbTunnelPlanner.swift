import Foundation

/// What the guard reports (`ev=usb_tunnel state=...`).
public enum UsbTunnelState: String, Equatable, Sendable {
    /// Device present and every tunnel exists.
    case up
    /// adb server down, or device present with tunnels missing (being repaired).
    case down
    /// adb is fine but no authorized device is attached.
    case noDevice = "no_device"
    case noAdb = "no_adb"
}

/// Facts gathered by one probe of the adb world. Host code fills it; nothing here touches processes.
public struct UsbSnapshot: Equatable, Sendable {
    public var adbFound: Bool
    public var serverUp: Bool
    public var devices: [AdbDevice]
    /// Tunnels currently present on the selected device (only meaningful when a device is ready).
    public var presentTunnels: Set<UInt16>

    public init(adbFound: Bool, serverUp: Bool, devices: [AdbDevice] = [], presentTunnels: Set<UInt16> = []) {
        self.adbFound = adbFound
        self.serverUp = serverUp
        self.devices = devices
        self.presentTunnels = presentTunnels
    }
}

public enum UsbAction: Equatable, Sendable {
    /// (Re)start the launchd-hosted adb server.
    case startServer
    /// Run `adb reverse tcp:N tcp:N` for each port.
    case installTunnels([UInt16])
}

public struct UsbDecision: Equatable, Sendable {
    public var state: UsbTunnelState
    public var action: UsbAction?
    /// Non-nil only when `state` differs from the previous decision's: the one line worth logging.
    public var stateChange: UsbTunnelState?
}

/// State to action for the USB tunnel guard, plus log de-duplication and retry backoff.
public struct UsbTunnelPlanner: Sendable {
    public static let baseDelay: TimeInterval = 2
    public static let maxDelay: TimeInterval = 30
    /// Polling interval while adb is missing altogether (it will not appear by itself within seconds).
    public static let noAdbDelay: TimeInterval = 10
    /// Safety-net interval while no cable is attached and USB attach/detach notifications work (T-324).
    public static let idleEventDrivenDelay: TimeInterval = 30
    /// Polling interval with no cable when no notifications are available (was 2 s).
    public static let idlePollingDelay: TimeInterval = 10
    /// After a USB event adb needs a moment to enumerate or drop the device: this many base-rate probes follow.
    public static let burstProbes = 6

    public let ports: [UInt16]
    private var lastState: UsbTunnelState?
    private var failures = 0
    private var lastIdle = false
    private var burstRemaining = 0
    /// True while IOKit attach/detach notifications are registered; lets an empty bus be probed rarely.
    public var usbEventsAvailable = false

    public init(ports: [UInt16] = [DefaultPorts.control, DefaultPorts.video]) { self.ports = ports }

    public mutating func decide(_ snapshot: UsbSnapshot) -> UsbDecision {
        let state: UsbTunnelState
        var action: UsbAction?
        if !snapshot.adbFound {
            state = .noAdb
        } else if !snapshot.serverUp {
            state = .down
            action = .startServer
        } else if AdbOutput.selectDevice(snapshot.devices) == nil {
            state = .noDevice
        } else {
            let missing = ports.filter { !snapshot.presentTunnels.contains($0) }
            if missing.isEmpty {
                state = .up
            } else {
                state = .down
                action = .installTunnels(missing)
            }
        }
        let change = state != lastState ? state : nil
        lastState = state
        // Idle: adb is healthy and has no cable device at all. A listed unauthorized/offline device is not idle,
        // because its authorization has no USB event.
        lastIdle = state == .noDevice && !snapshot.devices.contains { !$0.isNetwork }
        if burstRemaining > 0 { burstRemaining -= 1 }
        if action == nil && state != .noAdb { failures = 0 }  // a healthy or merely idle probe ends any backoff
        return UsbDecision(state: state, action: action, stateChange: change)
    }

    /// Report whether the action from the last decision worked; failures lengthen the next delay.
    public mutating func actionFinished(success: Bool) {
        failures = success ? 0 : failures + 1
    }

    /// Seconds to wait before the next probe: 2 s normally, doubling per consecutive failed repair up to 30 s.
    public var nextDelay: TimeInterval {
        if lastState == .noAdb { return Self.noAdbDelay }
        if lastIdle && burstRemaining == 0 {
            return usbEventsAvailable ? Self.idleEventDrivenDelay : Self.idlePollingDelay
        }
        guard failures > 0 else { return Self.baseDelay }
        return min(Self.maxDelay, Self.baseDelay * Double(1 << min(failures, 5)))
    }

    /// A USB device was attached or detached: probe at the base rate for a few rounds, then fall back.
    public mutating func noteUsbEvent() {
        burstRemaining = Self.burstProbes
    }

    /// Forget the previous state (guard switched off), so re-enabling logs its first state again.
    public mutating func reset() {
        lastState = nil
        failures = 0
        lastIdle = false
        burstRemaining = 0
    }
}

/// How the tablet reached the Mac, from the peer address of its control connection.
public enum SessionTransport: Equatable, Sendable {
    /// Loopback peer: the connection came through `adb reverse`.
    case usb
    case network

    public static func classify(peerHost: String?) -> SessionTransport {
        guard var host = peerHost else { return .network }
        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }  // IPv6 scope id
        if host == "::1" || host == "127.0.0.1" || host == "::ffff:127.0.0.1" || host == "localhost" { return .usb }
        return .network
    }
}

/// Coalesces USB attach/detach events into one pending probe (T-324). An event never postpones a probe that is
/// already pending, so a flapping hub cannot starve tunnel repair or detach detection.
public struct UsbEventCoalescer: Sendable {
    public static let settleDelay: TimeInterval = 0.3
    private var pending = false

    public init() {}

    /// Returns the delay after which to probe when a new probe must be scheduled; nil when one is already pending.
    public mutating func noteEvent() -> TimeInterval? {
        if pending { return nil }
        pending = true
        return Self.settleDelay
    }

    /// The scheduled probe is running now.
    public mutating func probeStarted() { pending = false }

    public mutating func reset() { pending = false }
}
