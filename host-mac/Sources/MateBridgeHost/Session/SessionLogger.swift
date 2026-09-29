import Foundation
import MateBridgeCore
import os

/// Logger for the host components: docs/LOGGING.md line format into os.Logger (subsystem `dev.matebridge.host`)
/// and into the rotating `~/Library/Logs/MateBridge/host.log`.
/// Callers must never pass device names, key characters or text in `fields`.
struct SessionLogger: Sendable {
    /// Shared by every `SessionLogger`: one file, one lock.
    static let file = RotatingLogFile()

    private let logger: Logger
    private let component: String

    init(component: String = "session") {
        self.component = component
        self.logger = Logger(subsystem: "dev.matebridge.host", category: component)
    }

    static func monoMs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

    func log(_ level: LogLevel, _ event: String, sessionID: UInt32, generation: UInt16, fields: String = "") {
        let line = LogFormat.line(monoMs: Self.monoMs(), level: level, component: component, sessionID: sessionID,
                                  generation: generation, event: event, fields: fields)
        switch level {
        case .error: logger.error("\(line, privacy: .public)")
        case .warning: logger.warning("\(line, privacy: .public)")
        case .info: logger.info("\(line, privacy: .public)")
        case .debug: logger.debug("\(line, privacy: .public)")
        }
        if level != .debug { Self.file.append(line) }
    }
}
