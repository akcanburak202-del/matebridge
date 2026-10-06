// Pure host-side session state machine (docs/PROTOCOL.md sections 3, 6, 7, 9).
// No I/O and no clock: every event carries `now` (monotonic microseconds), and the caller
// turns the returned actions into sends, closes and input releases, in order.
// Randomness (ephemeral key, nonces, session id) and the pair-key lookup are injected through `Configuration`.

public struct ConnectionID: Hashable, Sendable {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
}

/// Why the host is releasing all held input (PROTOCOL.md section 7 triggers).
public enum ReleaseCause: Equatable, Sendable {
    case clientRequest(ReleaseReason)
    case bye
    case disconnected
    case protocolError
    case silence
    case timeout
    case superseded
    case shutdown
    /// The Mac is going to sleep (T-132): the session ends with BYE(HOST_SLEEP).
    case hostSleep
    /// Host-internal, never produced by `SessionMachine`: the virtual display or the Accessibility permission went
    /// away while input was held (T-023), so the input pipeline releases it by itself.
    case gateLost
}

public enum LogLevel: String, Sendable { case error = "E", warning = "W", info = "I", debug = "D" }

/// What a new pairing request replaced (T-155). The request is never blocked; the approval panel shows the swap.
public enum ApprovalReplacement: Equatable, Sendable {
    /// No approval window was open.
    case none
    /// The open (orphaned) window belonged to the same `device_id`: the tablet came back before approval, with a new code.
    case sameDevice
    /// The open (orphaned) window belonged to another `device_id`: a different device took the dialog over.
    case otherDevice

    /// Value of the `replaced=` field of `approval_pending`.
    public var logValue: String {
        switch self {
        case .none: "none"
        case .sameDevice: "same"
        case .otherDevice: "other"
        }
    }
}

public enum SessionAction: Equatable, Sendable {
    /// Send on the control connection.
    case send(ConnectionID, Message)
    /// Close a control connection (after flushing queued sends).
    case close(ConnectionID)
    case closeVideo(ConnectionID)
    /// Look up the pair key of a device off the session queue and answer with `pairKeyResolved`. The connection
    /// sends nothing meanwhile; existing sessions and their release paths never wait for it.
    case lookupPairKey(ConnectionID, deviceID: DeviceID)
    /// A VIDEO_HELLO checked out: wait (bounded) for the connection's first authenticated record, a PING under `c2h`,
    /// and report it with `videoProven`. Nothing is attached and no frame is sent before that.
    case videoProve(ConnectionID, c2h: SecretBytes)
    /// Right after the first HELLO_ACK was sent (which stays plaintext): every later message on this control
    /// connection is sealed with `h2c` and every inbound byte is an encrypted record under `c2h`.
    case startEncryption(ConnectionID, ControlKeys)
    /// Release every held key, button and pen contact of this session (idempotent).
    case releaseInput(ConnectionID, ReleaseCause)
    /// Message from the approved, active session that the host acts on (input, STATS, KEYFRAME_REQUEST), and a PONG
    /// that answers one of the host's own PINGs on that connection (T-171, diagnostic clock offset only).
    case deliver(ConnectionID, Message)
    /// `code` is shown in the approval window only (never logged). `replaced` says whether this request replaced an
    /// approval window left open by a request whose tablet had left (T-155); the panel makes a swap visible.
    case requestApproval(ConnectionID, deviceID: DeviceID, deviceName: String, code: PairingCode,
                         replaced: ApprovalReplacement)
    case cancelApproval(ConnectionID)
    /// The connection that owns the approval request is gone (tablet left, e.g. switched to another app), but the
    /// window stays open for `orphanWindowUs` with the same code. The request id stays valid for `approvalDecided`
    /// ("Allow" then yields `persistOrphanPairing`); `cancelApproval` closes the window at the end.
    case approvalOrphaned(ConnectionID)
    /// "Allow" on an orphaned request: the caller stores that handshake's `key` (Keychain) and the device record and
    /// reports `orphanPairingPersisted`. There is no ACCEPTED to send; the device's next connection is PAIRED with `key`.
    case persistOrphanPairing(ConnectionID, deviceID: DeviceID, name: String, key: SecretBytes)
    /// The user accepted a pairing. The caller stores `key` (Keychain) and the device list, then reports the outcome
    /// with `pairingPersisted`; ACCEPTED is sent only after a successful store.
    case persistPairing(ConnectionID, deviceID: DeviceID, name: String, key: SecretBytes)
    /// The session is active. `hello` is the HELLO of *this* connection: per-session settings (display size) are
    /// derived from it now, never earlier (an unproven reconnect must not influence a live session).
    case sessionStarted(ConnectionID, sessionID: UInt32, configID: UInt16, hello: Hello)
    case sessionEnded(ConnectionID)
    /// A video connection passed VIDEO_HELLO validation.
    case videoAttached(video: ConnectionID, session: ConnectionID, sessionID: UInt32, configID: UInt16,
                       keys: VideoKeys)
    /// `fields` is preformatted `key=value` text and never contains the device name or input content.
    case log(LogLevel, ev: String, conn: ConnectionID?, fields: String)
}

public enum SessionStatus: Equatable, Sendable {
    case idle
    case pending(deviceName: String)
    case active(deviceName: String, sessionID: UInt32)
}

public struct SessionMachine: Sendable {
    public struct Configuration: Sendable {
        public var hostName: String
        public var helloTimeoutUs: UInt64 = 5_000_000
        public var approvalTimeoutUs: UInt64 = 60_000_000
        public var releaseSilenceUs: UInt64 = 1_500_000
        public var closeSilenceUs: UInt64 = 5_000_000
        public var videoHelloTimeoutUs: UInt64 = 5_000_000
        /// How long the approval window stays open after the pending tablet disconnected.
        public var orphanWindowUs: UInt64 = 120_000_000
        /// Fills the STREAM_CONFIG sent after ACCEPTED. `configID` must be nonzero.
        public var makeStreamConfig: @Sendable (Hello) -> StreamConfig
        public var makeSessionID: @Sendable () -> UInt32
        /// Persistent `host_id` (HELLO_ACK). Default: random per machine (tests); the app passes `HostIdentityStore`'s.
        public var hostID: [UInt8]
        /// Pair keys: PAIRED needs an approved device *and* a key here.
        /// nil (the app): pair keys are looked up asynchronously (`lookupPairKey` / `pairKeyResolved`) because the
        /// Keychain can block. A store here is consulted inline (tests, in-memory stores).
        public var pairKeys: PairKeyStore?
        /// A pair-key lookup that takes longer closes that connection; nothing has been sent on it by then.
        public var lookupTimeoutUs: UInt64 = 5_000_000
        public var makeEphemeral: @Sendable () -> EphemeralKeyPair = { EphemeralKeyPair() }
        public var makeNonce: @Sendable () -> [UInt8] = {
            (0..<ProtocolConstants.nonceSize).map { _ in UInt8.random(in: 0...255) }
        }
        /// Every proven `video_nonce` of a session is remembered for the whole session (a repeat would reuse an
        /// AES-GCM key and nonce). When this many are used up the session is ended so the tablet reconnects with a
        /// fresh handshake and a fresh `prk`.
        public var maxVideoNonces = 4096
        /// Time a new control/video connection has to prove it holds the keys (first authenticated record).
        public var proofTimeoutUs: UInt64 = 5_000_000
        /// false: never answer PAIRED (the host identity could not be persisted; PROTOCOL.md 9, host_id).
        public var allowPaired = true
        /// T-171: the host PINGs the active session's control connection this often (PROTOCOL.md 6, "Host da aynı
        /// aralıkla gönderebilir"). Its PONG only feeds the diagnostic clock offset (`InputAgeTracker`). nil: off,
        /// the default here, so tests that compare whole `tick` results stay exact; the host app sets
        /// `defaultHostPingIntervalUs`.
        public var hostPingIntervalUs: UInt64?
        /// The client's PING interval (PROTOCOL.md 6), used by the host app for its own PINGs.
        public static let defaultHostPingIntervalUs: UInt64 = 500_000
        /// PINGs remembered while unanswered; an older one is forgotten (its PONG is then ignored).
        public var maxOutstandingPings = 4

        public init(hostName: String,
                    makeStreamConfig: @escaping @Sendable (Hello) -> StreamConfig,
                    makeSessionID: @escaping @Sendable () -> UInt32 = { UInt32.random(in: 1...UInt32.max) },
                    hostID: [UInt8] = (0..<ProtocolConstants.deviceIDSize).map { _ in UInt8.random(in: 0...255) },
                    pairKeys: PairKeyStore? = InMemoryPairKeyStore()) {
            precondition(hostID.count == ProtocolConstants.deviceIDSize)
            self.hostName = hostName
            self.makeStreamConfig = makeStreamConfig
            self.makeSessionID = makeSessionID
            self.hostID = hostID
            self.pairKeys = pairKeys
        }
    }

    public var configuration: Configuration
    /// Video listener port sent in HELLO_ACK(ACCEPTED). Set once the listener is ready.
    public var videoPort: UInt16 = 0
    public private(set) var approvedDevices: Set<DeviceID>

    private struct Session {
        var id: UInt32
        var configID: UInt16
        var deviceID: DeviceID
        var deviceName: String
        /// `HELLO.capabilities` of this session's connection (`SETTINGS_PANEL` gates `SETTINGS_OPEN`, decision 0013).
        var capabilities: Capabilities = []
        var video: ConnectionID?
        /// Holds the session `prk` for video key derivation; wiped when the session ends.
        var schedule: SessionKeySchedule
        /// `video_nonce` values of proven attaches: a repeat must never reuse a GCM key and nonce.
        var videoNonces: Set<[UInt8]> = []
    }

    /// A PAIRED connection that has been answered ACCEPTED but has not yet shown it holds the keys: a same-device
    /// reconnect (takeover) or a fresh connection with no session live. It changes no session state (an old session
    /// keeps running, no session starts) until its first authenticated record.
    private struct Proving {
        var hello: Hello
        var session: Session
        var config: StreamConfig
        var deadline: UInt64
    }

    /// A video connection whose VIDEO_HELLO checked out and that now has to send one authenticated PING.
    private struct VideoProof {
        var sessionConn: ConnectionID
        var sessionID: UInt32
        var configID: UInt16
        var nonce: [UInt8]
        var deadline: UInt64
    }

    private struct Pairing {
        var schedule: SessionKeySchedule
        var code: PairingCode
        var newPairKey: SecretBytes
        /// How this request replaced an open window (T-155). `otherDevice` is sticky for the window: it is carried
        /// into the orphan and through every later replacement until the user decides or the window expires.
        var replaced: ApprovalReplacement
    }

    /// An approval request whose connection went away; the window is still open.
    private struct Orphan {
        var id: ConnectionID
        var deviceID: DeviceID
        var deviceName: String
        /// This handshake's `new_pair_key`, kept in memory only until the user answers or the window expires.
        var newPairKey: SecretBytes
        var deadline: UInt64
        /// The window was taken over by a different `device_id` at some point (T-155, sticky until decided/expired).
        var otherDeviceSeen: Bool
    }

    private enum Phase {
        case awaitingHello(deadline: UInt64)
        case lookingUp(Hello, deadline: UInt64)
        case pending(Hello, deadline: UInt64, Pairing)
        case proving(Proving)
        case active(Session)
    }

    /// Host PINGs of an active connection (T-171), diagnostics only.
    private struct HostPing {
        struct Sent {
            var seq: UInt32
            var sentAt: UInt64
        }
        var nextAt: UInt64
        var nextSeq: UInt32 = 1
        /// Unanswered, oldest first, bounded by `maxOutstandingPings`.
        var outstanding: [Sent] = []
    }

    private struct Conn {
        var phase: Phase
        var lastReceive: UInt64
        var silenceReleased = false
        /// Set when the connection becomes the active session (`start`), never before: no PING while
        /// `.awaitingHello`, `.lookingUp`, `.pending` or `.proving`.
        var ping: HostPing?
    }

    private var connections: [ConnectionID: Conn] = [:]
    private var videoConnections: [ConnectionID: UInt64] = [:]  // opened, awaiting VIDEO_HELLO
    private var videoProofs: [ConnectionID: VideoProof] = [:]  // VIDEO_HELLO valid, awaiting the authenticated PING
    private var orphan: Orphan?
    /// Devices whose orphaned approval is being stored right now. Their HELLO gets BUSY until it finished: a reconnect
    /// that started another PAIRING meanwhile would make the tablet replace the key that is about to be approved.
    private var persistingOrphans: Set<DeviceID> = []
    /// Latest `now` seen, for events that carry none (`connectionClosed`).
    private var clock: UInt64 = 0

    public init(configuration: Configuration, approvedDevices: Set<DeviceID> = []) {
        self.configuration = configuration
        self.approvedDevices = approvedDevices
    }

    public var status: SessionStatus {
        for conn in connections.values {
            switch conn.phase {
            case .pending(let hello, _, _): return .pending(deviceName: hello.deviceName)
            case .active(let s): return .active(deviceName: s.deviceName, sessionID: s.id)
            case .awaitingHello, .proving, .lookingUp: continue
            }
        }
        return .idle
    }

    /// Control connections that are not yet authenticated: no HELLO yet, or a reconnect still proving (the host caps these).
    public var awaitingHelloCount: Int {
        connections.values.filter {
            switch $0.phase {
            case .awaitingHello, .proving, .lookingUp: true
            default: false
            }
        }.count
    }

    /// Video connections that have not yet proven themselves (no VIDEO_HELLO, or no authenticated PING yet).
    public var pendingVideoCount: Int { videoConnections.count + videoProofs.count }

    public mutating func forgetApprovedDevices() {
        approvedDevices.removeAll()
    }

    /// Test hook: the orphaned request's device, if a window is open.
    var orphanDeviceForTesting: DeviceID? { orphan?.deviceID }

    /// True while the connection waits for the user's answer (the store/persist steps may still be in flight).
    public func isPendingApproval(_ id: ConnectionID) -> Bool {
        if case .pending? = connections[id]?.phase { true } else { false }
    }

    /// Test hook: the key schedule held for a connection (active session or pending pairing).
    func scheduleForTesting(_ id: ConnectionID) -> SessionKeySchedule? {
        switch connections[id]?.phase {
        case .active(let s)?: s.schedule
        case .pending(_, _, let p)?: p.schedule
        case .proving(let p)?: p.session.schedule
        default: nil
        }
    }

    // MARK: Control connection events

    public mutating func connectionOpened(_ id: ConnectionID, now: UInt64) -> [SessionAction] {
        clock = max(clock, now)
        connections[id] = Conn(phase: .awaitingHello(deadline: now + configuration.helloTimeoutUs), lastReceive: now)
        return [.log(.debug, ev: "control_open", conn: id, fields: "")]
    }

    /// The transport closed the connection (or failed). Releases input if it was the live session.
    public mutating func connectionClosed(_ id: ConnectionID) -> [SessionAction] {
        end(id, bye: nil, cause: .disconnected, close: false, ev: "control_closed", orphaning: true)
    }

    /// The decoder threw: BYE(PROTOCOL_ERROR), release, close both connections.
    public mutating func protocolError(_ id: ConnectionID) -> [SessionAction] {
        end(id, bye: .protocolError, cause: .protocolError, close: true, ev: "protocol_error")
    }

    /// An inbound record failed authentication or had an invalid length (PROTOCOL.md 9): the channel is not
    /// trusted, so there is no BYE. Input is released and both connections close.
    public mutating func recordAuthFailed(_ id: ConnectionID, counter: UInt64) -> [SessionAction] {
        end(id, bye: nil, cause: .protocolError, close: true, ev: "record_auth_failed", fields: "counter=\(counter)")
    }

    public mutating func received(_ id: ConnectionID, _ message: Message, now: UInt64) -> [SessionAction] {
        clock = max(clock, now)
        guard var conn = connections[id] else { return [] }
        conn.lastReceive = now
        conn.silenceReleased = false
        connections[id] = conn
        switch conn.phase {
        case .awaitingHello:
            guard case .hello(let hello) = message else { return protocolError(id) }
            return handleHello(id, hello, now: now)
        case .pending:
            return handleCommon(id, message, now: now, isActive: false)
        case .lookingUp:
            return protocolError(id)  // a client sends nothing before HELLO_ACK
        case .proving(let proving):
            return prove(id, proving, first: message, now: now)
        case .active:
            return handleCommon(id, message, now: now, isActive: true)
        }
    }

    /// The user answered the approval dialog. Ignored unless the connection is still pending.
    /// Accepting is two steps: this returns `persistPairing`, the caller stores the key, then `pairingPersisted`.
    public mutating func approvalDecided(_ id: ConnectionID, approved: Bool, now: UInt64) -> [SessionAction] {
        clock = max(clock, now)
        if connections[id] == nil, let o = orphan, o.id == id {
            return orphanDecided(o, approved: approved, now: now)
        }
        guard case .pending(_, let deadline, let pairing)? = connections[id]?.phase else { return [] }
        // An answer that arrives after the deadline (before tick ran) counts as a rejection.
        guard approved, now < deadline else {
            pairing.schedule.wipe()
            connections[id] = nil
            return [.send(id, ack(.rejected)), .close(id),
                    .log(.info, ev: "approval_rejected", conn: id, fields: "")]
        }
        guard case .pending(let hello, _, _)? = connections[id]?.phase else { return [] }
        return [.persistPairing(id, deviceID: hello.deviceID, name: hello.deviceName, key: pairing.newPairKey),
                .log(.info, ev: "approval_accepted", conn: id, fields: "")]
    }

    /// The user answered the window of a disconnected request. Allow: the handshake's pair key and the approval are
    /// stored (PAIRED next time, and only the tablet holding that key can complete it). Reject, or an answer after the
    /// window expired: nothing is stored and the key is dropped.
    private mutating func orphanDecided(_ o: Orphan, approved: Bool, now: UInt64) -> [SessionAction] {
        orphan = nil
        guard approved, now < o.deadline else {
            return [.cancelApproval(o.id), .log(.info, ev: "approval_rejected", conn: o.id, fields: "disconnected=true")]
        }
        persistingOrphans.insert(o.deviceID)
        return [.cancelApproval(o.id),
                .persistOrphanPairing(o.id, deviceID: o.deviceID, name: o.deviceName, key: o.newPairKey),
                .log(.info, ev: "approval_accepted", conn: o.id, fields: "disconnected=true")]
    }

    /// The caller finished storing an orphaned approval. On success the device counts as approved (its key is in the
    /// store), so its next connection takes the PAIRED path through the normal lookup.
    public mutating func orphanPairingPersisted(deviceID: DeviceID, stored: Bool) {
        persistingOrphans.remove(deviceID)
        if stored { approvedDevices.insert(deviceID) }
    }

    /// The caller finished storing the pair key (`stored`) after `persistPairing`. Only now is ACCEPTED sent;
    /// a failed store rejects instead (the tablet must not hold a key the host lacks).
    public mutating func pairingPersisted(_ id: ConnectionID, stored: Bool, now: UInt64) -> [SessionAction] {
        guard case .pending(let hello, _, let pairing)? = connections[id]?.phase else { return [] }
        guard stored else {
            pairing.schedule.wipe()
            connections[id] = nil
            return [.send(id, ack(.rejected)), .close(id),
                    .log(.error, ev: "pairing_store_failed", conn: id, fields: "")]
        }
        approvedDevices.insert(hello.deviceID)
        let sessionID = max(1, configuration.makeSessionID())
        let config = configuration.makeStreamConfig(hello)
        var actions: [SessionAction] = [.send(id, ack(.accepted, sessionID: sessionID, videoPort: videoPort))]
        actions += start(id, hello, now: now, sessionID: sessionID, config: config, schedule: pairing.schedule)
        return actions
    }

    // MARK: Video connection events

    public mutating func videoOpened(_ id: ConnectionID, now: UInt64) -> [SessionAction] {
        videoConnections[id] = now + configuration.videoHelloTimeoutUs
        return []
    }

    public mutating func videoClosed(_ id: ConnectionID) -> [SessionAction] {
        videoConnections[id] = nil
        videoProofs[id] = nil
        for (cid, conn) in connections {
            if case .active(var s) = conn.phase, s.video == id {
                s.video = nil
                connections[cid]?.phase = .active(s)
            }
        }
        return [.log(.debug, ev: "video_closed", conn: id, fields: "")]
    }

    /// First message on a video connection, in the clear. A valid one changes *nothing* about the session: the
    /// connection only has to prove it holds the video key (`videoProven`, PROTOCOL.md 3.5). Anything stale closes
    /// only this video connection.
    public mutating func videoHello(_ id: ConnectionID, _ hello: VideoHello, now: UInt64) -> [SessionAction] {
        guard videoConnections.removeValue(forKey: id) != nil else { return [.closeVideo(id)] }
        for (cid, conn) in connections {
            guard case .active(let s) = conn.phase,
                  hello.protocolVersion == ProtocolConstants.protocolVersion,
                  hello.sessionID == s.id, hello.configID == s.configID else { continue }
            guard !s.videoNonces.contains(hello.videoNonce),
                  let keys = s.schedule.videoKeys(nonce: hello.videoNonce) else {
                return [.closeVideo(id), .log(.warning, ev: "video_hello_rejected", conn: id, fields: "reason=nonce")]
            }
            videoProofs[id] = VideoProof(sessionConn: cid, sessionID: s.id, configID: s.configID,
                                         nonce: hello.videoNonce, deadline: now + configuration.proofTimeoutUs)
            return [.videoProve(id, c2h: keys.c2h)]
        }
        return [.closeVideo(id), .log(.warning, ev: "video_hello_rejected", conn: id, fields: "")]
    }

    /// The first authenticated record (a PING) arrived on the video connection: only now is it attached, the old
    /// video connection closed and the nonce remembered. Re-checks everything, time has passed since VIDEO_HELLO.
    public mutating func videoProven(_ id: ConnectionID, now: UInt64) -> [SessionAction] {
        guard let proof = videoProofs.removeValue(forKey: id) else { return [.closeVideo(id)] }
        guard case .active(var s)? = connections[proof.sessionConn]?.phase, s.id == proof.sessionID,
              s.configID == proof.configID, !s.videoNonces.contains(proof.nonce),
              let keys = s.schedule.videoKeys(nonce: proof.nonce) else {
            return [.closeVideo(id), .log(.warning, ev: "video_hello_rejected", conn: id, fields: "reason=stale")]
        }
        guard s.videoNonces.count < configuration.maxVideoNonces else {
            // Budget spent: never reuse a key. End the session; the tablet reconnects and gets a fresh prk.
            var actions: [SessionAction] = [.closeVideo(id)]
            actions += end(proof.sessionConn, bye: .shuttingDown, cause: .shutdown, close: true,
                           ev: "video_nonce_budget_exhausted")
            return actions
        }
        s.videoNonces.insert(proof.nonce)
        var actions: [SessionAction] = []
        if let old = s.video, old != id { actions.append(.closeVideo(old)) }
        s.video = id
        connections[proof.sessionConn]?.phase = .active(s)
        actions.append(.videoAttached(video: id, session: proof.sessionConn, sessionID: s.id, configID: s.configID,
                                      keys: keys))
        return actions
    }

    /// Session id of the live (ACCEPTED) session, if any. A file connection is accepted only for this id.
    public var activeSessionID: UInt32? {
        for conn in connections.values {
            if case .active(let s) = conn.phase { return s.id }
        }
        return nil
    }

    /// Keys of one Wi-Fi file connection (decision 0035) from the `prk` of the active session `sessionID`. The narrow
    /// query the file listener needs after a valid `FILES_HELLO`: nil when that session is not the active one any
    /// more (it ended, was superseded, its `prk` was wiped) or a nonce is malformed. The caller then closes the
    /// connection. Nothing is remembered: both nonces are fresh per connection (PROTOCOL.md 9).
    public func filesKeys(sessionID: UInt32, clientNonce: [UInt8], hostNonce: [UInt8]) -> FilesKeys? {
        for conn in connections.values {
            if case .active(let s) = conn.phase, s.id == sessionID {
                return s.schedule.filesKeys(clientNonce: clientNonce, hostNonce: hostNonce)
            }
        }
        return nil
    }

    /// Sends `message` on the control connection of the active session `sessionID` (host-initiated messages such as
    /// CLIPBOARD). Nothing happens for an unknown or pending session.
    public func send(sessionID: UInt32, _ message: Message) -> [SessionAction] {
        for (cid, conn) in connections {
            if case .active(let s) = conn.phase, s.id == sessionID { return [.send(cid, message)] }
        }
        return []
    }

    /// The active session's control connection, if that session's client can open its settings panel (HELLO
    /// capability bit9 `SETTINGS_PANEL`, decision 0013).
    private var settingsPanelConnection: ConnectionID? {
        for (cid, conn) in connections {
            if case .active(let s) = conn.phase, s.capabilities.contains(.settingsPanel) { return cid }
        }
        return nil
    }

    /// There is an ACCEPTED session whose client handles `SETTINGS_OPEN` (the host menu item is enabled only then).
    public var settingsPanelAvailable: Bool { settingsPanelConnection != nil }

    /// The host menu's "open settings on the tablet" (decision 0013): `SETTINGS_OPEN` on the active session's control
    /// connection. Without an active session, or when its client did not announce `SETTINGS_PANEL`, nothing is sent
    /// (only a log line).
    public func openSettingsPanel() -> [SessionAction] {
        if let cid = settingsPanelConnection {
            return [.send(cid, .settingsOpen(SettingsOpen())),
                    .log(.info, ev: "settings_open_sent", conn: cid, fields: "")]
        }
        let active = connections.values.contains { if case .active = $0.phase { true } else { false } }
        let reason = active ? "no_capability" : "no_session"
        return [.log(.info, ev: "settings_open_skipped", conn: nil, fields: "reason=\(reason)")]
    }

    /// The stream settings of the live session changed (`STREAM_PREFS`, PROTOCOL.md 3.7): send the new `STREAM_CONFIG`
    /// on the control connection, then close the current video connection; the tablet reopens it with the new
    /// `config_id`. A video connection that is still proving with the old `config_id` fails its re-check. Nothing
    /// happens for an unknown session or an unchanged `config_id`.
    public mutating func reconfigure(sessionID: UInt32, config: StreamConfig) -> [SessionAction] {
        for (cid, conn) in connections {
            guard case .active(var s) = conn.phase, s.id == sessionID, s.configID != config.configID else { continue }
            s.configID = config.configID
            let old = s.video
            s.video = nil
            connections[cid]?.phase = .active(s)
            var actions: [SessionAction] = [.send(cid, .streamConfig(config))]
            if let old { actions.append(.closeVideo(old)) }
            actions.append(.log(.info, ev: "stream_config_changed", conn: cid,
                                fields: "config_id=\(config.configID) width=\(config.widthPx) height=\(config.heightPx) fps=\(config.fps)"))
            return actions
        }
        return []
    }

    // MARK: Time and shutdown

    public mutating func tick(now: UInt64) -> [SessionAction] {
        clock = max(clock, now)
        var actions: [SessionAction] = []
        if let o = orphan, now >= o.deadline {
            orphan = nil
            actions += [.cancelApproval(o.id), .log(.info, ev: "approval_orphan_expired", conn: o.id, fields: "")]
        }
        for id in connections.keys.sorted(by: { $0.raw < $1.raw }) {
            guard let conn = connections[id] else { continue }
            switch conn.phase {
            case .awaitingHello(let deadline):
                if now >= deadline {
                    connections[id] = nil
                    actions += [.close(id), .log(.warning, ev: "hello_timeout", conn: id, fields: "")]
                }
            case .lookingUp(_, let deadline):
                if now >= deadline {
                    connections[id] = nil
                    actions += [.close(id), .log(.warning, ev: "pair_key_lookup_timeout", conn: id, fields: "")]
                }
            case .proving(let p):
                if now >= p.deadline {
                    // No proof: the new connection goes, the old session is untouched.
                    p.session.schedule.wipe()
                    connections[id] = nil
                    actions += [.close(id), .log(.warning, ev: "proof_timeout", conn: id, fields: "")]
                }
            case .pending(_, let deadline, let pairing):
                if now >= deadline {
                    pairing.schedule.wipe()
                    connections[id] = nil
                    actions += [.cancelApproval(id), .send(id, ack(.rejected)), .close(id),
                                .log(.info, ev: "approval_timeout", conn: id, fields: "")]
                }
            case .active:
                let silent = now >= conn.lastReceive ? now - conn.lastReceive : 0
                if silent >= configuration.closeSilenceUs {
                    actions += end(id, bye: .timeout, cause: .timeout, close: true, ev: "heartbeat_timeout")
                } else {
                    if silent >= configuration.releaseSilenceUs, !conn.silenceReleased {
                        connections[id]?.silenceReleased = true
                        actions += [.releaseInput(id, .silence),
                                    .log(.warning, ev: "heartbeat_silence", conn: id, fields: "")]
                    }
                    actions += hostPingIfDue(id, now: now)
                }
            }
        }
        for (vid, deadline) in videoConnections.sorted(by: { $0.key.raw < $1.key.raw }) where now >= deadline {
            videoConnections[vid] = nil
            actions += [.closeVideo(vid), .log(.warning, ev: "video_hello_timeout", conn: vid, fields: "")]
        }
        for (vid, proof) in videoProofs.sorted(by: { $0.key.raw < $1.key.raw }) where now >= proof.deadline {
            videoProofs[vid] = nil
            actions += [.closeVideo(vid), .log(.warning, ev: "video_proof_timeout", conn: vid, fields: "")]
        }
        return actions
    }

    /// Host app is quitting: release input, tell every peer, close everything.
    public mutating func shutdown() -> [SessionAction] {
        endAll(bye: .shuttingDown, cause: .shutdown, ev: "shutdown")
    }

    /// The Mac is going to sleep (`kIOMessageSystemWillSleep`, T-132): like `shutdown()`, but every peer gets
    /// BYE(HOST_SLEEP) so the tablet neither reconnects nor wakes the Mac by itself; no TCP connection is left open
    /// to keep dark-waking it. The live session (and one still proving its keys) is released and closed, a pairing
    /// waiting for approval is cancelled and closed, an approval window left open is closed, unproven video
    /// connections close. Connections opened later (after a wake) are handled normally.
    public mutating func hostSleep() -> [SessionAction] {
        endAll(bye: .hostSleep, cause: .hostSleep, ev: "bye_sent", fields: "reason=host_sleep")
    }

    private mutating func endAll(bye: ByeReason, cause: ReleaseCause, ev: String,
                                 fields: String = "") -> [SessionAction] {
        var actions: [SessionAction] = []
        if let o = orphan {
            orphan = nil
            actions.append(.cancelApproval(o.id))
        }
        for id in connections.keys.sorted(by: { $0.raw < $1.raw }) {
            actions += end(id, bye: bye, cause: cause, close: true, ev: ev, fields: fields)
        }
        for vid in videoConnections.keys.sorted(by: { $0.raw < $1.raw }) { actions.append(.closeVideo(vid)) }
        for vid in videoProofs.keys.sorted(by: { $0.raw < $1.raw }) { actions.append(.closeVideo(vid)) }
        videoConnections.removeAll()
        videoProofs.removeAll()
        return actions
    }

    // MARK: Internals

    /// T-171: the next host PING of the active connection `id`, if due. A late tick sends one PING, never a burst.
    private mutating func hostPingIfDue(_ id: ConnectionID, now: UInt64) -> [SessionAction] {
        guard let interval = configuration.hostPingIntervalUs, var ping = connections[id]?.ping,
              now >= ping.nextAt else { return [] }
        let seq = ping.nextSeq
        ping.nextSeq &+= 1
        ping.outstanding.append(.init(seq: seq, sentAt: now))
        if ping.outstanding.count > max(1, configuration.maxOutstandingPings) { ping.outstanding.removeFirst() }
        ping.nextAt = now + interval
        connections[id]?.ping = ping
        return [.send(id, .ping(Ping(seq: seq, senderTimeUs: now)))]
    }

    /// T-171: a PONG on the active connection that answers one of its outstanding host PINGs (same seq, and the echo
    /// is that PING's time) is handed on for the clock offset; anything else is ignored. PONGs arrive in order, so the
    /// matched PING and every older one are done.
    private mutating func hostPong(_ id: ConnectionID, _ pong: Pong) -> [SessionAction] {
        guard var ping = connections[id]?.ping,
              let i = ping.outstanding.firstIndex(where: { $0.seq == pong.seq && $0.sentAt == pong.echoTimeUs })
        else { return [] }
        ping.outstanding.removeSubrange(...i)
        connections[id]?.ping = ping
        return [.deliver(id, .pong(pong))]
    }

    private func ack(_ status: HelloStatus, sessionID: UInt32 = 0, videoPort: UInt16 = 0) -> Message {
        .helloAck(HelloAck(status: status, sessionID: sessionID, videoPort: videoPort,
                           hostName: configuration.hostName))
    }

    /// The connection holding the single session slot (pending or active).
    private var slotOwner: ConnectionID? {
        connections.first { entry in
            switch entry.value.phase {
            case .awaitingHello, .proving, .lookingUp: return false
            default: return true
            }
        }?.key
    }

    private mutating func handleHello(_ id: ConnectionID, _ hello: Hello, now: UInt64) -> [SessionAction] {
        guard hello.protocolVersion == ProtocolConstants.protocolVersion else {
            connections[id] = nil
            return [.send(id, ack(.versionMismatch)), .close(id),
                    .log(.warning, ev: "version_mismatch", conn: id, fields: "peer_version=\(hello.protocolVersion)")]
        }
        if persistingOrphans.contains(hello.deviceID) {
            connections[id] = nil
            return [.send(id, ack(.busy)), .close(id), .log(.info, ev: "busy", conn: id, fields: "reason=key_storing")]
        }
        // Another device holding the slot is BUSY whatever the key situation: no lookup needed.
        if let owner = slotOwner {
            var ownerDevice: DeviceID?
            switch connections[owner]?.phase {
            case .pending(let h, _, _)?: ownerDevice = h.deviceID
            case .active(let s)?: ownerDevice = s.deviceID
            default: break
            }
            if ownerDevice != hello.deviceID {
                connections[id] = nil
                return [.send(id, ack(.busy)), .close(id), .log(.info, ev: "busy", conn: id, fields: "")]
            }
        }
        guard configuration.allowPaired, approvedDevices.contains(hello.deviceID) else {
            return continueHello(id, hello, now: now, pairKey: nil)
        }
        if let store = configuration.pairKeys {
            return continueHello(id, hello, now: now, pairKey: store.key(for: hello.deviceID))
        }
        connections[id]?.phase = .lookingUp(hello, deadline: now + configuration.lookupTimeoutUs)
        return [.lookupPairKey(id, deviceID: hello.deviceID)]
    }

    /// The answer to `lookupPairKey`. Ignored unless the connection is still waiting for it.
    public mutating func pairKeyResolved(_ id: ConnectionID, key: SecretBytes?, now: UInt64) -> [SessionAction] {
        guard case .lookingUp(let hello, _)? = connections[id]?.phase else { return [] }
        return continueHello(id, hello, now: now, pairKey: key)
    }

    private mutating func continueHello(_ id: ConnectionID, _ hello: Hello, now: UInt64,
                                        pairKey: SecretBytes?) -> [SessionAction] {
        // One session at a time. The same device may reconnect, but only with its pair key (PAIRED): its session is
        // then taken over once the new connection proved key possession (`prove`). Anything else is BUSY, so the
        // device_id (sent in the clear) cannot be used by a bystander to knock a live session off.
        var takeover = false
        if let owner = slotOwner {
            var ownerDevice: DeviceID?
            switch connections[owner]?.phase {
            case .pending(let h, _, _)?: ownerDevice = h.deviceID
            case .active(let s)?: ownerDevice = s.deviceID
            default: break
            }
            guard ownerDevice == hello.deviceID, pairKey != nil else {
                connections[id] = nil
                return [.send(id, ack(.busy)), .close(id), .log(.info, ev: "busy", conn: id, fields: "")]
            }
            takeover = true
        }
        let ephemeral = configuration.makeEphemeral()
        guard let ecdh = try? ephemeral.sharedSecret(withPeerPublicKey: hello.clientEphPub) else {
            return protocolError(id)
        }
        let hostNonce = configuration.makeNonce()
        guard hostNonce.count == ProtocolConstants.nonceSize else { return protocolError(id) }
        var actions: [SessionAction] = []
        if let pairKey {
            let sessionID = max(1, configuration.makeSessionID())
            let config = configuration.makeStreamConfig(hello)
            let firstAck = HelloAck(status: .accepted, sessionID: sessionID, videoPort: videoPort,
                                    hostName: configuration.hostName, keyMode: .paired, hostID: configuration.hostID,
                                    hostNonce: hostNonce, hostEphPub: ephemeral.publicKeyBytes)
            guard let schedule = try? SessionKeySchedule.derive(
                ecdh: ecdh, pairKey: pairKey, helloPayload: hello.transcriptBytes,
                ackPayload: Message.helloAck(firstAck).encodePayload()) else { return protocolError(id) }
            actions += [.send(id, .helloAck(firstAck)), .startEncryption(id, schedule.control),
                        .log(.info, ev: "handshake", conn: id, fields: "mode=paired")]
            // Every PAIRED connection proves key possession (its first authenticated record) before anything
            // happens: no STREAM_CONFIG, no session, no display. `device_id` alone (sent in the clear) must not make
            // the Mac build a display or hold display sleep. A takeover additionally leaves the old session running
            // until then.
            connections[id]?.phase = .proving(Proving(
                hello: hello,
                session: Self.makeSession(hello, sessionID: sessionID, config: config, schedule: schedule),
                config: config, deadline: now + configuration.proofTimeoutUs))
            if takeover {
                actions.append(.log(.info, ev: "takeover_proving", conn: id, fields: ""))
            } else {
                actions.append(.log(.info, ev: "paired_proving", conn: id, fields: ""))
            }
        } else {
            let firstAck = HelloAck(status: .pendingApproval, sessionID: 0, videoPort: 0,
                                    hostName: configuration.hostName, keyMode: .pairing, hostID: configuration.hostID,
                                    hostNonce: hostNonce, hostEphPub: ephemeral.publicKeyBytes)
            guard let schedule = try? SessionKeySchedule.derive(
                ecdh: ecdh, pairKey: nil, helloPayload: hello.transcriptBytes,
                ackPayload: Message.helloAck(firstAck).encodePayload()),
                  let code = schedule.pairingCode, let newKey = schedule.newPairKey else {
                return protocolError(id)
            }
            // A new request replaces a window left open by an earlier one (its stored key is dropped). It is never
            // blocked (that would let any LAN device lock pairing out), but the swap is reported so the panel can
            // say whether the same or a different device is asking now (T-155). Once a different device took the
            // window over, it stays `otherDevice` for that window: that device leaving and coming back with its own
            // id must not turn the warning into the neutral "code changed" notice.
            var replaced = ApprovalReplacement.none
            let replacedOrphan = orphan
            if let o = replacedOrphan {
                orphan = nil
                replaced = o.otherDeviceSeen || o.deviceID != hello.deviceID ? .otherDevice : .sameDevice
            }
            connections[id]?.phase = .pending(hello, deadline: now + configuration.approvalTimeoutUs,
                                              Pairing(schedule: schedule, code: code, newPairKey: newKey,
                                                      replaced: replaced))
            actions += [.send(id, .helloAck(firstAck)), .startEncryption(id, schedule.control),
                        .log(.info, ev: "handshake", conn: id, fields: "mode=pairing")]
            if let o = replacedOrphan { actions.append(.cancelApproval(o.id)) }
            actions += [.requestApproval(id, deviceID: hello.deviceID, deviceName: hello.deviceName, code: code,
                                         replaced: replaced),
                        .log(.info, ev: "approval_pending", conn: id, fields: "replaced=\(replaced.logValue)")]
        }
        return actions
    }

    /// The first authenticated record of a PAIRED connection. If a session of the same device is live (takeover), it
    /// is released and closed now; then the new one becomes active (STREAM_CONFIG, `sessionStarted`) and `first` is
    /// processed last. If another device took the slot meanwhile, this connection is answered BUSY.
    private mutating func prove(_ id: ConnectionID, _ p: Proving, first: Message, now: UInt64) -> [SessionAction] {
        var actions: [SessionAction] = []
        if let owner = slotOwner {
            var ownerDevice: DeviceID?
            switch connections[owner]?.phase {
            case .pending(let h, _, _)?: ownerDevice = h.deviceID
            case .active(let s)?: ownerDevice = s.deviceID
            default: break
            }
            guard ownerDevice == p.hello.deviceID else {
                // Someone else took the slot meanwhile.
                p.session.schedule.wipe()
                connections[id] = nil
                return [.send(id, ack(.busy)), .close(id), .log(.info, ev: "busy", conn: id, fields: "")]
            }
            actions += end(owner, bye: .superseded, cause: .superseded, close: true, ev: "session_superseded")
        }
        actions += start(id, p.hello, now: now, sessionID: p.session.id, config: p.config, schedule: p.session.schedule)
        actions += handleCommon(id, first, now: now, isActive: true)
        return actions
    }

    private static func makeSession(_ hello: Hello, sessionID: UInt32, config: StreamConfig,
                             schedule: SessionKeySchedule) -> Session {
        Session(id: sessionID, configID: config.configID, deviceID: hello.deviceID, deviceName: hello.deviceName,
                capabilities: hello.capabilities, schedule: schedule)
    }

    /// Makes the connection the active session and returns everything after the ACCEPTED HELLO_ACK
    /// (which the caller already queued: first-ack for PAIRED, second ack for PAIRING).
    private mutating func start(_ id: ConnectionID, _ hello: Hello, now: UInt64, sessionID: UInt32,
                                config: StreamConfig, schedule: SessionKeySchedule) -> [SessionAction] {
        connections[id]?.phase = .active(Self.makeSession(hello, sessionID: sessionID, config: config, schedule: schedule))
        connections[id]?.lastReceive = now  // heartbeat baseline starts at ACCEPTED, not at HELLO
        connections[id]?.silenceReleased = false
        connections[id]?.ping = HostPing(nextAt: now)  // the first host PING goes out with the next tick
        return [.send(id, .streamConfig(config)),
                .sessionStarted(id, sessionID: sessionID, configID: config.configID, hello: hello),
                .log(.info, ev: "session_started", conn: id,
                     fields: "config_id=\(config.configID) video_port=\(videoPort)")]
    }

    /// Messages valid after HELLO. `isActive == false` means still pending approval.
    private mutating func handleCommon(_ id: ConnectionID, _ message: Message, now: UInt64,
                                       isActive: Bool) -> [SessionAction] {
        switch message {
        case .ping(let p):
            return [.send(id, .pong(Pong(seq: p.seq, echoTimeUs: p.senderTimeUs, responderTimeUs: now)))]
        case .bye:
            return end(id, bye: nil, cause: .bye, close: true, ev: "bye_received", orphaning: true)
        case .hello:
            return protocolError(id)
        case .releaseAll(let reason):
            return isActive ? [.releaseInput(id, .clientRequest(reason))] : []
        case .pen, .key, .pointerRel, .pointerAbs, .scroll, .pinch, .penGesture, .stats, .keyframeRequest, .streamPrefs, .clipboard, .displayRate,
             .filesInfo:
            // Before ACCEPTED input is ignored and nothing is injected (PROTOCOL.md section 3).
            return isActive ? [.deliver(id, message)] : []
        case .audioPrefs:
            return []  // decoded, no audio behaviour yet (T-094): ignored, as before when 0x30 was unknown
        case .pong(let pong):
            return isActive ? hostPong(id, pong) : []  // T-171: only answers to the host's own PINGs
        case .helloAck, .streamConfig, .settingsOpen, .audioConfig, .audioFrame, .videoHello, .videoFrame,
             .filesNet, .filesHello, .filesHelloAck, .filesData:
            return []  // wrong direction or connection: ignored
        }
    }

    /// Tears the connection down in protocol order: release input, BYE, close, video close.
    /// Secrets of the session (or of a pending pairing) are wiped.
    private mutating func end(_ id: ConnectionID, bye: ByeReason?, cause: ReleaseCause, close: Bool,
                              ev: String, fields: String = "", orphaning: Bool = false) -> [SessionAction] {
        guard let conn = connections.removeValue(forKey: id) else { return [] }
        var actions: [SessionAction] = []
        switch conn.phase {
        case .active(let s):
            s.schedule.wipe()
            actions.append(.releaseInput(id, cause))
            if let bye { actions.append(.send(id, .bye(bye))) }
            if close { actions.append(.close(id)) }
            if let v = s.video { actions.append(.closeVideo(v)) }
            actions.append(.sessionEnded(id))
        case .pending(let hello, _, let pairing):
            pairing.schedule.wipe()
            if orphaning {
                // The tablet left (connection lost or BYE, e.g. the user switched apps): keep the window.
                if let old = orphan { actions.append(.cancelApproval(old.id)) }
                orphan = Orphan(id: id, deviceID: hello.deviceID, deviceName: hello.deviceName,
                                newPairKey: pairing.newPairKey, deadline: clock + configuration.orphanWindowUs,
                                otherDeviceSeen: pairing.replaced == .otherDevice)
                actions.append(.approvalOrphaned(id))
            } else {
                actions.append(.cancelApproval(id))
            }
            if let bye { actions.append(.send(id, .bye(bye))) }
            if close { actions.append(.close(id)) }
        case .proving(let p):
            p.session.schedule.wipe()
            if let bye { actions.append(.send(id, .bye(bye))) }
            if close { actions.append(.close(id)) }
        case .awaitingHello, .lookingUp:
            if let bye { actions.append(.send(id, .bye(bye))) }
            if close { actions.append(.close(id)) }
        }
        actions.append(.log(.info, ev: ev, conn: id, fields: fields))
        return actions
    }
}
