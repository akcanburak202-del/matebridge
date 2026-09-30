import Foundation

/// The host's persistent `host_id` (PROTOCOL.md 9): 16 random bytes generated once and stored next to the approved
/// device list. Not secret (it travels in HELLO_ACK), but it must be stable: tablets key their pair key by it.
public struct HostIdentityStore: Sendable {
    public enum Identity: Equatable, Sendable {
        /// Read from disk.
        case loaded([UInt8])
        /// Newly generated (first run, or the file was missing or damaged) and written to disk. Every pair key and
        /// approval made under a previous id is now meaningless: the caller drops them so every device re-pairs.
        case created([UInt8])
        /// Newly generated but the write failed. Valid for this run only: the host must not answer PAIRED.
        case unpersisted([UInt8])

        public var id: [UInt8] {
            switch self {
            case .loaded(let id), .created(let id), .unpersisted(let id): id
            }
        }
    }

    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("host-id")
    }

    public func resolve() -> Identity {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8),
           let id = Self.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .loaded(id)
        }
        let id = (0..<ProtocolConstants.deviceIDSize).map { _ in UInt8.random(in: 0...255) }
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        let hex = id.map { String(format: "%02x", $0) }.joined()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard fm.createFile(atPath: fileURL.path, contents: Data(hex.utf8), attributes: [.posixPermissions: 0o600]),
                  let back = try? String(contentsOf: fileURL, encoding: .utf8), Self.parse(back) == id else {
                return .unpersisted(id)
            }
        } catch {
            return .unpersisted(id)
        }
        return .created(id)
    }

    /// Convenience for tests: the id only.
    public func loadOrCreate() -> [UInt8] { resolve().id }

    static func parse(_ hex: String) -> [UInt8]? {
        ApprovedDeviceStore.deviceID(hex: hex)?.bytes
    }
}
