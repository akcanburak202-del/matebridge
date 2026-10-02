import Foundation

/// The WebDAV password from `FILES_INFO`. Kept only in memory; `description` hides it so an action or state dump
/// can never put it into a log.
public struct FilesSecret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { "<secret>" }
    public var debugDescription: String { description }
}

/// What the "Tablet dosyalarını aç" menu item shows (decision 0015).
public enum TabletFilesMenu: Equatable, Sendable {
    /// No session, or the tablet does not share files (no `FILES` capability, no `FILES_INFO`).
    case hidden
    /// USB session, tablet server OFF: the user has to switch it on on the tablet.
    case enableOnTablet
    /// Wi-Fi session: files are reachable only through the USB tunnel; the item is disabled.
    case usbOnly
    /// USB + READY, the `adb forward` is being set up (or failed; retried when the menu opens).
    case preparing
    /// Enabled. `lastMountFailed`: the previous attempt to mount failed (the user may try again).
    case ready(lastMountFailed: Bool)
    /// A mount is in progress; the item is disabled until it finishes.
    case mounting
}

/// Side effects the host performs, in order. `generation` ties an asynchronous result back to the request,
/// so a result that arrives after its session/server ended is undone instead of applied.
public enum TabletFilesAction: Equatable, Sendable {
    /// `adb forward tcp:<local> tcp:<remotePort>` (local: preferred port, else any free one), then report it
    /// through `forwardFinished`.
    case installForward(remotePort: UInt16, generation: UInt64)
    /// `adb forward --remove tcp:<localPort>`.
    case removeForward(localPort: UInt16)
    /// Detach every WebDAV volume mounted from `http://localhost:<localPort>/` (not forced).
    case unmount(localPort: UInt16)
    /// Reveal the volume if it is already mounted, else mount it with user `matebridge` / `secret`; report the
    /// result through `mountFinished`.
    case mount(localPort: UInt16, secret: FilesSecret, generation: UInt64)
    /// Open the mounted volume in Finder.
    case reveal(path: String)
}

/// Pure state machine for tablet files on the Mac (T-136, decision 0015, PROTOCOL.md 0x09): when to forward the
/// tablet's WebDAV port, when to mount and when to tear everything down. Teardown order is always unmount first,
/// then forward removal, so the WebDAV client never hangs on a dead port while it still has the volume.
public struct TabletFilesPlanner: Sendable {
    private struct Session: Sendable {
        var transport: SessionTransport
        var capable: Bool
    }

    private enum Forward: Equatable, Sendable {
        case none
        case installing(remotePort: UInt16, generation: UInt64)
        case up(localPort: UInt16, remotePort: UInt16)
        case failed(remotePort: UInt16)
    }

    private var session: Session?
    /// Latest READY info of the session (nil: OFF or none yet). Kept on Wi-Fi too, never acted on there.
    private var info: FilesInfo?
    private var usbDeviceLost = false
    private var forward: Forward = .none
    private var mountingGeneration: UInt64?
    private var lastMountFailed = false
    private var nextGeneration: UInt64 = 1
    private var isShutDown = false

    public init() {}

    // MARK: - Events

    /// An ACCEPTED session started. `capable`: its HELLO has `Capabilities.files`.
    public mutating func sessionStarted(transport: SessionTransport, capable: Bool) -> [TabletFilesAction] {
        guard !isShutDown else { return [] }
        let out = teardown()
        session = Session(transport: transport, capable: capable)
        info = nil
        if transport == .usb { usbDeviceLost = false }  // the session itself came through the cable
        return out
    }

    public mutating func filesInfo(_ message: FilesInfo) -> [TabletFilesAction] {
        guard !isShutDown, var current = session else { return [] }
        current.capable = true  // it sends FILES_INFO, so it shares files
        session = current
        let ready = message.isReady ? message : nil
        guard ready != info else { return [] }
        let previous = info
        info = ready
        guard let ready, current.transport == .usb, !usbDeviceLost else { return teardown() }
        if let previous, previous.port == ready.port, case .up(let local, _) = forward {
            // Same port, new token: the server restarted, a mount made with the old token is useless.
            mountingGeneration = nil
            lastMountFailed = false
            return [.unmount(localPort: local)]
        }
        return teardown() + startForward(remotePort: ready.port)
    }

    public mutating func sessionEnded() -> [TabletFilesAction] {
        let out = teardown()
        session = nil
        info = nil
        return out
    }

    /// The USB guard's view: `false` when the device is gone (no device / no adb), `true` when it is back.
    public mutating func usbDevice(present: Bool) -> [TabletFilesAction] {
        guard !isShutDown else { return [] }
        if !present {
            guard !usbDeviceLost else { return [] }
            usbDeviceLost = true
            return teardown()
        }
        guard usbDeviceLost else { return [] }
        usbDeviceLost = false
        guard session?.transport == .usb, let info, forward == .none else { return [] }
        return startForward(remotePort: info.port)
    }

    /// The user opened the menu: retry a failed forward.
    public mutating func retry() -> [TabletFilesAction] {
        guard !isShutDown, case .failed(let remote) = forward else { return [] }
        return startForward(remotePort: remote)
    }

    /// App shutdown: tear down and ignore everything afterwards except late results (which are undone).
    public mutating func shutdown() -> [TabletFilesAction] {
        let out = teardown()
        session = nil
        info = nil
        isShutDown = true
        return out
    }

    /// Result of `installForward`; `localPort` nil on failure.
    public mutating func forwardFinished(generation: UInt64, localPort: UInt16?) -> [TabletFilesAction] {
        if case .installing(let remote, let gen) = forward, gen == generation {
            forward = localPort.map { .up(localPort: $0, remotePort: remote) } ?? .failed(remotePort: remote)
            return []
        }
        // Stale: its session or server is gone. Undo it unless the current forward reuses the same local port.
        guard let localPort else { return [] }
        if case .up(let current, _) = forward, current == localPort { return [] }
        return [.removeForward(localPort: localPort)]
    }

    /// The user chose "Tablet dosyalarını aç".
    public mutating func openRequested() -> [TabletFilesAction] {
        guard !isShutDown, case .up(let local, _) = forward, let info, mountingGeneration == nil else { return [] }
        let gen = takeGeneration()
        mountingGeneration = gen
        lastMountFailed = false
        return [.mount(localPort: local, secret: FilesSecret(info.token), generation: gen)]
    }

    /// Result of `mount`; `path` is the mount point on success, nil on failure.
    public mutating func mountFinished(generation: UInt64, localPort: UInt16, path: String?) -> [TabletFilesAction] {
        if let gen = mountingGeneration, gen == generation {
            mountingGeneration = nil
            guard let path else {
                lastMountFailed = true
                return []
            }
            return [.reveal(path: path)]
        }
        // Stale (session ended, token changed, shutdown): a volume that still got mounted is detached again,
        // unless a current mount of the same URL is in progress.
        guard path != nil else { return [] }
        if case .up(let current, _) = forward, current == localPort, mountingGeneration != nil { return [] }
        return [.unmount(localPort: localPort)]
    }

    // MARK: - State

    public var menu: TabletFilesMenu {
        guard let session, session.capable, !isShutDown else { return .hidden }
        guard session.transport == .usb else { return .usbOnly }
        guard info != nil else { return .enableOnTablet }
        guard case .up = forward, !usbDeviceLost else { return .preparing }
        return mountingGeneration != nil ? .mounting : .ready(lastMountFailed: lastMountFailed)
    }

    /// Local port of the installed forward, if any.
    public var forwardedLocalPort: UInt16? {
        if case .up(let local, _) = forward { return local }
        return nil
    }

    // MARK: - Private

    private mutating func takeGeneration() -> UInt64 {
        defer { nextGeneration += 1 }
        return nextGeneration
    }

    private mutating func startForward(remotePort: UInt16) -> [TabletFilesAction] {
        let gen = takeGeneration()
        forward = .installing(remotePort: remotePort, generation: gen)
        return [.installForward(remotePort: remotePort, generation: gen)]
    }

    /// Unmount, then remove the forward. An in-flight forward or mount becomes stale and is undone when it reports.
    private mutating func teardown() -> [TabletFilesAction] {
        mountingGeneration = nil
        lastMountFailed = false
        defer { forward = .none }
        guard case .up(let local, _) = forward else { return [] }
        return [.unmount(localPort: local), .removeForward(localPort: local)]
    }
}
