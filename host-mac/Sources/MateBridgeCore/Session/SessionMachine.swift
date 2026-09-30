// Pure host-side session state machine (docs/PROTOCOL.md sections 3, 6, 7).
// No I/O and no clock: every event carries `now` (monotonic microseconds), and the caller
// turns the returned actions into sends, closes and input releases, in order.

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
    /// Release every held key, button and pen contact of this session (idempotent).
    case releaseInput(ConnectionID, ReleaseCause)
    /// Message from the approved, active session that the host acts on (input, STATS, KEYFRAME_REQUEST).
    case deliver(ConnectionID, Message)
    case requestApproval(ConnectionID, deviceID: DeviceID, deviceName: String)
    case cancelApproval(ConnectionID)
    case rememberDevice(DeviceID, name: String)
    case sessionStarted(ConnectionID, sessionID: UInt32, configID: UInt16, deviceName: String)
    case sessionEnded(ConnectionID)
    /// A video connection passed VIDEO_HELLO validation.
    case videoAttached(video: ConnectionID, session: ConnectionID, sessionID: UInt32, configID: UInt16)
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

        public init(hostName: String,
                    makeStreamConfig: @escaping @Sendable (Hello) -> StreamConfig,
                    makeSessionID: @escaping @Sendable () -> UInt32 = { UInt32.random(in: 1...UInt32.max) }) {
            self.hostName = hostName
            self.makeStreamConfig = makeStreamConfig
            self.makeSessionID = makeSessionID
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
    }

    private enum Phase {
        case awaitingHello(deadline: UInt64)
        case pending(Hello, deadline: UInt64)
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
            case .pending(let hello, _): return .pending(deviceName: hello.deviceName)
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
    public mutating func approvalDecided(_ id: ConnectionID, approved: Bool, now: UInt64) -> [SessionAction] {
        guard case .pending(let hello, let deadline)? = connections[id]?.phase else { return [] }
        // An answer that arrives after the deadline (before tick ran) counts as a rejection.
        guard approved, now < deadline else {
            connections[id] = nil
            return [.send(id, ack(.rejected)), .close(id),
                    .log(.info, ev: "approval_rejected", conn: id, fields: "")]
        }
        approvedDevices.insert(hello.deviceID)
        var actions: [SessionAction] = [.rememberDevice(hello.deviceID, name: hello.deviceName),
                                        .log(.info, ev: "approval_accepted", conn: id, fields: "")]
        actions += accept(id, hello, now: now)
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
            var actions: [SessionAction] = []
            if let old = s.video, old != id { actions.append(.closeVideo(old)) }
            s.video = id
            connections[cid]?.phase = .active(s)
            actions.append(.videoAttached(video: id, session: cid, sessionID: s.id, configID: s.configID))
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
            case .pending(_, let deadline):
                if now >= deadline {
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
        var actions: [SessionAction] = []
        if let owner = slotOwner {
            var ownerDevice: DeviceID?
            switch connections[owner]?.phase {
            case .pending(let h, _)?: ownerDevice = h.deviceID
            case .active(let s)?: ownerDevice = s.deviceID
            default: break
            }
            if ownerDevice == hello.deviceID {
                // Takeover: the old session is fully released and closed before the new one is answered.
                actions += end(owner, bye: .superseded, cause: .superseded, close: true, ev: "session_superseded")
            } else {
                connections[id] = nil
                return [.send(id, ack(.busy)), .close(id), .log(.info, ev: "busy", conn: id, fields: "")]
            }
        }
        if approvedDevices.contains(hello.deviceID) {
            actions += accept(id, hello, now: now)
        } else {
            connections[id]?.phase = .pending(hello, deadline: now + configuration.approvalTimeoutUs)
            actions += [.send(id, ack(.pendingApproval)),
                        .requestApproval(id, deviceID: hello.deviceID, deviceName: hello.deviceName),
                        .log(.info, ev: "approval_pending", conn: id, fields: "")]
        }
        return actions
    }

    private mutating func accept(_ id: ConnectionID, _ hello: Hello, now: UInt64) -> [SessionAction] {
        let sessionID = max(1, configuration.makeSessionID())
        let config = configuration.makeStreamConfig(hello)
        connections[id]?.phase = .active(Session(id: sessionID, configID: config.configID,
                                                 deviceID: hello.deviceID, deviceName: hello.deviceName))
        connections[id]?.lastReceive = now  // heartbeat baseline starts at ACCEPTED, not at HELLO
        connections[id]?.silenceReleased = false
        return [.send(id, ack(.accepted, sessionID: sessionID, videoPort: videoPort)),
                .send(id, .streamConfig(config)),
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
    private mutating func end(_ id: ConnectionID, bye: ByeReason?, cause: ReleaseCause, close: Bool,
                              ev: String) -> [SessionAction] {
        guard let conn = connections.removeValue(forKey: id) else { return [] }
        var actions: [SessionAction] = []
        switch conn.phase {
        case .active(let s):
            actions.append(.releaseInput(id, cause))
            if let bye { actions.append(.send(id, .bye(bye))) }
            if close { actions.append(.close(id)) }
            if let v = s.video { actions.append(.closeVideo(v)) }
            actions.append(.sessionEnded(id))
        case .pending:
            actions.append(.cancelApproval(id))
            if let bye { actions.append(.send(id, .bye(bye))) }
            if close { actions.append(.close(id)) }
        case .awaitingHello:
            if let bye { actions.append(.send(id, .bye(bye))) }
            if close { actions.append(.close(id)) }
        }
        actions.append(.log(.info, ev: ev, conn: id, fields: ""))
        return actions
    }
}
