import Foundation

/// One line of `adb devices`.
public struct AdbDevice: Equatable, Sendable {
    public let serial: String
    /// `device`, `unauthorized`, `offline`, ...
    public let state: String
    public init(serial: String, state: String) {
        self.serial = serial
        self.state = state
    }
    public var isReady: Bool { state == "device" }
}

/// Parsers for adb's text output. Pure so they are unit-testable; adb also prints `* daemon ...` banners
/// on stdout when it starts its server, which must never be mistaken for data.
public enum AdbOutput {
    public static func parseDevices(_ text: String) -> [AdbDevice] {
        var result: [AdbDevice] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("*") || line.hasPrefix("List of devices") { continue }
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2 else { continue }
            result.append(AdbDevice(serial: String(parts[0]), state: String(parts[1])))
        }
        return result
    }

    /// Ports forwarded 1:1 (`tcp:N` to `tcp:N`) in `adb reverse --list`. Lines look like
    /// `host-19 tcp:47001 tcp:47001` (older adb omits the first column).
    public static func parseReverseList(_ text: String) -> Set<UInt16> {
        var ports: Set<UInt16> = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let remote = parts[parts.count - 2]
            let local = parts[parts.count - 1]
            guard remote == local, remote.hasPrefix("tcp:"), let port = UInt16(remote.dropFirst(4)) else { continue }
            ports.insert(port)
        }
        return ports
    }

    /// The port printed by `adb forward tcp:0 tcp:N` (adb allocates the local port). adb may print `* daemon ...`
    /// banners first, so the last line that is only a valid port number wins.
    public static func parseForwardPort(_ text: String) -> UInt16? {
        for raw in text.split(whereSeparator: \.isNewline).reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let port = UInt16(line), port != 0 { return port }
        }
        return nil
    }

    /// Local TCP ports forwarded for `serial` in `adb forward --list` (lines `<serial> tcp:<local> <remote>`).
    public static func parseForwardList(_ text: String, serial: String) -> Set<UInt16> {
        var ports: Set<UInt16> = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 3, parts[0] == serial, parts[1].hasPrefix("tcp:"),
                  let port = UInt16(parts[1].dropFirst(4)) else { continue }
            ports.insert(port)
        }
        return ports
    }

    /// The device to tunnel to: the first ready one, physical devices (USB) before emulators.
    public static func selectDevice(_ devices: [AdbDevice]) -> AdbDevice? {
        let ready = devices.filter(\.isReady)
        return ready.first { !$0.serial.hasPrefix("emulator-") } ?? ready.first
    }
}

/// Where to look for the adb binary, in priority order: `ANDROID_HOME`, the default Android Studio SDK location,
/// `PATH`, then common Homebrew locations (a login item starts with a minimal `PATH`).
public enum AdbLocator {
    public static func candidates(androidHome: String?, androidSdkRoot: String? = nil, home: String,
                                  path: String?) -> [String] {
        var result: [String] = []
        func add(_ p: String) { if !result.contains(p) { result.append(p) } }
        for root in [androidHome, androidSdkRoot] {
            if let root, !root.isEmpty { add(root + "/platform-tools/adb") }
        }
        add(home + "/Library/Android/sdk/platform-tools/adb")
        for dir in (path ?? "").split(separator: ":") where !dir.isEmpty { add(String(dir) + "/adb") }
        add("/opt/homebrew/bin/adb")
        add("/usr/local/bin/adb")
        return result
    }
}
