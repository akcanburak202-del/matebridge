// Tablet files messages, docs/PROTOCOL.md 0x09, 0x0A and 0x50-0x52 (decisions 0015, 0035). The token is an HTTP
// password and `FILES_DATA.data` is file/HTTP content: never log either.

/// `FILES_INFO.state`. Unknown values decode fine and count as OFF (PROTOCOL.md 0x09).
public struct FilesState: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let off = FilesState(rawValue: 0)
    public static let ready = FilesState(rawValue: 1)
    /// Wi-Fi only (decision 0035, `HELLO` bit12): sharing is allowed, the server is off and waits for `FILES_NET(OPEN)`.
    /// A host that does not know the value counts it as OFF, like any unknown state.
    public static let standby = FilesState(rawValue: 2)
}

/// `FILES_INFO` (C->H, 0x09): the state of the tablet's WebDAV server, reachable only on the tablet's
/// `127.0.0.1:port` (so only through `adb forward`). `token` is the password for user `matebridge`.
/// `description` hides the token so the value can never leak into a log by accident.
public struct FilesInfo: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let userName = "matebridge"

    public var state: FilesState
    public var port: UInt16
    public var token: String

    public init(state: FilesState, port: UInt16, token: String) {
        self.state = state
        self.port = port
        self.token = token
    }

    public static let off = FilesInfo(state: .off, port: 0, token: "")
    /// STANDBY: `port` 0 and an empty token (PROTOCOL.md 0x09).
    public static let standby = FilesInfo(state: .standby, port: 0, token: "")

    /// STANDBY, the Wi-Fi "ask me to open" state. Never true for READY or OFF.
    public var isStandby: Bool { state == .standby }

    /// READY with a usable port and token. Anything else (unknown state included) is treated as OFF.
    public var isReady: Bool { state == .ready && port != 0 && !token.isEmpty }

    public var description: String { "FilesInfo(state: \(state.rawValue), port: \(port), token: <\(token.utf8.count) bytes>)" }
    public var debugDescription: String { description }

    func write(_ w: inout ByteWriter) {
        w.u8(state.rawValue)
        w.u16(port)
        w.str8(token)
    }

    static func read(_ r: inout ByteReader) throws -> FilesInfo {
        FilesInfo(state: FilesState(rawValue: try r.u8()), port: try r.u16(), token: try r.str8())
    }
}

/// `FILES_NET.state` (PROTOCOL.md 0x0A). Unknown values decode fine and count as CLOSE.
public struct FilesNetState: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let close = FilesNetState(rawValue: 0)
    public static let open = FilesNetState(rawValue: 1)
}

/// `FILES_NET` (H->C, 0x0A, only with `HELLO` bit12): open or close the tablet's files over Wi-Fi (decision 0035).
public struct FilesNet: Equatable, Sendable {
    /// What the host proposes for the pool of idle file connections and the total (PROTOCOL.md 0x0A).
    public static let recommendedPool: UInt8 = 2
    public static let recommendedMax: UInt8 = 12

    public var state: FilesNetState
    /// OPEN: TCP port of the host's file listener. CLOSE: 0.
    public var port: UInt16
    /// OPEN: idle proven file connections the client keeps ready. CLOSE: 0.
    public var pool: UInt8
    /// OPEN: upper bound of all file connections. CLOSE: 0.
    public var max: UInt8

    public init(state: FilesNetState, port: UInt16, pool: UInt8, max: UInt8) {
        self.state = state
        self.port = port
        self.pool = pool
        self.max = max
    }

    public static func open(port: UInt16, pool: UInt8 = recommendedPool, max: UInt8 = recommendedMax) -> FilesNet {
        FilesNet(state: .open, port: port, pool: pool, max: max)
    }

    public static let close = FilesNet(state: .close, port: 0, pool: 0, max: 0)

    /// Anything but OPEN (unknown values included) is CLOSE.
    public var isOpen: Bool { state == .open }

    func write(_ w: inout ByteWriter) {
        w.u8(state.rawValue)
        w.u16(port)
        w.u8(pool)
        w.u8(max)
    }

    static func read(_ r: inout ByteReader) throws -> FilesNet {
        FilesNet(state: FilesNetState(rawValue: try r.u8()), port: try r.u16(), pool: try r.u8(), max: try r.u8())
    }
}

/// `FILES_HELLO` (C->H, 0x50, plain): the first message of a file connection (PROTOCOL.md section 4).
public struct FilesHello: Equatable, Sendable {
    public var protocolVersion: UInt16
    public var sessionID: UInt32
    /// Fresh random value per file connection; the connection's keys derive from it and the host's nonce (section 9).
    public var clientNonce: [UInt8]

    public init(protocolVersion: UInt16 = ProtocolConstants.protocolVersion, sessionID: UInt32,
                clientNonce: [UInt8]) {
        precondition(clientNonce.count == ProtocolConstants.nonceSize)
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.clientNonce = clientNonce
    }

    func write(_ w: inout ByteWriter) {
        w.u16(protocolVersion)
        w.u32(sessionID)
        w.raw(clientNonce)
    }

    /// A payload shorter than 22 bytes is a protocol error (`payloadTooShort`).
    static func read(_ r: inout ByteReader) throws -> FilesHello {
        FilesHello(protocolVersion: try r.u16(), sessionID: try r.u32(), clientNonce: try r.raw(ProtocolConstants.nonceSize))
    }
}

/// `FILES_HELLO_ACK.status`. Unknown values decode fine and count as REJECTED.
public struct FilesHelloStatus: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let ok = FilesHelloStatus(rawValue: 0)
    public static let rejected = FilesHelloStatus(rawValue: 1)
}

/// `FILES_HELLO_ACK` (H->C, 0x51, plain).
public struct FilesHelloAck: Equatable, Sendable {
    public var status: FilesHelloStatus
    /// OK: fresh random value per file connection. REJECTED: all zero.
    public var hostNonce: [UInt8]

    public init(status: FilesHelloStatus, hostNonce: [UInt8]) {
        precondition(hostNonce.count == ProtocolConstants.nonceSize)
        self.status = status
        self.hostNonce = hostNonce
    }

    public static let rejected = FilesHelloAck(status: .rejected,
                                               hostNonce: [UInt8](repeating: 0, count: ProtocolConstants.nonceSize))

    /// Only OK is OK: any other status, unknown values included, is REJECTED.
    public var isOK: Bool { status == .ok }

    func write(_ w: inout ByteWriter) {
        w.u8(status.rawValue)
        w.raw(hostNonce)
    }

    static func read(_ r: inout ByteReader) throws -> FilesHelloAck {
        FilesHelloAck(status: FilesHelloStatus(rawValue: try r.u8()), hostNonce: try r.raw(ProtocolConstants.nonceSize))
    }
}

/// `FILES_DATA` (both ways, 0x52): opaque HTTP bytes of the paired local connection. `size` is 1...65 534: an empty
/// record is a protocol error. The content is never logged.
public struct FilesData: Equatable, Sendable {
    public var data: [UInt8]

    public init(data: [UInt8]) { self.data = data }

    func write(_ w: inout ByteWriter) {
        w.u16(UInt16(truncatingIfNeeded: data.count))
        w.raw(data)
    }

    /// `size = 0` is `invalidField("size")`; a payload shorter than `2 + size` is `payloadTooShort`. Extra bytes
    /// after `data` are ignored (PROTOCOL.md section 2).
    static func read(_ r: inout ByteReader) throws -> FilesData {
        let size = Int(try r.u16())
        guard size >= 1 else { throw ProtocolError.invalidField("size") }
        return FilesData(data: try r.raw(size))
    }
}
