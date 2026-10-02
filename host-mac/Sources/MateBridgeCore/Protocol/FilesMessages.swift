// Tablet files message, docs/PROTOCOL.md 0x09 (decision 0015). The token is an HTTP password: never log it.

/// `FILES_INFO.state`. Unknown values decode fine and count as OFF (PROTOCOL.md 0x09).
public struct FilesState: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let off = FilesState(rawValue: 0)
    public static let ready = FilesState(rawValue: 1)
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
