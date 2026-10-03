import Foundation

/// The WebDAV password from `FILES_INFO`. Kept only in memory; `description` hides it so an action or state dump
/// can never put it into a log.
public struct FilesSecret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { "<secret>" }
    public var debugDescription: String { description }
}

/// Which mounted volume a mount point is (T-209): from the mount table entry (`statfs`) at the time we mounted it,
/// and again right before a forced unmount. `fsid` is assigned per mount, so a volume someone mounted later at the
/// same path, even from the same URL, has another one. Holds no credentials (our URL never carries them).
public struct VolumeIdentity: Equatable, Hashable, Sendable {
    /// `f_fsid`, both words.
    public let fsid: UInt64
    /// `f_fstypename`.
    public let fsType: String
    /// `f_mntfromname`, exactly as the mount table shows it.
    public let mountedFrom: String

    public init(fsid: UInt64, fsType: String, mountedFrom: String) {
        self.fsid = fsid
        self.fsType = fsType
        self.mountedFrom = mountedFrom
    }
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
    /// Force-detach (`MNT_FORCE`) the one volume at `path`, only if the volume there now is still exactly `identity`
    /// (`TabletFilesPlanner.identityMatches`): a leftover of ours whose token is dead (T-209). Any other volume, or
    /// none, is left alone and reported as gone. Report through `forceUnmountFinished`.
    case forceUnmount(path: String, localPort: UInt16, identity: VolumeIdentity)
    /// Reveal `knownPath` if it is still our volume, else mount with user `matebridge` / `secret`; report the
    /// result through `mountFinished`, or through `mountCollided` when NetFS answers EEXIST.
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
/// ejects the volume: seen either as an unmount notification of the current volume (`volumeUnmounted`), or, when a
/// restart got there first, as our own unmount finding the volume already gone (`unmountFinished`).
///
/// Dead leftovers (T-209): a volume of ours that our unmount could not detach (busy, e.g. open in Finder) is
/// remembered with the token it was mounted with, across sessions. Once a READY with a different token is known,
/// that volume is dead (its server is gone) and blocks the next mount of the same URL with EEXIST, so it is
/// force-unmounted: once as soon as it is known dead, and once more when a mount collides with it (then the mount
/// is retried once). A volume whose token is still the current one, an unknown volume and the user's own "MatePad"
/// are never forced: the host forces only while the volume at that path still has the exact identity it had right
/// after our mount (`identityMatches`). Any remount waits until the whole cleanup (every queued unmount and force)
/// has reported. A forced unmount is ours, never the user's eject.
public struct TabletFilesPlanner: Sendable {
    /// Removal attempts per round (first try plus retries) before waiting for the next session/USB event.
    public static let removalAttempts = 4
    public static let removalBaseDelay: TimeInterval = 1
    /// Replaced volumes whose unmount result is still awaited (oldest dropped first).
    public static let rememberedMounts = 4

    /// A volume of ours that a restart or teardown forgot and asked the host to unmount; resolved by
    /// `unmountFinished` for its port. `inSession`: replaced in the current session (only then can its result
    /// mean the user's eject, and only then does the remount wait for it).
    private struct ReplacedMount: Sendable {
        let path: String
        let localPort: UInt16
        let origin: MountOrigin
        var inSession = true
    }

    /// What we know about how one of our volumes was mounted: the token, and the volume's identity right after the
    /// mount. Either missing means the volume can never be forced.
    private struct MountOrigin: Sendable {
        var token: FilesSecret?
        var identity: VolumeIdentity?
    }

    /// A volume of ours that our unmount could not detach. `forced`: the one force attempt for being known dead was
    /// made.
    private struct Leftover: Sendable {
        let path: String
        let localPort: UInt16
        let origin: MountOrigin
        var forced = false

        var ref: VolumeRef { VolumeRef(path: path, localPort: localPort) }
    }

    /// A mount point on a forward port, compared without trailing slashes.
    private struct VolumeRef: Hashable, Sendable {
        let path: String
        let localPort: UInt16

        init(path: String, localPort: UInt16) {
            self.path = TabletFilesPlanner.normalizedPath(path)
            self.localPort = localPort
        }
    }

    /// A mount that collided with a dead leftover (EEXIST): retried once when every force is in and succeeded.
    private struct CollisionRetry: Sendable {
        let automatic: Bool
        var forceFailed = false
    }

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
    /// Token the pending mount was started with.
    private var mountingToken: FilesSecret?
    /// The pending mount is the one retry after a collision: another EEXIST fails it.
    private var mountingIsCollisionRetry = false
    /// Mount point the current forward's mount got (owned by the current generation chain).
    private var mountedPath: String?
    /// Token and identity of the volume at `mountedPath`.
    private var mountedOrigin = MountOrigin()
    /// `unmount(localPort:)` actions whose result has not come back, by port. A remount waits for all of them, so a
    /// volume it creates is never detached by a cleanup that was still queued ahead of it.
    private var pendingUnmounts: [UInt16: Int] = [:]
    /// Volumes we asked to unmount and whose result has not come back (bounded; they leave the session at its end,
    /// because a teardown's result arrives after it).
    private var replacedMounts: [ReplacedMount] = []
    /// Busy volumes of ours that stayed mounted (bounded, across sessions, cleared at shutdown).
    private var leftovers: [Leftover] = []
    /// `forceUnmount` actions whose result has not come back.
    private var pendingForces: Set<VolumeRef> = []
    private var collisionRetry: CollisionRetry?
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
        leaveSessionForReplacedMounts()
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
        // A new token makes every leftover mounted with another one dead: it is forced out after the normal cleanup
        // in the same list, and any remount waits for both results.
        guard let ready, current.transport == .usb, !usbDeviceLost else { return teardown() + forceDeadLeftovers() }
        if let previous, previous.port == ready.port, case .up(let local, _) = forward {
            // Same port, new token: the server restarted, a mount made with the old token is useless.
            var out = cancelPendingMount() + [unmountAction(localPort: local)]
            replaceMountedVolume(localPort: local)
            lastMountFailed = false
            out += forceDeadLeftovers()
            // The forward is already up. With a mounted volume the remount waits for `unmountFinished`, which tells
            // whether the user had ejected it first. Without one (and nothing forced) it may follow the unmount in
            // this list: the host reports that unmount before it runs the next action.
            out += autoMountIfArmed(afterUnmountInThisList: local)
            return out
        }
        return teardown() + forceDeadLeftovers() + startForward(remotePort: ready.port)
    }

    public mutating func sessionEnded() -> [TabletFilesAction] {
        let out = teardown() + retryGivenUpRemovals()
        session = nil
        info = nil
        forgetMountIntent()
        leaveSessionForReplacedMounts()
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
        replacedMounts = []
        leftovers = []
        pendingForces = []
        pendingUnmounts = [:]
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
        guard !isShutDown, case .up = forward, info != nil, mountingGeneration == nil, collisionRetry == nil else {
            return []
        }
        keepsMounted = true
        autoMountArmed = false  // the user's own mount covers this READY
        return startMount(automatic: false)
    }

    /// A volume was unmounted (`NSWorkspace.didUnmountNotification`, delivered late and in any order relative to our
    /// own actions). `mountedNow`: our mount points on the current forward at the time of handling.
    ///
    /// It counts as the user's eject only when it is the volume this session mounted and that path is not mounted
    /// any more. Our own unmounts never count: teardown and a token change forget `mountedPath` before they unmount,
    /// a stale `unmountPath` is never the current path, and a remount that already landed on the same mount point is
    /// still in `mountedNow`. On an eject: forget the volume and do not mount again by itself until the user opens
    /// it. Returns true when it was taken as an eject.
    ///
    /// The decision rests on the current volume being gone at handling time, not on which notification arrived, so
    /// a notification of our own earlier unmount that is late, duplicated or never delivered cannot hide a later
    /// eject. An eject whose notification comes after a restart already forgot the volume is caught by
    /// `unmountFinished` instead.
    @discardableResult
    public mutating func volumeUnmounted(path: String, mountedNow: [String]) -> Bool {
        guard !isShutDown, let mountedPath, Self.samePath(mountedPath, path),
              !mountedNow.contains(where: { Self.samePath($0, path) }) else { return false }
        self.mountedPath = nil
        forgetMountIntent()
        return true
    }

    /// Result of `unmount(localPort:)`: the volumes of ours on that port that the host detached (`detached`) and the
    /// ones it found but could not detach (`stillMounted`, e.g. busy). Must be reported for every `unmount`, before
    /// the host handles anything else.
    ///
    /// A replaced volume of this session in neither list was already gone before our unmount ran: the user ejected
    /// it (its notification is still on the way, or the restart was handled first), so the remount intent ends.
    /// A replaced volume in `stillMounted` (busy) becomes a leftover, force-unmounted once its token is known dead
    /// (T-209). A leftover on this port that the unmount detached or did not find is gone. Then the owed remount of
    /// this READY may go ahead, once every queued unmount and force has reported. Returns a force unmount and/or the
    /// remount, if any.
    public mutating func unmountFinished(localPort: UInt16, detached: [String],
                                         stillMounted: [String]) -> [TabletFilesAction] {
        guard !isShutDown else { return [] }
        if let n = pendingUnmounts[localPort] { pendingUnmounts[localPort] = n > 1 ? n - 1 : nil }
        let busy = Set(stillMounted.map { VolumeRef(path: $0, localPort: localPort) })
        leftovers.removeAll { $0.localPort == localPort && !busy.contains($0.ref) }
        var ejected = false
        let resolved = replacedMounts.filter { $0.localPort == localPort }
        replacedMounts.removeAll { $0.localPort == localPort }
        for replaced in resolved {
            if busy.contains(VolumeRef(path: replaced.path, localPort: localPort)) {
                remember(Leftover(path: replaced.path, localPort: localPort, origin: replaced.origin))
            } else if replaced.inSession, !detached.contains(where: { Self.samePath($0, replaced.path) }) {
                ejected = true
            }
        }
        if ejected { forgetMountIntent() }
        let forces = forceDeadLeftovers()
        return forces + resumeAfterCleanup()
    }

    /// Result of `forceUnmount`. `gone`: the volume is not mounted any more (detached, or already absent), or the
    /// volume at that path is not the one we left (then it is forgotten, never forced). A force that left our volume
    /// mounted keeps the leftover: no further automatic force, but a colliding mount tries once more.
    public mutating func forceUnmountFinished(path: String, localPort: UInt16, gone: Bool) -> [TabletFilesAction] {
        guard !isShutDown else { return [] }
        let ref = VolumeRef(path: path, localPort: localPort)
        guard pendingForces.remove(ref) != nil else { return [] }
        if gone {
            leftovers.removeAll { $0.ref == ref }
        } else {
            collisionRetry?.forceFailed = true
        }
        return resumeAfterCleanup()
    }

    /// The pending mount failed with EEXIST: NetFS already has this URL mounted. `mountedNow`: our mount points on
    /// `localPort` (WebDAV from `127.0.0.1:<localPort>`) at that time. When one of them is a leftover of ours whose
    /// token is dead, force it out and retry the mount once. Anything else (a live-token volume, the user's own
    /// "MatePad", an unknown volume) is left alone and the failure shows in the menu.
    public mutating func mountCollided(generation: UInt64, localPort: UInt16,
                                       mountedNow: [String]) -> [TabletFilesAction] {
        guard !isShutDown, let gen = mountingGeneration, gen == generation else { return [] }
        let automatic = mountingIsAutomatic
        let wasRetry = mountingIsCollisionRetry
        _ = cancelPendingMount()  // the request is over; nothing to cancel on the host
        mountedPath = nil
        mountedOrigin = MountOrigin()
        let blocking = Set(mountedNow.map { VolumeRef(path: $0, localPort: localPort) })
        let dead = leftovers.indices.filter { isDead(leftovers[$0]) && blocking.contains(leftovers[$0].ref) }
        guard !wasRetry, !dead.isEmpty else {
            lastMountFailed = true
            return []
        }
        collisionRetry = CollisionRetry(automatic: automatic)
        var out: [TabletFilesAction] = []
        for i in dead { out += force(at: i) }
        return out
    }

    /// Result of `mount`; `path` is the mount point on success, nil on failure. `identity`: the mount table entry of
    /// `path` right after the mount (nil if the host could not read it: then that volume is never forced).
    public mutating func mountFinished(generation: UInt64, localPort: UInt16, path: String?,
                                       identity: VolumeIdentity? = nil) -> [TabletFilesAction] {
        if let gen = mountingGeneration, gen == generation {
            let automatic = mountingIsAutomatic
            let token = mountingToken
            _ = cancelPendingMount()  // the request is over; nothing to cancel on the host
            guard let path else {
                lastMountFailed = true  // an automatic one is not retried until the next READY or the user
                mountedPath = nil
                mountedOrigin = MountOrigin()
                return []
            }
            mountedPath = path
            mountedOrigin = MountOrigin(token: token, identity: identity)
            leftovers.removeAll { Self.samePath($0.path, path) }  // our new volume took that mount point
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
        let mounting = mountingGeneration != nil || collisionRetry != nil
        return mounting ? .mounting : .ready(lastMountFailed: lastMountFailed)
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

    /// Normalized paths whose unmount notification can matter (the current volume and replaced ones awaiting their
    /// unmount result). The host drops every other notification before it reaches the planner.
    public var watchedPaths: Set<String> {
        let replaced = replacedMounts.filter(\.inSession).map(\.path)
        return Set(([mountedPath].compactMap { $0 } + replaced).map(Self.normalizedPath))
    }

    /// Normalized mount points of busy volumes of ours that stayed mounted (T-209), oldest first. Never logged.
    public var leftoverPaths: [String] { leftovers.map(\.ref.path) }

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
            mountingIsCollisionRetry = false
            mountingToken = nil
            collisionRetry = nil  // its forces still report; only the retry is dropped
        }
        return mountingGeneration.map { [.cancelMount(generation: $0)] } ?? []
    }

    /// Mount on the current forward with the current token. Callers check the forward is up and READY is known.
    private mutating func startMount(automatic: Bool) -> [TabletFilesAction] {
        guard case .up(let local, _) = forward, let info else { return [] }
        let gen = takeGeneration()
        mountingGeneration = gen
        mountingIsAutomatic = automatic
        mountingIsCollisionRetry = false
        mountingToken = FilesSecret(info.token)
        lastMountFailed = false
        return [.mount(localPort: local, secret: FilesSecret(info.token), generation: gen, knownPath: mountedPath)]
    }

    /// The owed remount of this READY, once the forward is up, nothing else is mounting, every replaced volume's
    /// unmount result is in (it may show the user had ejected it) and the whole cleanup has reported: every queued
    /// `unmount` and `forceUnmount`. Fires at most once.
    ///
    /// `afterUnmountInThisList`: the caller has just put an `unmount` of that port into the list this mount joins.
    /// The host reports that unmount before it runs the next action, so it may come first in the same list; any
    /// other pending cleanup still holds the mount back.
    private mutating func autoMountIfArmed(afterUnmountInThisList port: UInt16? = nil) -> [TabletFilesAction] {
        let cleanupPending = pendingUnmounts.contains { $0.key != port || $0.value > 1 }
        guard autoMountArmed, keepsMounted, !isShutDown, !usbDeviceLost, session?.transport == .usb,
              case .up = forward, info != nil, mountingGeneration == nil, collisionRetry == nil, pendingForces.isEmpty,
              !cleanupPending, !replacedMounts.contains(where: \.inSession) else { return [] }
        autoMountArmed = false
        return startMount(automatic: true)
    }

    /// After a cleanup result: once every queued unmount and force has reported, the collision retry (or else the
    /// owed remount) may go ahead.
    private mutating func resumeAfterCleanup() -> [TabletFilesAction] {
        guard pendingForces.isEmpty, pendingUnmounts.isEmpty else { return [] }
        guard let retry = collisionRetry else { return autoMountIfArmed() }
        collisionRetry = nil
        guard !retry.forceFailed else {
            lastMountFailed = true
            return []
        }
        let out = startMount(automatic: retry.automatic)
        if !out.isEmpty { mountingIsCollisionRetry = true }
        return out
    }

    /// `unmount(localPort:)`, counted until its result comes back.
    private mutating func unmountAction(localPort: UInt16) -> TabletFilesAction {
        pendingUnmounts[localPort, default: 0] += 1
        return .unmount(localPort: localPort)
    }

    /// Forget the current volume because we are about to emit `unmount(localPort:)` for it, and remember it until
    /// `unmountFinished` reports what the unmount found.
    private mutating func replaceMountedVolume(localPort: UInt16) {
        guard let path = mountedPath else { return }
        let origin = mountedOrigin
        mountedPath = nil
        mountedOrigin = MountOrigin()
        replacedMounts.removeAll { Self.samePath($0.path, path) }
        replacedMounts.append(ReplacedMount(path: path, localPort: localPort, origin: origin))
        if replacedMounts.count > Self.rememberedMounts {
            replacedMounts.removeFirst(replacedMounts.count - Self.rememberedMounts)
        }
    }

    /// At a session boundary, replaced volumes still await their unmount result (a teardown's result comes after
    /// the boundary), but they no longer say anything about the user's eject and no longer hold back a remount.
    private mutating func leaveSessionForReplacedMounts() {
        for i in replacedMounts.indices { replacedMounts[i].inSession = false }
    }

    private mutating func remember(_ leftover: Leftover) {
        leftovers.removeAll { $0.ref.path == leftover.ref.path }
        leftovers.append(leftover)
        if leftovers.count > Self.rememberedMounts { leftovers.removeFirst(leftovers.count - Self.rememberedMounts) }
    }

    /// Dead: mounted with a token other than the current READY's (that server is gone). No READY known (OFF, no
    /// session), no token or no identity known: not provably dead (or not provably ours). Never the volume we
    /// currently own.
    private func isDead(_ leftover: Leftover) -> Bool {
        guard let info, let token = leftover.origin.token, token.value != info.token,
              leftover.origin.identity != nil else { return false }
        if let mountedPath, Self.samePath(mountedPath, leftover.path) { return false }
        return true
    }

    /// The one automatic force for every leftover that is known dead now and has not had it.
    private mutating func forceDeadLeftovers() -> [TabletFilesAction] {
        var out: [TabletFilesAction] = []
        for i in leftovers.indices where !leftovers[i].forced && isDead(leftovers[i]) { out += force(at: i) }
        return out
    }

    /// Marks the leftover forced and emits its force, unless one is already pending. Callers checked `isDead`.
    private mutating func force(at i: Int) -> [TabletFilesAction] {
        leftovers[i].forced = true
        guard let identity = leftovers[i].origin.identity, pendingForces.insert(leftovers[i].ref).inserted else {
            return []
        }
        return [.forceUnmount(path: leftovers[i].path, localPort: leftovers[i].localPort, identity: identity)]
    }

    /// Whether the volume now at a leftover's mount point (`current`, nil: none of ours on that port) is exactly the
    /// one we mounted there (`expected`), so that forcing it can only hit our own dead volume: same `fsid` (assigned
    /// per mount), WebDAV, and mounted from exactly our URL on `localPort` (`http://127.0.0.1:<port>/MatePad/`).
    /// Anything else, including someone else's volume later mounted at that path from the same port, is not forced.
    public static func identityMatches(expected: VolumeIdentity, current: VolumeIdentity?, localPort: UInt16) -> Bool {
        guard let current, current == expected, expected.fsType == "webdav",
              let c = URLComponents(string: expected.mountedFrom),
              c.scheme?.lowercased() == "http", c.host == WebDavMount.host, c.port == Int(localPort),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              normalizedPath(c.path) == normalizedPath(WebDavMount.volumePath) else { return false }
        return true
    }

    /// A path without trailing slashes: mount points from `getfsstat` and volume URLs from NSWorkspace may differ
    /// by one.
    public static func normalizedPath(_ path: String) -> String {
        var t = Substring(path)
        while t.count > 1, t.hasSuffix("/") { t = t.dropLast() }
        return String(t)
    }

    static func samePath(_ a: String, _ b: String) -> Bool { normalizedPath(a) == normalizedPath(b) }

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
        lastMountFailed = false
        defer { forward = .none }
        guard case .up(let local, _) = forward else {
            mountedPath = nil  // a mount only exists on an up forward
            mountedOrigin = MountOrigin()
            return out
        }
        replaceMountedVolume(localPort: local)
        owedForwards[local] = 0
        out += [unmountAction(localPort: local), .removeForward(localPort: local)]
        return out
    }
}
