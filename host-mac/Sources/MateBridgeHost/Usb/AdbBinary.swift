import Foundation
import MateBridgeCore

/// Shared adb settings for the USB tunnel guard and the tablet files forward: where the binary is, the server
/// port, the per-call deadline and the environment (no mDNS bridge, it aborts on some networks).
enum AdbBinary {
    static let serverPort: UInt16 = 5037
    static let timeout: TimeInterval = 4
    static let environment = ["ADB_MDNS": "0", "ADB_MDNS_AUTO_CONNECT": "0"]

    static func locate() -> String? {
        let env = ProcessInfo.processInfo.environment
        let candidates = AdbLocator.candidates(androidHome: env["ANDROID_HOME"], androidSdkRoot: env["ANDROID_SDK_ROOT"],
                                               home: NSHomeDirectory(), path: env["PATH"])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The adb server answers on loopback. Never starts one (that is the USB guard's job).
    static var serverUp: Bool { LoopbackProbe.isListening(port: serverPort) }
}
