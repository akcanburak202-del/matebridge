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
    /// Host-internal, never produced by `SessionMachine`: the virtual display or the Accessibility permission went
    /// away while input was held (T-023), so the input pipeline releases it by itself.
    case gateLost
}

public enum LogLevel: String, Sendable { case error = "E", warning = "W", info = "I", debug = "D" }

public enum SessionAction: Equatable, Sendable {
    /// Send on the control connection.
    case send(ConnectionID, Message)
    /// Close a control connection (after flushing queued sends).
    case close(ConnectionID)
    case closeVideo(ConnectionID)
    /// Right after the first HELLO_ACK was sent (which stays plaintext): every later message on this control
    /// connection is sealed with `h2c` and every inbound byte is an encrypted record under `c2h`.
    case startEncryption(ConnectionID, ControlKeys)
    /// Release every held key, button and pen contact of this session (idempotent).
    case releaseInput(ConnectionID, ReleaseCause)
    /// Message from the approved, active session that the host acts on (input, STATS, KEYFRAME_REQUEST).
    case deliver(ConnectionID, Message)
    /// `code` is shown in the approval window only (never logged).
    case requestApproval(ConnectionID, deviceID: DeviceID, deviceName: String, code: PairingCode)
    case cancelApproval(ConnectionID)
    /// The user accepted a pairing. The caller stores `key` (Keychain) and the device list, then reports the outcome
    /// with `pairingPersisted`; ACCEPTED is sent only after a successful store.
    case persistPairing(ConnectionID, deviceID: DeviceID, name: String, key: SecretBytes)
    case sessionStarted(ConnectionID, sessionID: UInt32, configID: UInt16, deviceName: String)
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
        /// Fills the STREAM_CONFIG sent after ACCEPTED. `configID` must be nonzero.
        public var makeStreamConfig: @Sendable (Hello) -> StreamConfig
        public var makeSessionID: @Sendable () -> UInt32
        /// Persistent `host_id` (HELLO_ACK). Default: random per machine (tests); the app passes `HostIdentityStore`'s.
        public var hostID: [UInt8]
        /// Pair keys: PAIRED needs an approved device *and* a key here.
        public var pairKeys: PairKeyStore
        public var makeEphemeral: @Sendable () -> EphemeralKeyPair = { EphemeralKeyPair() }
        public var makeNonce: @Sendable () -> [UInt8] = {
            (0..<ProtocolConstants.nonceSize).map { _ in UInt8.random(in: 0...255) }
        }
        /// At most this many video connections are attached per session. Each needs a fresh `video_nonce`.
        public var maxVideoAttaches = 64

        public init(hostName: String,
                    makeStreamConfig: @escaping @Sendable (Hello) -> StreamConfig,
                    makeSessionID: @escaping @Sendable () -> UInt32 = { UInt32.random(in: 1...UInt32.max) },
                    hostID: [UInt8] = (0..<ProtocolConstants.deviceIDSize).map { _ in UInt8.random(in: 0...255) },
                    pairKeys: PairKeyStore = InMemoryPairKeyStore()) {
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
        var video: ConnectionID?
        /// Holds the session `prk` for video key derivation; wiped when the session ends.
        var schedule: SessionKeySchedule
        /// `video_nonce` values already used: a replayed VIDEO_HELLO must never reuse a GCM key and nonce.
        var videoNonces: Set<[UInt8]> = []
    }

    private struct Pairing {
        var schedule: SessionKeySchedule
        var code: PairingCode
        var newPairKey: SecretBytes
    }

    private enum Phase {
        case awaitingHello(deadline: UInt64)
        case pending(Hello, deadline: UInt64, Pairing)
        case active(Session)
    }

    private struct Conn {
        var phase: Phase
        var lastReceive: UInt64
        var silenceReleased = false
    }

    private var connections: [ConnectionID: Conn] = [:]
    private var videoConnections: [ConnectionID: UInt64] = [:]  // opened, awaiting VIDEO_HELLO

    public init(configuration: Configuration, approvedDevices: Set<DeviceID> = []) {
        self.configuration = configuration
        self.approvedDevices = approvedDevices
    }

    public var status: SessionStatus {
        for conn in connections.values {
            switch conn.phase {
            case .pending(let hello, _, _): return .pending(deviceName: hello.deviceName)
            case .active(let s): return .active(deviceName: s.deviceName, sessionID: s.id)
            case .awaitingHello: continue
            }
        }
        return .idle
    }

    /// Control connections that have not sent HELLO yet (unauthenticated; the host caps these).
    public var awaitingHelloCount: Int {
        connections.values.filter { if case .awaitingHello = $0.phase { true } else { false } }.count
    }

    /// Video connections that have not yet passed VIDEO_HELLO.
    public var pendingVideoCount: Int { videoConnections.count }

    public mutating func forgetApprovedDevices() { approvedDevices.removeAll() }

    /// Test hook: the key schedule held for a connection (active session or pending pairing).
    func scheduleForTesting(_ id: ConnectionID) -> SessionKeySchedule? {
        switch connections[id]?.phase {
        case .active(let s)?: s.schedule
        case .pending(_, _, let p)?: p.schedule
        default: nil
        }
    }

    // MARK: Control connection events

    public mutating func connectionOpened(_ id: ConnectionID, now: UInt64) -> [SessionAction] {
        connections[id] = Conn(phase: .awaitingHello(deadline: now + configuration.helloTimeoutUs), lastReceive: now)
        return [.log(.debug, ev: "control_open", conn: id, fields: "")]
    }

    /// The transport closed the connection (or failed). Releases input if it was the live session.
    public mutating func connectionClosed(_ id: ConnectionID) -> [SessionAction] {
        end(id, bye: nil, cause: .disconnected, close: false, ev: "control_closed")
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
        case .active:
            return handleCommon(id, message, now: now, isActive: true)
        }
    }

    /// The user answered the approval dialog. Ignored unless the connection is still pending.
    /// Accepting is two steps: this returns `persistPairing`, the caller stores the key, then `pairingPersisted`.
    public mutating func approvalDecided(_ id: ConnectionID, approved: Bool, now: UInt64) -> [SessionAction] {
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
        for (cid, conn) in connections {
            if case .active(var s) = conn.phase, s.video == id {
                s.video = nil
                connections[cid]?.phase = .active(s)
            }
        }
        return [.log(.debug, ev: "video_closed", conn: id, fields: "")]
    }

    /// First and only C->H message on a video connection. Anything stale closes only the video connection.
    public mutating func videoHello(_ id: ConnectionID, _ hello: VideoHello, now: UInt64) -> [SessionAction] {
        guard videoConnections.removeValue(forKey: id) != nil else { return [.closeVideo(id)] }
        for (cid, conn) in connections {
            guard case .active(var s) = conn.phase,
                  hello.protocolVersion == ProtocolConstants.protocolVersion,
                  hello.sessionID == s.id, hello.configID == s.configID else { continue }
            // One (key, nonce) pair must never encrypt two different streams: a captured VIDEO_HELLO replayed by
            // someone else would derive the same keys. Refuse a repeated nonce (and cap the number per session).
            guard !s.videoNonces.contains(hello.videoNonce), s.videoNonces.count < configuration.maxVideoAttaches,
                  let keys = s.schedule.videoKeys(nonce: hello.videoNonce) else {
                return [.closeVideo(id), .log(.warning, ev: "video_hello_rejected", conn: id, fields: "reason=nonce")]
            }
            s.videoNonces.insert(hello.videoNonce)
            var actions: [SessionAction] = []
            if let old = s.video, old != id { actions.append(.closeVideo(old)) }
            s.video = id
            connections[cid]?.phase = .active(s)
            actions.append(.videoAttached(video: id, session: cid, sessionID: s.id, configID: s.configID, keys: keys))
            return actions
        }
        return [.closeVideo(id), .log(.warning, ev: "video_hello_rejected", conn: id, fields: "")]
    }

    // MARK: Time and shutdown

    public mutating func tick(now: UInt64) -> [SessionAction] {
        var actions: [SessionAction] = []
        for id in connections.keys.sorted(by: { $0.raw < $1.raw }) {
            guard let conn = connections[id] else { continue }
            switch conn.phase {
            case .awaitingHello(let deadline):
                if now >= deadline {
                    connections[id] = nil
                    actions += [.close(id), .log(.warning, ev: "hello_timeout", conn: id, fields: "")]
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
                } else if silent >= configuration.releaseSilenceUs, !conn.silenceReleased {
                    connections[id]?.silenceReleased = true
                    actions += [.releaseInput(id, .silence),
                                .log(.warning, ev: "heartbeat_silence", conn: id, fields: "")]
                }
            }
        }
        for (vid, deadline) in videoConnections.sorted(by: { $0.key.raw < $1.key.raw }) where now >= deadline {
            videoConnections[vid] = nil
            actions += [.closeVideo(vid), .log(.warning, ev: "video_hello_timeout", conn: vid, fields: "")]
        }
        return actions
    }

    /// Host app is quitting: release input, tell every peer, close everything.
    public mutating func shutdown() -> [SessionAction] {
        var actions: [SessionAction] = []
        for id in connections.keys.sorted(by: { $0.raw < $1.raw }) {
            actions += end(id, bye: .shuttingDown, cause: .shutdown, close: true, ev: "shutdown")
        }
        for vid in videoConnections.keys.sorted(by: { $0.raw < $1.raw }) { actions.append(.closeVideo(vid)) }
        videoConnections.removeAll()
        return actions
    }

    // MARK: Internals

    private func ack(_ status: HelloStatus, sessionID: UInt32 = 0, videoPort: UInt16 = 0) -> Message {
        .helloAck(HelloAck(status: status, sessionID: sessionID, videoPort: videoPort,
                           hostName: configuration.hostName))
    }

    /// The connection holding the single session slot (pending or active).
    private var slotOwner: ConnectionID? {
        connections.first { entry in
            if case .awaitingHello = entry.value.phase { return false }
            return true
        }?.key
    }

    private mutating func handleHello(_ id: ConnectionID, _ hello: Hello, now: UInt64) -> [SessionAction] {
        guard hello.protocolVersion == ProtocolConstants.protocolVersion else {
            connections[id] = nil
            return [.send(id, ack(.versionMismatch)), .close(id),
                    .log(.warning, ev: "version_mismatch", conn: id, fields: "peer_version=\(hello.protocolVersion)")]
        }
        var takeover: ConnectionID?
        if let owner = slotOwner {
            var ownerDevice: DeviceID?
            switch connections[owner]?.phase {
            case .pending(let h, _, _)?: ownerDevice = h.deviceID
            case .active(let s)?: ownerDevice = s.deviceID
            default: break
            }
            if ownerDevice == hello.deviceID {
                takeover = owner
            } else {
                connections[id] = nil
                return [.send(id, ack(.busy)), .close(id), .log(.info, ev: "busy", conn: id, fields: "")]
            }
        }
        // The key exchange is checked before an existing session is disturbed: a garbage key must not end it.
        let ephemeral = configuration.makeEphemeral()
        guard let ecdh = try? ephemeral.sharedSecret(withPeerPublicKey: hello.clientEphPub) else {
            return protocolError(id)
        }
        var actions: [SessionAction] = []
        if let owner = takeover {
            // Takeover: the old session is fully released and closed before the new one is answered.
            actions += end(owner, bye: .superseded, cause: .superseded, close: true, ev: "session_superseded")
        }
        let pairKey = approvedDevices.contains(hello.deviceID) ? configuration.pairKeys.key(for: hello.deviceID) : nil
        let hostNonce = configuration.makeNonce()
        guard hostNonce.count == ProtocolConstants.nonceSize else { return actions + protocolError(id) }
        if let pairKey {
            let sessionID = max(1, configuration.makeSessionID())
            let config = configuration.makeStreamConfig(hello)
            let firstAck = HelloAck(status: .accepted, sessionID: sessionID, videoPort: videoPort,
                                    hostName: configuration.hostName, keyMode: .paired, hostID: configuration.hostID,
                                    hostNonce: hostNonce, hostEphPub: ephemeral.publicKeyBytes)
            guard let schedule = try? SessionKeySchedule.derive(
                ecdh: ecdh, pairKey: pairKey, helloPayload: hello.transcriptBytes,
                ackPayload: Message.helloAck(firstAck).encodePayload()) else { return actions + protocolError(id) }
            actions += [.send(id, .helloAck(firstAck)), .startEncryption(id, schedule.control),
                        .log(.info, ev: "handshake", conn: id, fields: "mode=paired")]
            actions += start(id, hello, now: now, sessionID: sessionID, config: config, schedule: schedule)
        } else {
            let firstAck = HelloAck(status: .pendingApproval, sessionID: 0, videoPort: 0,
                                    hostName: configuration.hostName, keyMode: .pairing, hostID: configuration.hostID,
                                    hostNonce: hostNonce, hostEphPub: ephemeral.publicKeyBytes)
            guard let schedule = try? SessionKeySchedule.derive(
                ecdh: ecdh, pairKey: nil, helloPayload: hello.transcriptBytes,
                ackPayload: Message.helloAck(firstAck).encodePayload()),
                  let code = schedule.pairingCode, let newKey = schedule.newPairKey else {
                return actions + protocolError(id)
            }
            connections[id]?.phase = .pending(hello, deadline: now + configuration.approvalTimeoutUs,
                                              Pairing(schedule: schedule, code: code, newPairKey: newKey))
            actions += [.send(id, .helloAck(firstAck)), .startEncryption(id, schedule.control),
                        .requestApproval(id, deviceID: hello.deviceID, deviceName: hello.deviceName, code: code),
                        .log(.info, ev: "handshake", conn: id, fields: "mode=pairing"),
                        .log(.info, ev: "approval_pending", conn: id, fields: "")]
        }
        return actions
    }

    /// Makes the connection the active session and returns everything after the ACCEPTED HELLO_ACK
    /// (which the caller already queued: first-ack for PAIRED, second ack for PAIRING).
    private mutating func start(_ id: ConnectionID, _ hello: Hello, now: UInt64, sessionID: UInt32,
                                config: StreamConfig, schedule: SessionKeySchedule) -> [SessionAction] {
        connections[id]?.phase = .active(Session(id: sessionID, configID: config.configID,
                                                 deviceID: hello.deviceID, deviceName: hello.deviceName,
                                                 schedule: schedule))
        connections[id]?.lastReceive = now  // heartbeat baseline starts at ACCEPTED, not at HELLO
        connections[id]?.silenceReleased = false
        return [.send(id, .streamConfig(config)),
                .sessionStarted(id, sessionID: sessionID, configID: config.configID, deviceName: hello.deviceName),
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
            return end(id, bye: nil, cause: .bye, close: true, ev: "bye_received")
        case .hello:
            return protocolError(id)
        case .releaseAll(let reason):
            return isActive ? [.releaseInput(id, .clientRequest(reason))] : []
        case .pen, .key, .pointerRel, .pointerAbs, .scroll, .pinch, .penGesture, .stats, .keyframeRequest:
            // Before ACCEPTED input is ignored and nothing is injected (PROTOCOL.md section 3).
            return isActive ? [.deliver(id, message)] : []
        case .helloAck, .streamConfig, .pong, .videoHello, .videoFrame:
            return []  // wrong direction or connection: ignored
        }
    }

    /// Tears the connection down in protocol order: release input, BYE, close, video close.
    /// Secrets of the session (or of a pending pairing) are wiped.
    private mutating func end(_ id: ConnectionID, bye: ByeReason?, cause: ReleaseCause, close: Bool,
                              ev: String, fields: String = "") -> [SessionAction] {
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
        case .pending(_, _, let pairing):
            pairing.schedule.wipe()
            actions.append(.cancelApproval(id))
            if let bye { actions.append(.send(id, .bye(bye))) }
            if close { actions.append(.close(id)) }
        case .awaitingHello:
            if let bye { actions.append(.send(id, .bye(bye))) }
            if close { actions.append(.close(id)) }
        }
        actions.append(.log(.info, ev: ev, conn: id, fields: fields))
        return actions
    }
}
