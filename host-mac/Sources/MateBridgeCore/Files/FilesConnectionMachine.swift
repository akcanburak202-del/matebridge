// Pure host-side state machine of the Wi-Fi file connections (decision 0035, docs/PROTOCOL.md section 4 "Dosya
// bağlantısı", section 5). No I/O and no clock: every event that needs time carries `now` (monotonic microseconds),
// and the caller (the host's file listener and loopback proxy) turns the returned actions into sends, closes and
// byte forwarding. The machine never sees file or HTTP content, keys, tokens or nonces in log fields.

public struct FilesConnID: Hashable, Sendable {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
}

/// A connection from Finder (NetFS/webdavfs) to the loopback proxy.
public struct LocalConnID: Hashable, Sendable {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
}

/// Why a file connection (or a waiting local connection) is closed. Only these tokens reach a log.
public enum FilesCloseReason: String, Sendable {
    /// No listener is open (before `FILES_NET(OPEN)` or after the session ended).
    case notOpen = "not_open"
    /// The peer address is not the control connection's.
    case peerMismatch = "peer_mismatch"
    /// Already 2 connections that have not proven themselves.
    case unprovenLimit = "unproven_limit"
    /// No `FILES_HELLO` within 5 s of the TCP accept.
    case helloTimeout = "hello_timeout"
    /// No authenticated PING within 5 s of the TCP accept (the `FILES_HELLO` wait counts).
    case proofTimeout = "proof_timeout"
    /// `FILES_HELLO` failed the checks (version, session, capacity); answered `REJECTED`.
    case rejected
    case protocolError = "protocol_error"
    /// A record failed authentication (or had an invalid length).
    case authFailed = "auth_failed"
    /// 30 s without any record on an idle connection.
    case idleTimeout = "idle_timeout"
    /// The Finder side of a bound connection closed.
    case localClosed = "local_closed"
    /// The file connection of a bound local connection closed.
    case fileClosed = "file_closed"
    /// `FILES_NET(CLOSE)`, session end, OFF or shutdown.
    case sessionEnded = "session_ended"
    /// The session's keys could not be derived any more (the session is gone).
    case keysUnavailable = "keys_unavailable"
    /// A local connection found no idle file connection within 5 s.
    case noIdleConnection = "no_idle_connection"
    /// 8 local connections already wait for a file connection.
    case tooManyWaiting = "too_many_waiting"
}

public enum FilesAction: Equatable, Sendable {
    /// Send this plain `FILES_HELLO_ACK`, then (for REJECTED) the close that follows it in the list.
    case sendAck(FilesConnID, FilesHelloAck)
    /// The ACK was OK: derive the keys with `SessionMachine.filesKeys(sessionID:clientNonce:hostNonce:)`, then every
    /// inbound byte is a record under `c2h` and every outbound message is sealed under `h2c`. If the derivation
    /// returns nil, report `keysUnavailable`.
    case startRecords(FilesConnID, clientNonce: [UInt8], hostNonce: [UInt8])
    /// Close the file connection after flushing queued sends. The machine has already forgotten it.
    case close(FilesConnID, FilesCloseReason)
    /// A local connection was paired with an idle file connection: from now on bytes read from the local connection
    /// go out as `FILES_DATA` (the first one tells the machine through `hostSentData`).
    case bind(FilesConnID, LocalConnID)
    /// Close the local connection after writing the bytes still owed to it. The machine has already forgotten it.
    case closeLocal(LocalConnID, FilesCloseReason)
    /// The `FILES_DATA` that was just reported is valid: write its bytes to this local connection.
    case dataToLocal(FilesConnID, LocalConnID)
    /// `fields` is preformatted `key=value` text: counters and states only, never content, keys, nonces or paths.
    case log(LogLevel, ev: String, conn: FilesConnID?, fields: String)
}

/// Counters for the once-per-second log line.
public struct FilesPoolCounts: Equatable, Sendable {
    public var total = 0
    public var unproven = 0
    public var idle = 0
    public var bound = 0
    public var waitingLocal = 0
}

/// Normalization of peer addresses for the "same host as the control connection" check.
public enum FilesPeer {
    /// Lower case, without a `%scope` and without the `::ffff:` prefix of an IPv4-mapped IPv6 address.
    public static func normalized(_ host: String) -> String {
        var h = host.lowercased()
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
        if h.hasPrefix("::ffff:"), h.dropFirst(7).contains(".") { h = String(h.dropFirst(7)) }
        return h
    }

    public static func same(_ a: String, _ b: String) -> Bool { normalized(a) == normalized(b) }
}

public struct FilesConnectionMachine: Sendable {
    public struct Configuration: Sendable {
        /// TCP accept to proven (the `FILES_HELLO` wait included): PROTOCOL.md section 4 steps 2 and 4.
        public var proofTimeoutUs: UInt64 = 5_000_000
        /// An idle proven connection with no record for this long is closed (the client PINGs every 10 s).
        public var idleTimeoutUs: UInt64 = 30_000_000
        /// A local connection waits this long for an idle file connection.
        public var localWaitUs: UInt64 = 5_000_000
        /// Connections that have not proven themselves: more are closed as soon as they are accepted.
        public var maxUnproven = 2
        /// Local connections waiting for a file connection.
        public var maxWaitingLocal = 8
        public var makeNonce: @Sendable () -> [UInt8] = {
            (0..<ProtocolConstants.nonceSize).map { _ in UInt8.random(in: 0...255) }
        }
        public init() {}
    }

    private enum State {
        case awaitingHello(deadline: UInt64)
        case awaitingProof(deadline: UInt64)
        /// Proven and unpaired. `since` orders the pool (oldest first), `lastReceive` drives the idle timeout.
        case idle(since: UInt64, lastReceive: UInt64)
        case bound(LocalConnID, hostSentData: Bool)
    }

    private struct Waiting {
        var id: LocalConnID
        var deadline: UInt64
    }

    public var configuration: Configuration

    private var listening = false
    private var sessionID: UInt32 = 0
    private var controlPeer = ""
    private var maxConnections = 0
    private var pool = 0
    private var conns: [FilesConnID: State] = [:]
    private var waiting: [Waiting] = []
    private var provenCount: UInt64 = 0

    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }

    public var isOpen: Bool { listening }

    public var counts: FilesPoolCounts {
        var c = FilesPoolCounts()
        c.total = conns.count
        c.waitingLocal = waiting.count
        for state in conns.values {
            switch state {
            case .awaitingHello, .awaitingProof: c.unproven += 1
            case .idle: c.idle += 1
            case .bound: c.bound += 1
            }
        }
        return c
    }

    /// The local connection a file connection is paired with.
    public func local(for id: FilesConnID) -> LocalConnID? {
        if case .bound(let local, _)? = conns[id] { return local }
        return nil
    }

    /// Earliest instant a `tick` has something to do, nil when nothing is pending.
    public var nextDeadline: UInt64? {
        var times: [UInt64] = waiting.map(\.deadline)
        for state in conns.values {
            switch state {
            case .awaitingHello(let d), .awaitingProof(let d): times.append(d)
            case .idle(_, let last): times.append(last + configuration.idleTimeoutUs)
            case .bound: break
            }
        }
        return times.min()
    }

    // MARK: Lifecycle

    /// `FILES_NET(OPEN)` was sent and the listener is up. `sessionID` and `controlPeer` (the peer address of the
    /// session's control connection) are what every file connection is checked against. `max` and `pool` are the
    /// values that went into `FILES_NET`. Opening again for the same session only updates `max`/`pool`; for another
    /// session every connection of the old one closes first.
    public mutating func open(sessionID: UInt32, controlPeer: String, max: Int, pool: Int) -> [FilesAction] {
        var out: [FilesAction] = []
        if listening, self.sessionID != sessionID { out += closeAll(.sessionEnded) }
        listening = true
        self.sessionID = sessionID
        self.controlPeer = controlPeer
        maxConnections = max
        self.pool = pool
        out.append(.log(.info, ev: "files_net", conn: nil, fields: "state=open max=\(max) pool=\(pool)"))
        return out
    }

    /// `FILES_NET(CLOSE)`, session end (BYE, HOST_SLEEP, takeover, connection loss), `FILES_INFO(OFF)` or shutdown:
    /// every file connection and every waiting local connection closes, the listener is to be closed by the caller.
    public mutating func close(_ reason: FilesCloseReason = .sessionEnded) -> [FilesAction] {
        guard listening else { return closeAll(reason) }
        var out = closeAll(reason)
        listening = false
        sessionID = 0
        controlPeer = ""
        out.append(.log(.info, ev: "files_net", conn: nil, fields: "state=close reason=\(reason.rawValue)"))
        return out
    }

    // MARK: File connection events

    /// A TCP connection reached the file listener. `peer` is its remote address.
    public mutating func accepted(_ id: FilesConnID, peer: String, now: UInt64) -> [FilesAction] {
        guard listening else { return [.close(id, .notOpen)] }
        guard FilesPeer.same(peer, controlPeer) else {
            return [.close(id, .peerMismatch), .log(.warning, ev: "files_conn", conn: id, fields: "state=refused reason=peer_mismatch")]
        }
        guard unprovenCount < configuration.maxUnproven else {
            return [.close(id, .unprovenLimit), .log(.warning, ev: "files_conn", conn: id, fields: "state=refused reason=unproven_limit")]
        }
        conns[id] = .awaitingHello(deadline: now + configuration.proofTimeoutUs)
        return []
    }

    /// The plain `FILES_HELLO` of a connection. Accepted only for the current session, protocol version 1 and while
    /// fewer than `max` other connections are past their HELLO. Otherwise `REJECTED` (zero nonce) and close.
    public mutating func hello(_ id: FilesConnID, _ hello: FilesHello, now: UInt64) -> [FilesAction] {
        guard case .awaitingHello(let deadline)? = conns[id] else {
            return conns[id] == nil ? [] : protocolError(id)
        }
        var reason: String?
        if hello.protocolVersion != ProtocolConstants.protocolVersion {
            reason = "version"
        } else if !listening || hello.sessionID != sessionID {
            reason = "session"
        } else if establishedCount >= maxConnections {
            reason = "capacity"
        }
        if let reason {
            conns[id] = nil
            return [.sendAck(id, .rejected), .close(id, .rejected),
                    .log(.warning, ev: "files_conn", conn: id, fields: "state=rejected reason=\(reason)")]
        }
        let hostNonce = configuration.makeNonce()
        guard hostNonce.count == ProtocolConstants.nonceSize else { return protocolError(id) }
        conns[id] = .awaitingProof(deadline: deadline)
        return [.sendAck(id, FilesHelloAck(status: .ok, hostNonce: hostNonce)),
                .startRecords(id, clientNonce: hello.clientNonce, hostNonce: hostNonce)]
    }

    /// The key derivation after `startRecords` returned nil: the session is gone.
    public mutating func keysUnavailable(_ id: FilesConnID) -> [FilesAction] {
        guard let state = conns.removeValue(forKey: id) else { return [] }
        return [.close(id, .keysUnavailable)] + closeBoundLocal(state, .fileClosed)
    }

    /// An authenticated record arrived. The first one must be a PING (the proof); an idle connection answers PINGs
    /// with nothing (no PONG on file connections); `FILES_DATA` is valid only on a bound connection that has already
    /// sent its first `FILES_DATA` to the tablet (the host always speaks first). Any other known type is a protocol
    /// error. Unknown types never get here (the decoder skips them).
    public mutating func record(_ id: FilesConnID, _ message: Message, now: UInt64) -> [FilesAction] {
        guard let state = conns[id] else { return [] }
        switch (state, message) {
        case (.awaitingProof, .ping):
            provenCount += 1
            conns[id] = .idle(since: provenCount, lastReceive: now)
            var out: [FilesAction] = [.log(.info, ev: "files_conn", conn: id, fields: "state=proven \(countsFields)")]
            out += bindWaiting(now: now)
            return out
        case (.idle(let since, _), .ping):
            conns[id] = .idle(since: since, lastReceive: now)
            return []
        case (.bound, .ping):
            return []
        case (.bound(let local, let sent), .filesData):
            guard sent else { return protocolError(id) }
            return [.dataToLocal(id, local)]
        default:
            return protocolError(id)
        }
    }

    /// The host sent a `FILES_DATA` on a bound connection (the first one unlocks the tablet's replies).
    public mutating func hostSentData(_ id: FilesConnID) {
        if case .bound(let local, _)? = conns[id] { conns[id] = .bound(local, hostSentData: true) }
    }

    /// The decoder or the record layer reported a protocol violation (malformed payload, `FILES_DATA` with size 0).
    public mutating func protocolError(_ id: FilesConnID) -> [FilesAction] {
        end(id, .protocolError, level: .warning)
    }

    /// A record failed authentication or had an invalid length (PROTOCOL.md section 9): no reply, close.
    public mutating func recordAuthFailed(_ id: FilesConnID) -> [FilesAction] {
        end(id, .authFailed, level: .warning)
    }

    /// The transport closed or failed. A bound local connection is closed after its pending bytes.
    public mutating func fileClosed(_ id: FilesConnID) -> [FilesAction] {
        guard let state = conns.removeValue(forKey: id) else { return [] }
        return closeBoundLocal(state, .fileClosed)
    }

    // MARK: Local (Finder) connection events

    /// A connection from Finder reached the loopback proxy: it gets the oldest idle file connection, or waits (at
    /// most 5 s, at most 8 waiting).
    public mutating func localOpened(_ lid: LocalConnID, now: UInt64) -> [FilesAction] {
        guard listening else { return [.closeLocal(lid, .notOpen)] }
        if let fid = oldestIdle() {
            conns[fid] = .bound(lid, hostSentData: false)
            return [.bind(fid, lid), .log(.debug, ev: "files_conn", conn: fid, fields: "state=bound \(countsFields)")]
        }
        guard waiting.count < configuration.maxWaitingLocal else {
            return [.closeLocal(lid, .tooManyWaiting)]
        }
        waiting.append(Waiting(id: lid, deadline: now + configuration.localWaitUs))
        return []
    }

    /// The Finder side closed (or failed). A bound file connection closes with it (1:1, no message), after the
    /// bytes the caller still owes the tablet.
    public mutating func localClosed(_ lid: LocalConnID) -> [FilesAction] {
        if let i = waiting.firstIndex(where: { $0.id == lid }) {
            waiting.remove(at: i)
            return []
        }
        for (fid, state) in conns {
            if case .bound(let l, _) = state, l == lid {
                conns[fid] = nil
                return [.close(fid, .localClosed)]
            }
        }
        return []
    }

    // MARK: Time

    public mutating func tick(now: UInt64) -> [FilesAction] {
        var out: [FilesAction] = []
        for id in conns.keys.sorted(by: { $0.raw < $1.raw }) {
            switch conns[id] {
            case .awaitingHello(let deadline)? where now >= deadline:
                conns[id] = nil
                out += [.close(id, .helloTimeout), .log(.warning, ev: "files_conn", conn: id, fields: "state=timeout reason=hello_timeout")]
            case .awaitingProof(let deadline)? where now >= deadline:
                conns[id] = nil
                out += [.close(id, .proofTimeout), .log(.warning, ev: "files_conn", conn: id, fields: "state=timeout reason=proof_timeout")]
            case .idle(_, let last)? where now >= last + configuration.idleTimeoutUs:
                conns[id] = nil
                out += [.close(id, .idleTimeout), .log(.info, ev: "files_conn", conn: id, fields: "state=closed reason=idle_timeout")]
            default:
                break
            }
        }
        for w in waiting where now >= w.deadline {
            out += [.closeLocal(w.id, .noIdleConnection)]
        }
        waiting.removeAll { now >= $0.deadline }
        return out
    }

    // MARK: Internals

    private var unprovenCount: Int {
        conns.values.reduce(0) {
            switch $1 {
            case .awaitingHello, .awaitingProof: $0 + 1
            default: $0
            }
        }
    }

    /// Connections that are past their HELLO (the ones that count toward `max`).
    private var establishedCount: Int {
        conns.values.reduce(0) {
            switch $1 {
            case .awaitingHello: $0
            default: $0 + 1
            }
        }
    }

    private var countsFields: String {
        let c = counts
        return "total=\(c.total) idle=\(c.idle) bound=\(c.bound) unproven=\(c.unproven) waiting=\(c.waitingLocal)"
    }

    private func oldestIdle() -> FilesConnID? {
        var best: (FilesConnID, UInt64)?
        for (id, state) in conns {
            if case .idle(let since, _) = state, best == nil || since < best!.1 { best = (id, since) }
        }
        return best?.0
    }

    /// A file connection became idle: give it to the oldest waiting local connection.
    private mutating func bindWaiting(now: UInt64) -> [FilesAction] {
        var out: [FilesAction] = []
        while let first = waiting.first, let fid = oldestIdle() {
            waiting.removeFirst()
            guard now < first.deadline else {
                out.append(.closeLocal(first.id, .noIdleConnection))
                continue
            }
            conns[fid] = .bound(first.id, hostSentData: false)
            out += [.bind(fid, first.id), .log(.debug, ev: "files_conn", conn: fid, fields: "state=bound \(countsFields)")]
        }
        return out
    }

    private mutating func end(_ id: FilesConnID, _ reason: FilesCloseReason, level: LogLevel) -> [FilesAction] {
        guard let state = conns.removeValue(forKey: id) else { return [] }
        return [.close(id, reason), .log(level, ev: "files_conn", conn: id, fields: "state=closed reason=\(reason.rawValue)")]
            + closeBoundLocal(state, .fileClosed)
    }

    private func closeBoundLocal(_ state: State, _ reason: FilesCloseReason) -> [FilesAction] {
        if case .bound(let local, _) = state { return [.closeLocal(local, reason)] }
        return []
    }

    private mutating func closeAll(_ reason: FilesCloseReason) -> [FilesAction] {
        var out: [FilesAction] = []
        for id in conns.keys.sorted(by: { $0.raw < $1.raw }) {
            if let state = conns.removeValue(forKey: id) {
                out.append(.close(id, reason))
                out += closeBoundLocal(state, reason)
            }
        }
        for w in waiting { out.append(.closeLocal(w.id, reason)) }
        waiting.removeAll()
        return out
    }
}
