import Foundation

/// The host's persistent `host_id` (PROTOCOL.md 9): 16 random bytes generated once and stored next to the approved
/// device list. Not secret (it travels in HELLO_ACK), but it must be stable so tablets find their pair key again.
public struct HostIdentityStore: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("host-id")
    }

    /// Stored id, or a new one written to disk. If the file cannot be written the id is still returned
    /// (valid for this run; tablets re-pair next launch).
    public func loadOrCreate() -> [UInt8] {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8),
           let id = Self.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id
        }
        let id = (0..<ProtocolConstants.deviceIDSize).map { _ in UInt8.random(in: 0...255) }
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let hex = id.map { String(format: "%02x", $0) }.joined()
        _ = fm.createFile(atPath: fileURL.path, contents: Data(hex.utf8), attributes: [.posixPermissions: 0o600])
        return id
    }

    static func parse(_ hex: String) -> [UInt8]? {
        ApprovedDeviceStore.deviceID(hex: hex)?.bytes
    }
}
