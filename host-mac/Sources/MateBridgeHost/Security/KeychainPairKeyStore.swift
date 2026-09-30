import Foundation
import MateBridgeCore
import Security

/// The only type that touches the macOS Keychain for pair keys (PROTOCOL.md 9, decision 0010).
/// One generic-password item per tablet: service `dev.matebridge.host.pair`, account = `device_id` as 32 hex chars,
/// value = the 32-byte `pair_key`. Keys are never logged; failures carry only the OSStatus.
public struct KeychainPairKeyStore: PairKeyStore {
    public static let defaultService = "dev.matebridge.host.pair"

    public struct KeychainError: Error, CustomStringConvertible, Sendable {
        public let status: OSStatus
        public var description: String { "keychain status \(status)" }
    }

    private let service: String

    public init(service: String = KeychainPairKeyStore.defaultService) {
        self.service = service
    }

    private func query(_ device: DeviceID?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let device { q[kSecAttrAccount as String] = ApprovedDeviceStore.hex(device) }
        return q
    }

    public func key(for device: DeviceID) -> SecretBytes? {
        var q = query(device)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              data.count == SessionKeySchedule.keySize else { return nil }
        return SecretBytes([UInt8](data))
    }

    public func save(_ key: SecretBytes, for device: DeviceID) throws {
        let data = Data(key.bytes)
        let update = SecItemUpdate(query(device) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = query(device)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "MateBridge pair key"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func remove(_ device: DeviceID) throws {
        let status = SecItemDelete(query(device) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func removeAll() throws {
        // Enumerate and delete per account: a bulk delete by service alone is not reliable on the file-based keychain.
        var q = query(nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let found = SecItemCopyMatching(q as CFDictionary, &result)
        guard found == errSecSuccess || found == errSecItemNotFound else { throw KeychainError(status: found) }
        var firstFailure: OSStatus?
        for item in (result as? [[String: Any]]) ?? [] {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            var d = query(nil)
            d[kSecAttrAccount as String] = account
            let status = SecItemDelete(d as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { firstFailure = firstFailure ?? status }
        }
        if let firstFailure { throw KeychainError(status: firstFailure) }
    }
}
