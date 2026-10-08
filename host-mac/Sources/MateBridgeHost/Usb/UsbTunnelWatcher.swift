import Foundation
import IOKit
import MateBridgeCore

/// USB mode guard (T-039). While enabled it keeps `adb reverse tcp:47001/47002` alive: it makes sure the adb server
/// runs (under launchd, like `scripts/usb-mode.sh`, so tunnels survive), and every ~2 s re-installs missing tunnels,
/// which also restores them after the cable is unplugged and replugged. All work, including child processes
/// with deadlines, runs on its own serial queue; decisions come from the pure `UsbTunnelPlanner`.
/// With no cable it does not poll `adb devices` every 2 s (T-324): IOKit USB attach/detach notifications trigger an
/// immediate probe (then a short burst at the base rate while adb catches up), with a slow safety-net poll.
/// Logs only state changes (`ev=usb_tunnel state=...`); the device serial is never logged.
public final class UsbTunnelWatcher: @unchecked Sendable {
    static let launchdLabel = "dev.matebridge.adb"

    private let queue = DispatchQueue(label: "dev.matebridge.usb", qos: .utility)
    private let logger = SessionLogger(component: "usb")
    private let runner = ProcessRunner(environment: AdbBinary.environment)

    // Confined to `queue`.
    private var planner = UsbTunnelPlanner()
    private var enabled = false
    private var generation = 0
    private var lastActionFailed = false
    private var lastDeviceSerial: String?
    private var usbEvents: UsbEventMonitor?
    private var eventCoalescer = UsbEventCoalescer()

    /// Called on the watcher queue whenever the state changes. Set before `setEnabled`.
    public var onStateChange: (@Sendable (UsbTunnelState?) -> Void)?

    public init() {}

    /// Switch the guard on or off. Off removes the tunnels (the adb server is left running).
    public func setEnabled(_ on: Bool) {
        queue.async { [self] in
            guard on != enabled else { return }
            enabled = on
            generation += 1
            if on {
                planner.reset()
                let monitor = UsbEventMonitor(queue: queue) { [weak self] in self?.usbEventOccurred() }
                usbEvents = monitor.start() ? monitor : nil
                planner.usbEventsAvailable = usbEvents != nil
                scheduleTick(after: 0)
            } else {
                usbEvents?.stop()
                usbEvents = nil
                planner.usbEventsAvailable = false
                startRemoval()
                planner.reset()
                lastActionFailed = false
                onStateChange?(nil)
            }
        }
    }

    /// On `queue`. Probe soon and restart the tick chain (the pending slow tick is cancelled by the generation bump).
    /// A pending event probe is never postponed by later events (flapping hubs), so probes keep running.
    private func usbEventOccurred() {
        guard enabled else { return }
        planner.noteUsbEvent()
        guard let delay = eventCoalescer.noteEvent() else { return }
        let gen = generation
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            eventCoalescer.probeStarted()
            guard enabled, gen == generation else { return }
            generation += 1  // cancels the pending regular tick; the chain restarts below
            tick()
            guard enabled else { return }
            scheduleTick(after: planner.nextDelay)
        }
    }

    private func scheduleTick(after delay: TimeInterval) {
        let gen = generation
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard enabled, gen == generation else { return }
            tick()
            guard enabled, gen == generation else { return }
            scheduleTick(after: planner.nextDelay)
        }
    }

    private func tick() {
        let adb = AdbBinary.locate()
        var snapshot = UsbSnapshot(adbFound: adb != nil, serverUp: false)
        var serial: String?
        if let adb, LoopbackProbe.isListening(port: AdbBinary.serverPort) {
            // The server is up (so this cannot auto-start a stray one); a hung answer counts as down.
            let devices = runner.run(adb, ["devices"], timeout: AdbBinary.timeout)
            if devices.succeeded {
                snapshot.serverUp = true
                snapshot.devices = AdbOutput.parseDevices(devices.output)
                if let device = AdbOutput.selectDevice(snapshot.devices) {
                    serial = device.serial
                    let list = runner.run(adb, ["-s", device.serial, "reverse", "--list"], timeout: AdbBinary.timeout)
                    if list.succeeded { snapshot.presentTunnels = AdbOutput.parseReverseList(list.output) }
                }
            }
        }
        lastDeviceSerial = serial

        let decision = planner.decide(snapshot)
        if let change = decision.stateChange {
            logger.log(change == .noAdb ? .warning : .info, "usb_tunnel", sessionID: 0, generation: 0,
                       fields: "state=\(change.rawValue)")
            onStateChange?(change)
        }
        guard let action = decision.action, let adb else { return }
        let ok: Bool
        let what: String
        switch action {
        case .startServer:
            what = "start_server"
            ok = startServer(adb: adb)
        case .installTunnels(let ports):
            what = "install_tunnels"
            ok = serial.map { installTunnels(adb: adb, serial: $0, ports: ports) } ?? false
        }
        planner.actionFinished(success: ok)
        if !ok && !lastActionFailed {
            logger.log(.warning, "usb_action_failed", sessionID: 0, generation: 0, fields: "action=\(what)")
        }
        lastActionFailed = !ok
    }

    /// Same method as scripts/usb-mode.sh: adb under launchd, without its mDNS bridge (it aborts on some networks).
    private func startServer(adb: String) -> Bool {
        _ = runner.run("/bin/launchctl", ["remove", Self.launchdLabel], timeout: 3)  // clear a dead or hung job
        let submit = runner.run("/bin/launchctl", ["submit", "-l", Self.launchdLabel, "--"]
                                + AdbServerLaunch.command(adb: adb), timeout: 5)
        guard submit.succeeded else { return false }
        for _ in 0..<15 {  // up to ~3 s for the listener
            if LoopbackProbe.isListening(port: AdbBinary.serverPort) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private func installTunnels(adb: String, serial: String, ports: [UInt16]) -> Bool {
        var allOK = true
        for port in ports {
            let r = runner.run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"], timeout: AdbBinary.timeout)
            if !r.succeeded { allOK = false }
        }
        return allOK
    }

    /// Only touches adb when its server already answers and a device is known, never starts anything.
    /// A failed or timed-out removal is retried (bounded, with backoff); a later re-enable cancels the retries.
    private func startRemoval() {
        guard let serial = lastDeviceSerial else { return }
        removalAttempt(serial: serial, removal: TunnelRemoval(ports: planner.ports), gen: generation)
    }

    private func removalAttempt(serial: String, removal: TunnelRemoval, gen: Int) {
        guard !enabled, gen == generation else { return }
        // If the server is gone the tunnels went with it.
        guard let adb = AdbBinary.locate(), LoopbackProbe.isListening(port: AdbBinary.serverPort) else { return }
        var removal = removal
        for port in removal.pending {
            _ = runner.run(adb, ["-s", serial, "reverse", "--remove", "tcp:\(port)"], timeout: AdbBinary.timeout)
        }
        // Verify against the device's own list rather than trusting exit codes.
        let list = runner.run(adb, ["-s", serial, "reverse", "--list"], timeout: AdbBinary.timeout)
        let present: Set<UInt16>? = list.succeeded ? AdbOutput.parseReverseList(list.output) : nil
        switch removal.finishAttempt(stillPresent: present) {
        case .done:
            logger.log(.info, "usb_tunnel", sessionID: 0, generation: 0, fields: "state=removed")
        case .retry(let delay, _):
            let next = removal
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                removalAttempt(serial: serial, removal: next, gen: gen)
            }
        case .gaveUp:
            logger.log(.warning, "usb_tunnel", sessionID: 0, generation: 0, fields: "state=remove_failed")
        }
    }
}

/// IOKit attach/detach notifications for any USB device (no vendor filter: the Mac's bus changes rarely, and a
/// probe on a foreign device is one cheap `adb devices`). Callbacks arrive on `queue`. System framework only (T-324).
final class UsbEventMonitor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let onEvent: @Sendable () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    init(queue: DispatchQueue, onEvent: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.onEvent = onEvent
    }

    /// False when the notifications could not be registered; the caller then polls at the fallback rate.
    func start() -> Bool {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        IONotificationPortSetDispatchQueue(port, queue)
        self.port = port
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<UsbEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.drain(iterator, notify: true)
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            // IOServiceAddMatchingNotification consumes one reference of the matching dictionary.
            let kr = IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOUSBHostDevice"),
                                                      callback, refcon, &iterator)
            guard kr == KERN_SUCCESS else { stop(); return false }
            iterators.append(iterator)
            drain(iterator, notify: false)  // arms the notification; existing devices are not events
        }
        return true
    }

    func stop() {
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators = []
        if let port {
            IONotificationPortSetDispatchQueue(port, nil)
            IONotificationPortDestroy(port)
        }
        port = nil
    }

    private func drain(_ iterator: io_iterator_t, notify: Bool) {
        var any = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            any = true
        }
        if any && notify { onEvent() }
    }
}
