import AppKit
import Darwin
import Foundation
import MateBridgeCore
import NetFS

/// Tablet files in Finder (T-136, decision 0015, PROTOCOL.md 0x09). Executes `TabletFilesPlanner` on its own serial
/// queue: `adb forward` of the tablet's loopback-only WebDAV port (USB sessions only), a NetFS WebDAV mount with
/// user `matebridge` and the session token, and the teardown (cancel pending mount, unmount, forward removal) on
/// OFF, session end, USB loss and app shutdown. The token stays in memory: it is never logged, never put into the
/// URL, never saved to the keychain, and no NetFS UI is shown. The device serial and mount paths are not logged.
///
/// Queue discipline: session start/end, USB changes and shutdown are always queued (never coalesced or dropped).
/// `FILES_INFO`, menu-open retries and open requests are coalesced, so a burst never piles up behind blocking
/// adb or unmount work: at most one pending FILES_INFO per session epoch, one retry and one open.
public final class TabletFilesBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.matebridge.files", qos: .utility)
    private let logger = SessionLogger(component: "files")
    private let runner = ProcessRunner(environment: AdbBinary.environment)

    // Guarded by `lock` (written from any thread).
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var infoSlot = EpochCoalescer<FilesInfo>()
    private var retryQueued = false
    private var openQueued = false
    /// `NSWorkspace.didUnmountNotification` observer (T-206): a Finder eject ends the remount intent.
    private var unmountObserver: NSObjectProtocol?
    /// Snapshot of `TabletFilesPlanner.watchedPaths` (normalized), refreshed after every planner step, so the
    /// posting thread drops every unrelated unmount without touching the bridge queue.
    private var watchedPaths: Set<String> = []
    /// Watched paths unmounted but not yet handed to the planner: in order, duplicates kept (two notifications for
    /// one path can mean our unmount and then the user's eject), bounded.
    private var unmountedPaths: [String] = []
    /// One drain block at most is queued for `unmountedPaths`.
    private var unmountDrainQueued = false
    /// Far above what can matter: the planner watches at most `rememberedMounts + 1` paths.
    private static let maxPendingUnmounts = 16

    // Confined to `queue`.
    private var planner = TabletFilesPlanner()
    private var lastMenu: TabletFilesMenu = .hidden
    /// Device each owned forward was installed on (needed to remove it). Never logged.
    private var forwardSerials: [UInt16: String] = [:]
    /// Pending NetFS requests by mount generation, so teardown can cancel them.
    private var pendingMounts: [UInt64: AsyncRequestID] = [:]

    /// Called on the bridge queue whenever the menu state changes. Set before the first event.
    public var onMenuChange: (@Sendable (TabletFilesMenu) -> Void)?

    public init() {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            self?.volumeUnmounted(path: url.path(percentEncoded: false))
        }
        lock.withLock { unmountObserver = observer }
    }

    deinit { removeUnmountObserver() }

    // MARK: - Events (any thread; handled in order on the bridge queue)

    public func sessionStarted(transport: SessionTransport, capabilities: Capabilities) {
        lock.withLock { epoch += 1 }
        queue.async { [self] in
            apply(planner.sessionStarted(transport: transport, capable: capabilities.contains(.files)))
        }
    }

    /// Every delivered message; only `FILES_INFO` matters here. Coalesced per session epoch (latest wins).
    public func deliver(_ message: Message) {
        guard case .filesInfo(let info) = message else { return }
        let (current, needsDrain) = lock.withLock { (epoch, infoSlot.offer(info, epoch: epoch)) }
        guard needsDrain else { return }
        queue.async { [self] in
            guard let latest = lock.withLock({ infoSlot.take(epoch: current) }) else { return }
            logger.log(.info, "info", sessionID: 0, generation: 0,
                       fields: "state=\(latest.isReady ? "ready" : "off") port=\(latest.port)")
            apply(planner.filesInfo(latest))
        }
    }

    public func sessionEnded() {
        lock.withLock { epoch += 1 }
        queue.async { [self] in apply(planner.sessionEnded()) }
    }

    /// From the USB guard: no device or no adb means the cable is gone. `down` (repairing) and nil (guard off)
    /// say nothing about the device.
    public func usbStateChanged(_ state: UsbTunnelState?) {
        let present: Bool
        switch state {
        case .noDevice, .noAdb: present = false
        case .up: present = true
        case .down, nil: return
        }
        queue.async { [self] in apply(planner.usbDevice(present: present)) }
    }

    /// The menu is opening: retry a failed forward.
    public func menuWillOpen() {
        guard claim(\.retryQueued) else { return }
        queue.async { [self] in
            lock.withLock { retryQueued = false }
            apply(planner.retry())
        }
    }

    /// "Tablet dosyalarını aç": mount if needed, then show the volume in Finder.
    public func open() {
        guard claim(\.openQueued) else { return }
        queue.async { [self] in
            lock.withLock { openQueued = false }
            apply(planner.openRequested())
        }
    }

    /// App shutdown: cancel a pending mount, unmount and remove forwards, waiting at most `timeout` seconds.
    public func shutdown(timeout: TimeInterval = 3) {
        removeUnmountObserver()
        lock.withLock { epoch += 1 }
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            apply(planner.shutdown())
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            logger.log(.warning, "shutdown_timeout", sessionID: 0, generation: 0)
        }
    }

    /// Any volume was unmounted (posting thread). Only a path the planner watches is queued, and at most one drain
    /// block is pending, so unrelated volumes (disk images, other shares) never reach the bridge queue. The path is
    /// never logged.
    private func volumeUnmounted(path: String) {
        let key = TabletFilesPlanner.normalizedPath(path)
        let scheduleDrain: Bool = lock.withLock {
            guard watchedPaths.contains(key), unmountedPaths.count < Self.maxPendingUnmounts else { return false }
            unmountedPaths.append(key)
            guard !unmountDrainQueued else { return false }
            unmountDrainQueued = true
            return true
        }
        guard scheduleDrain else { return }
        queue.async { [self] in drainUnmountedPaths() }
    }

    /// On `queue`. The planner decides whether each unmount was the user ejecting our volume (see
    /// `TabletFilesPlanner.volumeUnmounted`); our own mount points on the current forward are passed in, so a
    /// remount that already landed on the same path is not mistaken for an eject.
    private func drainUnmountedPaths() {
        let paths = lock.withLock { () -> [String] in
            defer {
                unmountedPaths = []
                unmountDrainQueued = false
            }
            return unmountedPaths
        }
        let mountedNow = planner.forwardedLocalPort.map { Self.mountPoints(localPort: $0) } ?? []
        for path in paths where planner.volumeUnmounted(path: path, mountedNow: mountedNow) {
            logger.log(.info, "eject", sessionID: 0, generation: 0, fields: "remount=off seen=notification")
        }
        apply([])  // publishes the new watched paths
    }

    private func removeUnmountObserver() {
        guard let observer = lock.withLock({ () -> NSObjectProtocol? in
            defer { unmountObserver = nil }
            return unmountObserver
        }) else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }

    /// Sets the flag and returns true unless it was already set (one queued block per kind).
    private func claim(_ flag: ReferenceWritableKeyPath<TabletFilesBridge, Bool>) -> Bool {
        lock.withLock {
            if self[keyPath: flag] { return false }
            self[keyPath: flag] = true
            return true
        }
    }

    // MARK: - Execution (on `queue`)

    private func apply(_ actions: [TabletFilesAction]) {
        for action in actions { execute(action) }
        let watched = planner.watchedPaths
        lock.withLock { watchedPaths = watched }
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
            let ok = removeForward(localPort: local)
            apply(planner.forwardRemoved(localPort: local, success: ok))
        case .retryRemoveForward(let local, let delay):
            queue.asyncAfter(deadline: .now() + delay) { [self] in apply(planner.forwardRemovalDue(localPort: local)) }
        case .cancelMount(let gen):
            if let id = pendingMounts.removeValue(forKey: gen) {
                let rc = NetFSMountURLCancel(id)
                logger.log(.info, "mount", sessionID: 0, generation: 0, fields: "result=cancelled code=\(rc)")
            }
        case .unmount(let local):
            // Reported before anything else runs: a replaced volume that is already gone was ejected by the user.
            var detached: [String] = []
            var stillMounted: [String] = []
            for path in Self.mountPoints(localPort: local) {
                if unmount(path) { detached.append(path) } else { stillMounted.append(path) }
            }
            let wanted = planner.remountsAfterRestart
            let next = planner.unmountFinished(localPort: local, detached: detached, stillMounted: stillMounted)
            if wanted, !planner.remountsAfterRestart {
                logger.log(.info, "eject", sessionID: 0, generation: 0, fields: "remount=off seen=unmount")
            }
            apply(next)
        case .unmountPath(let path, let local):
            if Self.mountPoints(localPort: local).contains(path) { unmount(path) }
        case .forceUnmount(let path, let local):
            apply(planner.forceUnmountFinished(path: path, localPort: local, gone: forceUnmount(path, localPort: local)))
        case .mount(let local, let secret, let gen, let knownPath):
            mount(localPort: local, secret: secret, generation: gen, knownPath: knownPath)
        case .reveal(let path):
            let url = URL(fileURLWithPath: path, isDirectory: true)
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: adb forward

    /// `adb forward --no-rebind tcp:47010 tcp:<remote>` (never replaces a forward someone else set up); if that
    /// fails, `tcp:0` lets adb choose a free port. Returns the local port, or nil when adb, its server or the
    /// device is not available.
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
        if runner.run(adb, ["-s", serial, "forward", "--no-rebind", "tcp:\(preferred)", "tcp:\(remotePort)"],
                      timeout: AdbBinary.timeout).succeeded {
            local = preferred
        } else {
            let any = runner.run(adb, ["-s", serial, "forward", "tcp:0", "tcp:\(remotePort)"], timeout: AdbBinary.timeout)
            if any.succeeded { local = AdbOutput.parseForwardPort(any.output) }
        }
        guard let local else { return forwardFailed(remotePort, reason: "adb_forward") }
        forwardSerials[local] = serial
        logger.log(.info, "forward", sessionID: 0, generation: 0, fields: "state=on local=\(local) remote=\(remotePort)")
        return local
    }

    private func forwardFailed(_ remotePort: UInt16, reason: String) -> UInt16? {
        logger.log(.warning, "forward", sessionID: 0, generation: 0,
                   fields: "state=failed remote=\(remotePort) reason=\(reason)")
        return nil
    }

    /// Removes an owned forward and verifies it against `adb forward --list`. Without an adb server, or with the
    /// device gone, the forward went with them (success). Returns false when it is still there or adb hung.
    private func removeForward(localPort: UInt16) -> Bool {
        guard let serial = forwardSerials[localPort] else { return true }
        guard let adb = AdbBinary.locate(), AdbBinary.serverUp else {
            return forwardRemoved(localPort, detail: "adb=gone")
        }
        let devices = runner.run(adb, ["devices"], timeout: AdbBinary.timeout)
        if devices.succeeded, !AdbOutput.parseDevices(devices.output).contains(where: { $0.serial == serial }) {
            return forwardRemoved(localPort, detail: "device=gone")
        }
        _ = runner.run(adb, ["-s", serial, "forward", "--remove", "tcp:\(localPort)"], timeout: AdbBinary.timeout)
        let list = runner.run(adb, ["forward", "--list"], timeout: AdbBinary.timeout)
        if list.succeeded, !AdbOutput.parseForwardList(list.output, serial: serial).contains(localPort) {
            return forwardRemoved(localPort, detail: "result=ok")
        }
        logger.log(.warning, "forward", sessionID: 0, generation: 0,
                   fields: "state=remove_failed local=\(localPort) timeout=\(list.timedOut ? 1 : 0)")
        return false
    }

    private func forwardRemoved(_ localPort: UInt16, detail: String) -> Bool {
        forwardSerials[localPort] = nil
        logger.log(.info, "forward", sessionID: 0, generation: 0, fields: "state=off local=\(localPort) \(detail)")
        return true
    }

    // MARK: Mount

    private func mount(localPort: UInt16, secret: FilesSecret, generation: UInt64, knownPath: String?) {
        // Only a volume this session mounted itself is reused; anything else on the port is not adopted.
        if let knownPath, Self.mountPoints(localPort: localPort).contains(knownPath) {
            logger.log(.info, "mount", sessionID: 0, generation: 0, fields: "result=ok already=1")
            apply(planner.mountFinished(generation: generation, localPort: localPort, path: knownPath))
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
            // On `queue` (the dispatch queue passed above). Not called for a cancelled request.
            pendingMounts[generation] = nil
            let paths = (mountPoints as? [String]) ?? []
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let path = status == 0 ? paths.first : nil  // the path itself is not logged
            logger.log(path != nil ? .info : .warning, "mount", sessionID: 0, generation: 0,
                       fields: path != nil ? "result=ok ms=\(ms)" : "result=error code=\(status) ms=\(ms)")
            if status == EEXIST {
                // NetFS already has this URL mounted (T-209): the planner decides whether that volume is a dead
                // leftover of ours to force out, from our mount points on this port.
                let next = planner.mountCollided(generation: generation, localPort: localPort,
                                                 mountedNow: Self.mountPoints(localPort: localPort))
                let forces = next.filter { if case .forceUnmount = $0 { return true } else { return false } }.count
                logger.log(.info, "mount_exists", sessionID: 0, generation: 0, fields: "dead_ours=\(forces)")
                apply(next)
                return
            }
            apply(planner.mountFinished(generation: generation, localPort: localPort, path: path))
        }
        if rc != 0 {
            logger.log(.warning, "mount", sessionID: 0, generation: 0, fields: "result=error code=\(rc) stage=start")
            apply(planner.mountFinished(generation: generation, localPort: localPort, path: nil))
        } else if let requestID {
            pendingMounts[generation] = requestID
        }
    }

    /// Not forced: a volume with open files stays and the failure is logged.
    @discardableResult
    private func unmount(_ path: String) -> Bool {
        if Darwin.unmount(path, 0) == 0 {
            logger.log(.info, "unmount", sessionID: 0, generation: 0, fields: "result=ok")
            return true
        }
        logger.log(.warning, "unmount", sessionID: 0, generation: 0, fields: "result=error code=\(errno)")
        return false
    }

    /// Forced (T-209), only for a dead leftover the planner chose, and only while `path` is still a WebDAV volume
    /// from `127.0.0.1:<localPort>`. Never shows UI. Returns true when the volume is not mounted any more.
    private func forceUnmount(_ path: String, localPort: UInt16) -> Bool {
        let key = TabletFilesPlanner.normalizedPath(path)
        guard Self.mountPoints(localPort: localPort).contains(where: { TabletFilesPlanner.normalizedPath($0) == key })
        else {
            logger.log(.info, "unmount", sessionID: 0, generation: 0, fields: "result=gone force=1")
            return true
        }
        if Darwin.unmount(path, MNT_FORCE) == 0 {
            logger.log(.info, "unmount", sessionID: 0, generation: 0, fields: "result=ok force=1")
            return true
        }
        logger.log(.warning, "unmount", sessionID: 0, generation: 0, fields: "result=error code=\(errno) force=1")
        return false
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
