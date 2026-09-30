import Foundation
import MateBridgeCore

/// USB mode guard (T-039). While enabled it keeps `adb reverse tcp:47001/47002` alive: it makes sure the adb server
/// runs (under launchd, like `scripts/usb-mode.sh`, so tunnels survive), and every ~2 s re-installs missing tunnels,
/// which also restores them after the cable is unplugged and replugged. All work, including child processes
/// with deadlines, runs on its own serial queue; decisions come from the pure `UsbTunnelPlanner`.
/// Logs only state changes (`ev=usb_tunnel state=...`); the device serial is never logged.
public final class UsbTunnelWatcher: @unchecked Sendable {
    static let launchdLabel = "dev.matebridge.adb"
    static let adbServerPort: UInt16 = 5037
    static let adbTimeout: TimeInterval = 4

    private let queue = DispatchQueue(label: "dev.matebridge.usb", qos: .utility)
    private let logger = SessionLogger(component: "usb")
    private let runner = ProcessRunner(environment: ["ADB_MDNS": "0", "ADB_MDNS_AUTO_CONNECT": "0"])

    // Confined to `queue`.
    private var planner = UsbTunnelPlanner()
    private var enabled = false
    private var generation = 0
    private var lastActionFailed = false
    private var lastDeviceSerial: String?

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
                scheduleTick(after: 0)
            } else {
                removeTunnels()
                planner.reset()
                lastActionFailed = false
                onStateChange?(nil)
            }
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
        let adb = locateAdb()
        var snapshot = UsbSnapshot(adbFound: adb != nil, serverUp: false)
        var serial: String?
        if let adb, LoopbackProbe.isListening(port: Self.adbServerPort) {
            // The server is up (so this cannot auto-start a stray one); a hung answer counts as down.
            let devices = runner.run(adb, ["devices"], timeout: Self.adbTimeout)
            if devices.succeeded {
                snapshot.serverUp = true
                snapshot.devices = AdbOutput.parseDevices(devices.output)
                if let device = AdbOutput.selectDevice(snapshot.devices) {
                    serial = device.serial
                    let list = runner.run(adb, ["-s", device.serial, "reverse", "--list"], timeout: Self.adbTimeout)
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

    private func locateAdb() -> String? {
        let env = ProcessInfo.processInfo.environment
        let candidates = AdbLocator.candidates(androidHome: env["ANDROID_HOME"], androidSdkRoot: env["ANDROID_SDK_ROOT"],
                                               home: NSHomeDirectory(), path: env["PATH"])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Same method as scripts/usb-mode.sh: adb under launchd, without its mDNS bridge (it aborts on some networks).
    private func startServer(adb: String) -> Bool {
        _ = runner.run("/bin/launchctl", ["remove", Self.launchdLabel], timeout: 3)  // clear a dead or hung job
        let submit = runner.run("/bin/launchctl", ["submit", "-l", Self.launchdLabel, "--"]
                                + AdbServerLaunch.command(adb: adb), timeout: 5)
        guard submit.succeeded else { return false }
        for _ in 0..<15 {  // up to ~3 s for the listener
            if LoopbackProbe.isListening(port: Self.adbServerPort) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private func installTunnels(adb: String, serial: String, ports: [UInt16]) -> Bool {
        var allOK = true
        for port in ports {
            let r = runner.run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"], timeout: Self.adbTimeout)
            if !r.succeeded { allOK = false }
        }
        return allOK
    }

    /// Only touches adb when its server already answers and a device is known, never starts anything.
    private func removeTunnels() {
        guard let adb = locateAdb(), let serial = lastDeviceSerial,
              LoopbackProbe.isListening(port: Self.adbServerPort) else { return }
        for port in planner.ports {
            _ = runner.run(adb, ["-s", serial, "reverse", "--remove", "tcp:\(port)"], timeout: Self.adbTimeout)
        }
        logger.log(.info, "usb_tunnel", sessionID: 0, generation: 0, fields: "state=removed")
    }
}
