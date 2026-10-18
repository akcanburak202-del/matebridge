// Per-session decision logic of the tablet camera (decision 0040, docs/PROTOCOL.md 0x0E/0x0F). Pure and clock-free:
// events carry `now` (monotonic microseconds), the host turns the returned actions into listener, CMIO and control
// messages. Nothing runs while the camera is off: with `CAMERA_PREFS` OFF (or no `CAMERA` capability, or a remote
// link) the controller asks for no environment watching, no listener and no timer (`nextDeadline` is nil).
//
// START needs, all at once: AUTO, a local link, a virtual camera target on the Mac and an app using it. Usage starts
// counting at once and ends only after `stopFilterUs` without use (a camera app flipping its device must not make the
// tablet camera blink). Any other condition dropping stops at once.

public struct CameraController: Sendable {
    public enum Action: Equatable, Sendable {
        /// Open the camera listener for this `cam_id`; answer with `listenerOpened(port:)` or `listenerFailed()`.
        case openListener(camID: UInt16)
        /// Close the listener and every camera connection (no message to the client).
        case closeListener
        /// Send this control message on the session's control connection.
        case send(CameraControl)
        /// Start (true) or stop (false) watching the virtual camera: device presence and usage. Only true while the
        /// camera is enabled.
        case watchEnvironment(Bool)
        /// `fields` is preformatted `key=value` text.
        case log(LogLevel, ev: String, fields: String)
    }

    public struct Configuration: Sendable {
        /// Usage must stay gone this long before STOP (PROTOCOL.md 0x0F, suggestion 3 s).
        public var stopFilterUs: UInt64 = 3_000_000
        public init() {}
    }

    private enum Run: Equatable {
        case idle
        /// The listener is being opened; `START` goes out when it is up.
        case opening(camID: UInt16)
        case started(camID: UInt16)
    }

    public var configuration: Configuration

    private var sessionActive = false
    private var clientHasCamera = false
    private var mode = CameraMode.off
    private var remote = false
    private var watching = false
    /// nil until the environment watcher reported the device state.
    private var deviceAvailable: Bool?
    private var usageRaw = false
    private var usageFiltered = false
    private var stopAt: UInt64?
    private var run = Run.idle
    private var nextCamID: UInt16 = 1
    private var unavailableReported = false
    /// The listener failed for the current usage: no retry until the usage ends or the prefs change.
    private var openFailed = false
    /// `CAMERA_PREFS.release_seq` of the first prefs of the session (a baseline, not a change); nil before it.
    private var releaseBaseline: UInt16?
    /// The user released the camera ("Kamerayı şimdi kapat"): no START until the usage went to 0 and came back, or the
    /// mode went OFF.
    private var released = false

    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }

    /// Everything the camera may be doing is derived from this.
    public var isEnabled: Bool { sessionActive && clientHasCamera && mode == .auto && !remote }
    public var isWatching: Bool { watching }
    public var isReleased: Bool { released }
    public var isStarted: Bool { if case .started = run { true } else { false } }
    public var currentCamID: UInt16? {
        switch run {
        case .idle: nil
        case .opening(let id), .started(let id): id
        }
    }

    /// Earliest instant a `tick` has something to do; nil when nothing is pending (always nil while the camera is off).
    public var nextDeadline: UInt64? { stopAt }

    // MARK: Events

    /// A session became active. `clientHasCamera` is `HELLO.capabilities` bit15. The camera starts in OFF.
    public mutating func sessionStarted(clientHasCamera: Bool, now: UInt64) -> [Action] {
        var out = teardown(silent: true)
        resetSession()
        sessionActive = true
        self.clientHasCamera = clientHasCamera
        out += reconcile(now: now)
        return out
    }

    /// The session ended (BYE, HOST_SLEEP, takeover, connection loss): nothing is sent, everything closes.
    public mutating func sessionEnded() -> [Action] {
        let out = teardown(silent: true)
        resetSession()
        return out
    }

    /// `CAMERA_PREFS`. Ignored without the capability bit. `facing` is not the host's business.
    public mutating func prefs(_ prefs: CameraPrefs, now: UInt64) -> [Action] {
        guard sessionActive, clientHasCamera else { return [] }
        let before = mode
        mode = prefs.isAuto ? .auto : .off
        if mode != before { openFailed = false }
        var out: [Action] = []
        let baseline = releaseBaseline
        releaseBaseline = prefs.releaseSeq
        if mode == .off {
            released = false
        } else if let baseline, baseline != prefs.releaseSeq, isEnabled {
            // Only a camera that is being written is released; a tap with START not sent changes nothing.
            if run != .idle {
                released = true
                out += stopRun(reason: "released")
            }
        }
        return out + reconcile(now: now)
    }

    /// `STREAM_PREFS.link`: a remote session counts as OFF.
    public mutating func link(remote isRemote: Bool, now: UInt64) -> [Action] {
        guard remote != isRemote else { return [] }
        remote = isRemote
        return reconcile(now: now)
    }

    /// The environment watcher found (or lost) the virtual camera target.
    public mutating func deviceAvailable(_ available: Bool, now: UInt64) -> [Action] {
        guard watching else { return [] }
        guard deviceAvailable != available else { return [] }
        deviceAvailable = available
        return reconcile(now: now)
    }

    /// An app uses (or no longer uses) the virtual camera.
    public mutating func usage(_ inUse: Bool, now: UInt64) -> [Action] {
        guard watching else { return [] }
        let was = usageRaw
        usageRaw = inUse
        if inUse, !was { released = false }  // 0 then 1 again: a new use, the normal rule applies
        if inUse {
            stopAt = nil
            usageFiltered = true
        } else if usageFiltered, stopAt == nil {
            stopAt = now + configuration.stopFilterUs
        }
        return reconcile(now: now)
    }

    /// The listener asked for with `openListener` is up on `port` (dinleyici açık, then START).
    public mutating func listenerOpened(port: UInt16, now: UInt64) -> [Action] {
        guard case .opening(let camID) = run else { return [] }
        guard isEnabled, deviceAvailable == true, usageFiltered else {
            run = .idle
            return [.closeListener]
        }
        run = .started(camID: camID)
        return [.send(.start(camID: camID, port: port)),
                .log(.info, ev: "camera", fields: "state=start cam_id=\(camID) port=\(port)")]
    }

    /// The listener could not be opened.
    public mutating func listenerFailed(now: UInt64) -> [Action] {
        guard case .opening(let camID) = run else { return [] }
        run = .idle
        openFailed = true
        return [.log(.error, ev: "camera", fields: "state=failed cam_id=\(camID) reason=listener")]
    }

    public mutating func tick(now: UInt64) -> [Action] {
        guard let at = stopAt, now >= at else { return [] }
        stopAt = nil
        usageFiltered = false
        return reconcile(now: now)
    }

    // MARK: Decision

    private mutating func reconcile(now: UInt64) -> [Action] {
        var out: [Action] = []
        guard isEnabled else {
            let why = !sessionActive || !clientHasCamera ? "session" : (remote ? "remote" : "off")
            out += teardown(reason: why)
            unavailableReported = false
            return out
        }
        if !watching {
            watching = true
            out.append(.watchEnvironment(true))
        }
        guard let available = deviceAvailable else { return out }
        guard available else {
            out += stopRun(reason: "no_device")
            if !unavailableReported {
                unavailableReported = true
                out += [.send(.unavailable), .log(.info, ev: "camera", fields: "state=unavailable cam_id=0 reason=no_device")]
            }
            return out
        }
        unavailableReported = false
        if usageFiltered {
            if run == .idle, !openFailed, !released {
                let camID = nextCamID
                nextCamID = nextCamID == UInt16.max ? 1 : nextCamID + 1
                run = .opening(camID: camID)
                out.append(.openListener(camID: camID))
            }
        } else {
            openFailed = false
            out += stopRun(reason: "usage_ended")
        }
        return out
    }

    /// STOP (when START was sent) and close the listener.
    private mutating func stopRun(reason: String) -> [Action] {
        switch run {
        case .idle:
            return []
        case .opening:
            run = .idle
            return [.closeListener]
        case .started(let camID):
            run = .idle
            return [.send(.stop(camID: camID)), .closeListener,
                    .log(.info, ev: "camera", fields: "state=stop cam_id=\(camID) reason=\(reason)")]
        }
    }

    /// Everything off: STOP if START was sent (unless `silent`), listener closed, watcher stopped.
    private mutating func teardown(silent: Bool = false, reason: String = "off") -> [Action] {
        var out: [Action] = []
        if silent {
            if run != .idle { out.append(.closeListener) }
            run = .idle
        } else {
            out += stopRun(reason: reason)
        }
        if watching {
            watching = false
            out.append(.watchEnvironment(false))
        }
        deviceAvailable = nil
        usageRaw = false
        usageFiltered = false
        stopAt = nil
        openFailed = false
        released = false
        return out
    }

    private mutating func resetSession() {
        sessionActive = false
        clientHasCamera = false
        mode = .off
        remote = false
        nextCamID = 1
        releaseBaseline = nil
        unavailableReported = false
    }
}
