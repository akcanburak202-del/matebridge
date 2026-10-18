// Pure host-side state machine of the tablet camera connection (decision 0040, docs/PROTOCOL.md section 4 "Kamera
// bağlantısı"). No I/O and no clock: every event that needs time carries `now` (monotonic microseconds); the caller
// (the host's camera listener) turns the returned actions into sends, closes and decoding. Same shape as
// `FilesConnectionMachine`, but with at most one *active* connection and at most one connection that has not proven
// itself. The machine never sees camera content, keys or nonces in log fields.

public struct CameraConnID: Hashable, Sendable {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
}

/// Why a camera connection is closed. Only these tokens reach a log.
public enum CameraCloseReason: String, Sendable {
    /// No listener is open (stopped or the session ended).
    case notOpen = "not_open"
    /// The peer address is not the control connection's.
    case peerMismatch = "peer_mismatch"
    /// Another connection has not proven itself yet (at most 1).
    case unprovenLimit = "unproven_limit"
    /// No `CAM_HELLO` within 5 s of the TCP accept.
    case helloTimeout = "hello_timeout"
    /// No authenticated PING within 5 s of the TCP accept (the `CAM_HELLO` wait counts).
    case proofTimeout = "proof_timeout"
    /// `CAM_HELLO` failed the checks (version, session, cam_id); answered `REJECTED`.
    case rejected
    /// Unknown-direction or wrong-state message, or a malformed payload.
    case protocolError = "protocol_error"
    /// A record failed authentication (or had an invalid length).
    case authFailed = "auth_failed"
    /// A proven newer connection replaced this one.
    case superseded
    /// The session's keys could not be derived any more.
    case keysUnavailable = "keys_unavailable"
    /// START ended (STOP, new `cam_id`, mode OFF), the session ended or the host shut down.
    case sessionEnded = "session_ended"
}

public enum CameraAction: Equatable, Sendable {
    /// Send this plain `CAM_HELLO_ACK`; for REJECTED the `close` that follows it flushes it first.
    case sendAck(CameraConnID, CamHelloAck)
    /// The ACK was OK: derive the keys with `SessionMachine.cameraKeys(sessionID:clientNonce:hostNonce:)`; from now on
    /// every inbound byte is a record under `c2h` and every outbound message is sealed under `h2c`. If the derivation
    /// returns nil, report `keysUnavailable`.
    case startRecords(CameraConnID, clientNonce: [UInt8], hostNonce: [UInt8])
    /// Close the connection (flush queued sends first). It no longer counts as live.
    case close(CameraConnID, CameraCloseReason)
    /// The first authenticated PING arrived: this connection is now the active one. A host-side first request for a
    /// keyframe goes out now (`CAM_KEYFRAME_REQUEST(STARTUP)`). The older active connection, if any, has its own
    /// `close(.superseded)` in the same list.
    case activated(CameraConnID)
    /// A proven connection's `CAM_FRAME` (the caller holds the message): decode it.
    case frame(CameraConnID)
    /// `fields` is preformatted `key=value` text: counters and states only, never content, keys or nonces.
    case log(LogLevel, ev: String, conn: CameraConnID?, fields: String)
}

public struct CameraConnectionMachine: Sendable {
    public struct Configuration: Sendable {
        /// TCP accept to proven (the `CAM_HELLO` wait included): PROTOCOL.md section 4 steps 2 and 4.
        public var proofTimeoutUs: UInt64 = 5_000_000
        /// Connections that have not proven themselves: more are closed as soon as they are accepted.
        public var maxUnproven = 1
        public var makeNonce: @Sendable () -> [UInt8] = {
            (0..<ProtocolConstants.nonceSize).map { _ in UInt8.random(in: 0...255) }
        }
        public init() {}
    }

    private enum State {
        case awaitingHello(deadline: UInt64)
        case awaitingProof(deadline: UInt64)
        case active
    }

    public var configuration: Configuration

    private var listening = false
    private var sessionID: UInt32 = 0
    private var camID: UInt16 = 0
    private var controlPeer = ""
    private var conns: [CameraConnID: State] = [:]

    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }

    public var isOpen: Bool { listening }
    public var connectionCount: Int { conns.count }
    public var unprovenCount: Int {
        conns.values.reduce(0) {
            switch $1 {
            case .awaitingHello, .awaitingProof: $0 + 1
            case .active: $0
            }
        }
    }
    /// The one proven connection, if any.
    public var activeConnection: CameraConnID? {
        conns.first { if case .active = $0.value { return true } else { return false } }?.key
    }

    /// Earliest instant a `tick` has something to do, nil when nothing is pending.
    public var nextDeadline: UInt64? {
        var times: [UInt64] = []
        for state in conns.values {
            switch state {
            case .awaitingHello(let d), .awaitingProof(let d): times.append(d)
            case .active: break
            }
        }
        return times.min()
    }

    // MARK: Lifecycle

    /// The listener is up and `CAMERA_CONTROL(START, camID)` is about to be sent. Every connection of an earlier START
    /// closes first.
    public mutating func open(sessionID: UInt32, camID: UInt16, controlPeer: String) -> [CameraAction] {
        var out = closeAll(.sessionEnded)
        listening = true
        self.sessionID = sessionID
        self.camID = camID
        self.controlPeer = controlPeer
        out.append(.log(.info, ev: "camera_listen", conn: nil, fields: "state=open cam_id=\(camID)"))
        return out
    }

    /// STOP, a new START, mode OFF, session end (BYE, HOST_SLEEP, takeover, connection loss) or shutdown: every
    /// camera connection closes; the caller closes the listener.
    public mutating func close(_ reason: CameraCloseReason = .sessionEnded) -> [CameraAction] {
        var out = closeAll(reason)
        if listening {
            out.append(.log(.info, ev: "camera_listen", conn: nil, fields: "state=close cam_id=\(camID) reason=\(reason.rawValue)"))
        }
        listening = false
        sessionID = 0
        camID = 0
        controlPeer = ""
        return out
    }

    // MARK: Connection events

    /// A TCP connection reached the camera listener. `peer` is its remote address.
    public mutating func accepted(_ id: CameraConnID, peer: String, now: UInt64) -> [CameraAction] {
        guard listening else { return [.close(id, .notOpen)] }
        guard FilesPeer.same(peer, controlPeer) else {
            return [.close(id, .peerMismatch), .log(.warning, ev: "camera_conn", conn: id, fields: "state=refused reason=peer_mismatch")]
        }
        guard unprovenCount < configuration.maxUnproven else {
            return [.close(id, .unprovenLimit), .log(.warning, ev: "camera_conn", conn: id, fields: "state=refused reason=unproven_limit")]
        }
        conns[id] = .awaitingHello(deadline: now + configuration.proofTimeoutUs)
        return []
    }

    /// The plain `CAM_HELLO`. Accepted only while listening, for protocol version 1, the current session and the
    /// current `cam_id`; otherwise `REJECTED` (zero nonce) and close. A HELLO that arrives after the 5 s from the TCP
    /// accept closes without an answer, even when the tick has not run yet.
    public mutating func hello(_ id: CameraConnID, _ hello: CamHello, now: UInt64) -> [CameraAction] {
        guard case .awaitingHello(let deadline)? = conns[id] else {
            return conns[id] == nil ? [] : protocolError(id)
        }
        guard now < deadline else {
            conns[id] = nil
            return [.close(id, .helloTimeout), .log(.warning, ev: "camera_conn", conn: id, fields: "state=timeout reason=hello_timeout")]
        }
        var reason: String?
        if hello.protocolVersion != ProtocolConstants.protocolVersion {
            reason = "version"
        } else if !listening || hello.sessionID != sessionID {
            reason = "session"
        } else if hello.camID != camID {
            reason = "cam_id"
        }
        if let reason {
            conns[id] = nil
            return [.sendAck(id, .rejected), .close(id, .rejected),
                    .log(.warning, ev: "camera_conn", conn: id, fields: "state=rejected reason=\(reason)")]
        }
        let hostNonce = configuration.makeNonce()
        guard hostNonce.count == ProtocolConstants.nonceSize else { return protocolError(id) }
        conns[id] = .awaitingProof(deadline: deadline)
        return [.sendAck(id, CamHelloAck(status: .ok, hostNonce: hostNonce)),
                .startRecords(id, clientNonce: hello.clientNonce, hostNonce: hostNonce)]
    }

    /// The key derivation after `startRecords` returned nil: the session is gone.
    public mutating func keysUnavailable(_ id: CameraConnID) -> [CameraAction] {
        guard conns.removeValue(forKey: id) != nil else { return [] }
        return [.close(id, .keysUnavailable)]
    }

    /// An authenticated record arrived. The first one must be a PING (the proof); the proof activates the connection
    /// and closes the older active one. A `CAM_FRAME` is valid only on the active connection; PINGs after the proof
    /// are keep-alives and get no PONG. Any other known type, or a type of the wrong direction, ends only this
    /// connection. Unknown types never get here (the decoder skips them).
    public mutating func record(_ id: CameraConnID, _ message: Message, now: UInt64) -> [CameraAction] {
        guard let state = conns[id] else { return [] }
        switch (state, message) {
        case (.awaitingProof(let deadline), .ping):
            // The 5 s run from the TCP accept: a proof that is processed late (before a delayed tick) is too late.
            guard now < deadline else {
                conns[id] = nil
                return [.close(id, .proofTimeout), .log(.warning, ev: "camera_conn", conn: id, fields: "state=timeout reason=proof_timeout")]
            }
            var out: [CameraAction] = []
            if let old = activeConnection, old != id {
                conns[old] = nil
                out += [.close(old, .superseded), .log(.info, ev: "camera_conn", conn: old, fields: "state=closed reason=superseded")]
            }
            conns[id] = .active
            out += [.activated(id), .log(.info, ev: "camera_conn", conn: id, fields: "state=proven cam_id=\(camID)")]
            return out
        case (.active, .ping):
            return []
        case (.active, .camFrame):
            return [.frame(id)]
        default:
            return protocolError(id)
        }
    }

    /// The decoder or the record layer reported a protocol violation (malformed payload, `CAM_FRAME` with size 0).
    public mutating func protocolError(_ id: CameraConnID) -> [CameraAction] {
        end(id, .protocolError, level: .warning)
    }

    /// A record failed authentication or had an invalid length (PROTOCOL.md section 9): no reply, close.
    public mutating func recordAuthFailed(_ id: CameraConnID) -> [CameraAction] {
        end(id, .authFailed, level: .warning)
    }

    /// The transport closed or failed (the peer hung up, a write failed).
    public mutating func connectionClosed(_ id: CameraConnID) -> [CameraAction] {
        guard let state = conns.removeValue(forKey: id) else { return [] }
        if case .active = state {
            return [.log(.info, ev: "camera_conn", conn: id, fields: "state=closed reason=peer_closed")]
        }
        return []
    }

    // MARK: Time

    public mutating func tick(now: UInt64) -> [CameraAction] {
        var out: [CameraAction] = []
        for id in conns.keys.sorted(by: { $0.raw < $1.raw }) {
            switch conns[id] {
            case .awaitingHello(let deadline)? where now >= deadline:
                conns[id] = nil
                out += [.close(id, .helloTimeout), .log(.warning, ev: "camera_conn", conn: id, fields: "state=timeout reason=hello_timeout")]
            case .awaitingProof(let deadline)? where now >= deadline:
                conns[id] = nil
                out += [.close(id, .proofTimeout), .log(.warning, ev: "camera_conn", conn: id, fields: "state=timeout reason=proof_timeout")]
            default:
                break
            }
        }
        return out
    }

    // MARK: Internals

    private mutating func end(_ id: CameraConnID, _ reason: CameraCloseReason, level: LogLevel) -> [CameraAction] {
        guard conns.removeValue(forKey: id) != nil else { return [] }
        return [.close(id, reason), .log(level, ev: "camera_conn", conn: id, fields: "state=closed reason=\(reason.rawValue)")]
    }

    private mutating func closeAll(_ reason: CameraCloseReason) -> [CameraAction] {
        var out: [CameraAction] = []
        for id in conns.keys.sorted(by: { $0.raw < $1.raw }) {
            conns[id] = nil
            out.append(.close(id, reason))
        }
        return out
    }
}
