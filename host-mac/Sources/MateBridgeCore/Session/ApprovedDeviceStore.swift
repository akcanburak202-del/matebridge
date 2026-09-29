import Foundation

/// Persistent list of approved tablets: `device_id` and display name only.
/// Stored as JSON in `<directory>/approved-devices.json`, owner-readable only.
public struct ApprovedDeviceStore: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var deviceID: String  // 32 hex chars
        public var name: String
    }

    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("approved-devices.json")
    }

    /// `~/Library/Application Support/MateBridge/`
    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MateBridge", isDirectory: true)
    }

    public static func hex(_ id: DeviceID) -> String { id.bytes.map { String(format: "%02x", $0) }.joined() }

    static func deviceID(hex: String) -> DeviceID? {
        guard hex.utf8.count == ProtocolConstants.deviceIDSize * 2 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let b = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(b)
            index = next
        }
        return DeviceID(bytes: bytes)
    }

    /// A missing or unreadable file yields an empty list (fail closed: nobody is approved).
    public func load() -> [DeviceID: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        var result: [DeviceID: String] = [:]
        for e in entries { if let id = Self.deviceID(hex: e.deviceID) { result[id] = e.name } }
        return result
    }

    public func save(_ devices: [DeviceID: String]) throws {
        let entries = devices.map { Entry(deviceID: Self.hex($0.key), name: $0.value) }
            .sorted { $0.deviceID < $1.deviceID }
        let data = try JSONEncoder().encode(entries)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
