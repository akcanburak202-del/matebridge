import AppKit
import Darwin
import Foundation
import MateBridgeCore
import NetFS

/// Tablet files in Finder (T-136, decision 0015, PROTOCOL.md 0x09). Executes `TabletFilesPlanner` on its own serial
/// queue: `adb forward` of the tablet's loopback-only WebDAV port (USB sessions only), a NetFS WebDAV mount with
/// user `matebridge` and the session token, and the teardown (unmount, then forward removal) on OFF, session end,
/// USB loss and app shutdown. The token stays in memory: it is never logged, never put into the URL, never saved
/// to the keychain, and no NetFS UI is shown. The device serial and mount paths are not logged either.
public final class TabletFilesBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.matebridge.files", qos: .utility)
    private let logger = SessionLogger(component: "files")
    private let runner = ProcessRunner(environment: AdbBinary.environment)

    // Confined to `queue`.
    private var planner = TabletFilesPlanner()
    private var lastMenu: TabletFilesMenu = .hidden
    /// Device the current forward was installed on (needed to remove it). Never logged.
    private var forwardSerial: String?

    /// Called on the bridge queue whenever the menu state changes. Set before the first event.
    public var onMenuChange: (@Sendable (TabletFilesMenu) -> Void)?

    public init() {}

    // MARK: - Events (any thread; handled in order on the bridge queue)

    public func sessionStarted(transport: SessionTransport, capabilities: Capabilities) {
        queue.async { [self] in
            apply(planner.sessionStarted(transport: transport, capable: capabilities.contains(.files)))
        }
    }

    /// Every delivered message; only `FILES_INFO` matters here.
    public func deliver(_ message: Message) {
        guard case .filesInfo(let info) = message else { return }
        queue.async { [self] in
            logger.log(.info, "info", sessionID: 0, generation: 0,
                       fields: "state=\(info.isReady ? "ready" : "off") port=\(info.port)")
            apply(planner.filesInfo(info))
        }
    }

    public func sessionEnded() {
        queue.async { [self] in apply(planner.sessionEnded()) }
    }

    /// From the USB guard: no device or no adb means the cable is gone. `down` (repairing) and nil (guard off)
    /// say nothing about the device.
    public func usbStateChanged(_ state: UsbTunnelState?) {
        queue.async { [self] in
            switch state {
            case .noDevice, .noAdb: apply(planner.usbDevice(present: false))
            case .up: apply(planner.usbDevice(present: true))
            case .down, nil: break
            }
        }
    }

    /// The menu is opening: retry a failed forward.
    public func menuWillOpen() {
        queue.async { [self] in apply(planner.retry()) }
    }

    /// "Tablet dosyalarını aç": mount if needed, then show the volume in Finder.
    public func open() {
        queue.async { [self] in apply(planner.openRequested()) }
    }

    /// App shutdown: unmount and remove the forward, waiting at most `timeout` seconds.
    public func shutdown(timeout: TimeInterval = 3) {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            apply(planner.shutdown())
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            logger.log(.warning, "shutdown_timeout", sessionID: 0, generation: 0)
        }
    }

    // MARK: - Execution (on `queue`)

    private func apply(_ actions: [TabletFilesAction]) {
        for action in actions { execute(action) }
        let menu = planner.menu
        if menu != lastMenu {
            lastMenu = menu
            onMenuChange?(menu)
        }
    }

    private func execute(_ action: TabletFilesAction) {
        switch action {
        case .installForward(let remote, let gen):
            let local = installForward(remotePort: remote)
            apply(planner.forwardFinished(generation: gen, localPort: local))
        case .removeForward(let local):
            removeForward(localPort: local)
        case .unmount(let local):
            unmountVolumes(localPort: local)
        case .mount(let local, let secret, let gen):
            mount(localPort: local, secret: secret, generation: gen)
        case .reveal(let path):
            let url = URL(fileURLWithPath: path, isDirectory: true)
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: adb forward

    /// `adb forward tcp:47010 tcp:<remote>`; if that port is taken, `tcp:0` lets adb choose a free one.
    /// Returns the local port, or nil when adb, its server or the device is not available.
    private func installForward(remotePort: UInt16) -> UInt16? {
        guard let adb = AdbBinary.locate(), AdbBinary.serverUp else {
            return forwardFailed(remotePort, reason: "no_adb_server")
        }
        let devices = runner.run(adb, ["devices"], timeout: AdbBinary.timeout)
        guard devices.succeeded, let device = AdbOutput.selectDevice(AdbOutput.parseDevices(devices.output)) else {
            return forwardFailed(remotePort, reason: "no_device")
        }
        let serial = device.serial
        var local: UInt16?
        let preferred = WebDavMount.preferredLocalPort
        if runner.run(adb, ["-s", serial, "forward", "tcp:\(preferred)", "tcp:\(remotePort)"],
                      timeout: AdbBinary.timeout).succeeded {
            local = preferred
        } else {
            let any = runner.run(adb, ["-s", serial, "forward", "tcp:0", "tcp:\(remotePort)"], timeout: AdbBinary.timeout)
            if any.succeeded { local = AdbOutput.parseForwardPort(any.output) }
        }
        guard let local else { return forwardFailed(remotePort, reason: "adb_forward") }
        forwardSerial = serial
        logger.log(.info, "forward", sessionID: 0, generation: 0, fields: "state=on local=\(local) remote=\(remotePort)")
        return local
    }

    private func forwardFailed(_ remotePort: UInt16, reason: String) -> UInt16? {
        logger.log(.warning, "forward", sessionID: 0, generation: 0,
                   fields: "state=failed remote=\(remotePort) reason=\(reason)")
        return nil
    }

    /// Best effort: without a server or device the forward is already gone with them.
    private func removeForward(localPort: UInt16) {
        defer { forwardSerial = nil }
        guard let serial = forwardSerial, let adb = AdbBinary.locate(), AdbBinary.serverUp else {
            logger.log(.info, "forward", sessionID: 0, generation: 0, fields: "state=off local=\(localPort) adb=gone")
            return
        }
        let r = runner.run(adb, ["-s", serial, "forward", "--remove", "tcp:\(localPort)"], timeout: AdbBinary.timeout)
        logger.log(.info, "forward", sessionID: 0, generation: 0,
                   fields: "state=off local=\(localPort) result=\(r.succeeded ? "ok" : "error")")
    }

    // MARK: Mount

    private func mount(localPort: UInt16, secret: FilesSecret, generation: UInt64) {
        if let existing = Self.mountPoints(localPort: localPort).first {
            logger.log(.info, "mount", sessionID: 0, generation: 0, fields: "result=ok already=1")
            apply(planner.mountFinished(generation: generation, localPort: localPort, path: existing))
            return
        }
        // Credentials go only as the user/password arguments: not in the URL, no UI, nothing saved.
        let openOptions = NSMutableDictionary()
        openOptions["UIOption"] = "NoUI"  // kNAUIOptionKey = kNAUIOptionNoUI
        openOptions["AllowLoopback"] = true  // kNetFSAllowLoopbackKey: the server is behind 127.0.0.1
        let mountOptions = NSMutableDictionary()
        mountOptions["SoftMount"] = true  // kNetFSSoftMountKey: a vanished tablet fails I/O instead of hanging it
        var requestID: AsyncRequestID?
        let started = Date()
        let rc = NetFSMountURLAsync(WebDavMount.url(localPort: localPort) as CFURL, nil,
                                    FilesInfo.userName as CFString, secret.value as CFString,
                                    openOptions as CFMutableDictionary, mountOptions as CFMutableDictionary,
                                    &requestID, queue) { [self] status, _, mountPoints in
            // On `queue` (the dispatch queue passed above).
            let paths = (mountPoints as? [String]) ?? []
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let path = status == 0 ? paths.first : nil  // the path itself is not logged
            logger.log(path != nil ? .info : .warning, "mount", sessionID: 0, generation: 0,
                       fields: path != nil ? "result=ok ms=\(ms)" : "result=error code=\(status) ms=\(ms)")
            apply(planner.mountFinished(generation: generation, localPort: localPort, path: path))
        }
        if rc != 0 {
            logger.log(.warning, "mount", sessionID: 0, generation: 0, fields: "result=error code=\(rc) stage=start")
            apply(planner.mountFinished(generation: generation, localPort: localPort, path: nil))
        }
    }

    /// Not forced: a volume with open files stays and the failure is logged.
    private func unmountVolumes(localPort: UInt16) {
        for path in Self.mountPoints(localPort: localPort) {
            if Darwin.unmount(path, 0) == 0 {
                logger.log(.info, "unmount", sessionID: 0, generation: 0, fields: "result=ok")
            } else {
                logger.log(.warning, "unmount", sessionID: 0, generation: 0, fields: "result=error code=\(errno)")
            }
        }
    }

    /// Mount points of WebDAV volumes served from `http://127.0.0.1:<localPort>/` (thread-safe `getfsstat`).
    static func mountPoints(localPort: UInt16) -> [String] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let capacity = Int(count) + 4
        let buf = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { buf.deallocate() }
        UnsafeMutableRawPointer(buf).initializeMemory(as: UInt8.self, repeating: 0,
                                                      count: MemoryLayout<statfs>.stride * capacity)
        let got = getfsstat(buf, Int32(MemoryLayout<statfs>.stride * capacity), MNT_NOWAIT)
        guard got > 0 else { return [] }
        return UnsafeBufferPointer(start: buf, count: min(Int(got), capacity)).compactMap { entry -> String? in
            var e = entry
            let type = withUnsafeBytes(of: &e.f_fstypename) { cString($0) }
            let from = withUnsafeBytes(of: &e.f_mntfromname) { cString($0) }
            let on = withUnsafeBytes(of: &e.f_mntonname) { cString($0) }
            return WebDavMount.isOurs(fsType: type, mountedFrom: from, localPort: localPort) ? on : nil
        }
    }

    private static func cString(_ raw: UnsafeRawBufferPointer) -> String {
        let bytes = raw.bindMemory(to: UInt8.self)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}
