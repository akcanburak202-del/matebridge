import Foundation
import MateBridgeCore
import os

/// Session-component logger: docs/LOGGING.md line format into os.Logger (subsystem `dev.matebridge.host`).
/// File logging (`~/Library/Logs/MateBridge/host.log`) is not part of this task.
/// Callers must never pass device names, key characters or text in `fields`.
struct SessionLogger: Sendable {
    private let logger = Logger(subsystem: "dev.matebridge.host", category: "session")

    static func monoMs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

    func log(_ level: LogLevel, _ event: String, sessionID: UInt32, generation: UInt16, fields: String = "") {
        let line = LogFormat.line(monoMs: Self.monoMs(), level: level, component: "session", sessionID: sessionID,
                                  generation: generation, event: event, fields: fields)
        switch level {
        case .error: logger.error("\(line, privacy: .public)")
        case .warning: logger.warning("\(line, privacy: .public)")
        case .info: logger.info("\(line, privacy: .public)")
        case .debug: logger.debug("\(line, privacy: .public)")
        }
    }
}
