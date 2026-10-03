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
    /// `adb forward --no-rebind tcp:<local> tcp:<remotePort>` (local: preferred port, else any free one), then
    /// report it through `forwardFinished`. Never replaces a forward someone else owns.
    case installForward(remotePort: UInt16, generation: UInt64)
    /// `adb forward --remove tcp:<localPort>` of a forward we own; report it through `forwardRemoved`.
    case removeForward(localPort: UInt16)
    /// Call `forwardRemovalDue(localPort:)` after `delay` seconds (bounded retry of a failed removal).
    case retryRemoveForward(localPort: UInt16, delay: TimeInterval)
    /// Cancel the pending NetFS request of this mount generation (its result is then never reported).
    case cancelMount(generation: UInt64)
    /// Detach every WebDAV volume mounted from `http://127.0.0.1:<localPort>/` (not forced): the forward on that
    /// port is ours and about to go, or the token changed.
    case unmount(localPort: UInt16)
    /// Detach the one volume at `path`, if it is still a WebDAV volume from `127.0.0.1:<localPort>` (a stale
    /// mount that finished after its generation ended).
    case unmountPath(path: String, localPort: UInt16)
    /// Reveal `knownPath` if it is still our volume, else mount with user `matebridge` / `secret`; report the
    /// result through `mountFinished`.
    case mount(localPort: UInt16, secret: FilesSecret, generation: UInt64, knownPath: String?)
    /// Open the mounted volume in Finder.
    case reveal(path: String)
}

/// Pure state machine for tablet files on the Mac (T-136, decision 0015, PROTOCOL.md 0x09): when to forward the
/// tablet's WebDAV port, when to mount and when to tear everything down. Teardown order is always: cancel a
/// pending mount, unmount, then remove the forward, so the WebDAV client never hangs on a dead port while it
/// still has the volume. A forward whose removal failed stays owed: retried with backoff, then again at the next
/// session/USB event and at shutdown.
///
/// Remount after a server restart (T-206): once the user has asked for the volume, a tablet server restart in the
/// same session (`FILES_INFO` OFF then READY, or a new token on the same port, e.g. a shared-folder scope change)
/// mounts it again with the new token as soon as the forward is up. At most one automatic attempt per READY; an
/// automatic mount is not revealed in Finder. The intent ends with the session, at shutdown and when the user
/// ejects the volume (`volumeUnmounted`).
public struct TabletFilesPlanner: Sendable {
    /// Removal attempts per round (first try plus retries) before waiting for the next session/USB event.
    public static let removalAttempts = 4
    public static let removalBaseDelay: TimeInterval = 1

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
    /// The pending mount was started by the planner (remount), not by the user: its success is not revealed.
    private var mountingIsAutomatic = false
    /// The user asked for the volume in this session and has not ejected it: remount after a server restart.
    private var keepsMounted = false
    /// A new READY arrived while `keepsMounted`: one automatic mount is owed once the forward is up.
    private var autoMountArmed = false
    /// Mount point the current forward's mount got (owned by the current generation chain).
    private var mountedPath: String?
    private var lastMountFailed = false
    /// Forwards we installed and still have to remove: local port to failed attempts in the current round.
    private var owedForwards: [UInt16: Int] = [:]
    private var nextGeneration: UInt64 = 1
    private var isShutDown = false

    public init() {}

    // MARK: - Events

    /// An ACCEPTED session started. `capable`: its HELLO has `Capabilities.files`.
    public mutating func sessionStarted(transport: SessionTransport, capable: Bool) -> [TabletFilesAction] {
        guard !isShutDown else { return [] }
        let out = teardown() + retryGivenUpRemovals()
        session = Session(transport: transport, capable: capable)
        info = nil
        forgetMountIntent()  // a new session needs the user's "Tablet dosyalarını aç" again
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
        // Every new READY (a server (re)start) owes one remount if the user wants the volume; OFF owes none.
        autoMountArmed = ready != nil && keepsMounted
        guard let ready, current.transport == .usb, !usbDeviceLost else { return teardown() }
        if let previous, previous.port == ready.port, case .up(let local, _) = forward {
            // Same port, new token: the server restarted, a mount made with the old token is useless.
            var out = cancelPendingMount() + [.unmount(localPort: local)]
            mountedPath = nil
            lastMountFailed = false
            out += autoMountIfArmed()  // the forward is already up
            return out
        }
        return teardown() + startForward(remotePort: ready.port)
    }

    public mutating func sessionEnded() -> [TabletFilesAction] {
        let out = teardown() + retryGivenUpRemovals()
        session = nil
        info = nil
        forgetMountIntent()
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
        var out = retryGivenUpRemovals()
        if session?.transport == .usb, let info, forward == .none { out += startForward(remotePort: info.port) }
        return out
    }

    /// The user opened the menu: retry a failed forward.
    public mutating func retry() -> [TabletFilesAction] {
        guard !isShutDown, case .failed(let remote) = forward else { return [] }
        return startForward(remotePort: remote)
    }

    /// App shutdown: tear down, one more try for every owed forward, then ignore everything except late results
    /// (which are undone).
    public mutating func shutdown() -> [TabletFilesAction] {
        var out = teardown()
        let pendingInTeardown = Set(out.compactMap { action -> UInt16? in
            if case .removeForward(let port) = action { return port }
            return nil
        })
        for port in owedForwards.keys.sorted() where !pendingInTeardown.contains(port) {
            owedForwards[port] = 0
            out.append(.removeForward(localPort: port))
        }
        session = nil
        info = nil
        forgetMountIntent()
        isShutDown = true
        return out
    }

    /// Result of `installForward`; `localPort` nil on failure.
    public mutating func forwardFinished(generation: UInt64, localPort: UInt16?) -> [TabletFilesAction] {
        // A fresh forward on a port we thought we still owed means that removal did happen after all.
        if let localPort { owedForwards[localPort] = nil }
        if case .installing(let remote, let gen) = forward, gen == generation {
            forward = localPort.map { .up(localPort: $0, remotePort: remote) } ?? .failed(remotePort: remote)
            return autoMountIfArmed()  // nothing while it failed: the attempt stays owed for `retry`/USB return
        }
        // Stale: its session or server is gone. We own it, so remove it (unless it is the current forward).
        guard let localPort else { return [] }
        if case .up(let current, _) = forward, current == localPort { return [] }
        owedForwards[localPort] = 0
        return [.removeForward(localPort: localPort)]
    }

    /// Result of `removeForward`. A failure keeps the forward owed and schedules a bounded retry.
    public mutating func forwardRemoved(localPort: UInt16, success: Bool) -> [TabletFilesAction] {
        guard let attempts = owedForwards[localPort] else { return [] }
        if success {
            owedForwards[localPort] = nil
            return []
        }
        let failed = attempts + 1
        owedForwards[localPort] = failed
        guard !isShutDown, failed < Self.removalAttempts else { return [] }  // given up for this round
        let delay = Self.removalBaseDelay * Double(1 << (failed - 1))
        return [.retryRemoveForward(localPort: localPort, delay: delay)]
    }

    /// A scheduled retry is due.
    public mutating func forwardRemovalDue(localPort: UInt16) -> [TabletFilesAction] {
        guard !isShutDown, let attempts = owedForwards[localPort], attempts < Self.removalAttempts else { return [] }
        return [.removeForward(localPort: localPort)]
    }

    /// The user chose "Tablet dosyalarını aç".
    public mutating func openRequested() -> [TabletFilesAction] {
        guard !isShutDown, case .up = forward, info != nil, mountingGeneration == nil else { return [] }
        keepsMounted = true
        autoMountArmed = false  // the user's own mount covers this READY
        return startMount(automatic: false)
    }

    /// A volume went away and is no longer mounted (the host checks that, e.g. on
    /// `NSWorkspace.didUnmountNotification`). If it is the volume this session mounted, the user ejected it: forget
    /// it and do not mount again by itself until the user opens it. Our own unmounts clear `mountedPath` first, so
    /// their notifications never match.
    public mutating func volumeUnmounted(path: String) -> [TabletFilesAction] {
        guard !isShutDown, let mountedPath, mountedPath == path else { return [] }
        self.mountedPath = nil
        forgetMountIntent()
        return []
    }

    /// Result of `mount`; `path` is the mount point on success, nil on failure.
    public mutating func mountFinished(generation: UInt64, localPort: UInt16, path: String?) -> [TabletFilesAction] {
        if let gen = mountingGeneration, gen == generation {
            let automatic = mountingIsAutomatic
            mountingGeneration = nil
            mountingIsAutomatic = false
            guard let path else {
                lastMountFailed = true  // an automatic one is not retried until the next READY or the user
                mountedPath = nil
                return []
            }
            mountedPath = path
            return automatic ? [] : [.reveal(path: path)]
        }
        // Stale (session ended, token changed, shutdown): detach only the volume this request created, never
        // the current one (the port may have been reused).
        guard let path, path != mountedPath else { return [] }
        return [.unmountPath(path: path, localPort: localPort)]
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

    /// Forwards whose removal is still owed (sorted).
    public var owedForwardPorts: [UInt16] { owedForwards.keys.sorted() }

    /// The user wants the volume in this session: a server restart remounts it.
    public var remountsAfterRestart: Bool { keepsMounted }

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

    private mutating func cancelPendingMount() -> [TabletFilesAction] {
        defer {
            mountingGeneration = nil
            mountingIsAutomatic = false
        }
        return mountingGeneration.map { [.cancelMount(generation: $0)] } ?? []
    }

    /// Mount on the current forward with the current token. Callers check the forward is up and READY is known.
    private mutating func startMount(automatic: Bool) -> [TabletFilesAction] {
        guard case .up(let local, _) = forward, let info else { return [] }
        let gen = takeGeneration()
        mountingGeneration = gen
        mountingIsAutomatic = automatic
        lastMountFailed = false
        return [.mount(localPort: local, secret: FilesSecret(info.token), generation: gen, knownPath: mountedPath)]
    }

    /// The owed remount of this READY, once the forward is up and nothing else is mounting. Fires at most once.
    private mutating func autoMountIfArmed() -> [TabletFilesAction] {
        guard autoMountArmed, keepsMounted, !isShutDown, !usbDeviceLost, session?.transport == .usb,
              case .up = forward, info != nil, mountingGeneration == nil else { return [] }
        autoMountArmed = false
        return startMount(automatic: true)
    }

    private mutating func forgetMountIntent() {
        keepsMounted = false
        autoMountArmed = false
    }

    /// Owed forwards whose retry round ran out get a fresh round.
    private mutating func retryGivenUpRemovals() -> [TabletFilesAction] {
        var out: [TabletFilesAction] = []
        for port in owedForwards.keys.sorted() where owedForwards[port]! >= Self.removalAttempts {
            owedForwards[port] = 0
            out.append(.removeForward(localPort: port))
        }
        return out
    }

    /// Cancel a pending mount, unmount, then remove the forward. An in-flight forward or mount becomes stale and is
    /// undone when it reports.
    private mutating func teardown() -> [TabletFilesAction] {
        var out = cancelPendingMount()
        mountedPath = nil
        lastMountFailed = false
        defer { forward = .none }
        guard case .up(let local, _) = forward else { return out }
        owedForwards[local] = 0
        out += [.unmount(localPort: local), .removeForward(localPort: local)]
        return out
    }
}
