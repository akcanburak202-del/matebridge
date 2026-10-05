import Foundation
import MateBridgeCore

/// `StreamPrefsStoring` in UserDefaults:
/// `{device hex: [fps, scale_permille, bitrate_kbps(, display_w, display_h(, dynamic_range))]}`
/// (`StreamPrefsStorageCodec`; the game display pair of T-214 only when set or followed by `dynamic_range`, which is
/// written only for HDR10, T-237; pre-T-106 entries without the bitrate still load). The device id is not secret; at most `maxDevices` entries are kept.
final class UserDefaultsStreamPrefsStore: StreamPrefsStoring, @unchecked Sendable {
    private static let key = "streamPrefsByDevice"
    private static let maxDevices = 16
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private static func hex(_ d: DeviceID) -> String { d.bytes.map { String(format: "%02x", $0) }.joined() }

    func load(device: DeviceID) -> StreamPrefs? {
        lock.withLock {
            guard let all = defaults.dictionary(forKey: Self.key) as? [String: [Int]],
                  let v = all[Self.hex(device)] else { return nil }
            return StreamPrefsStorageCodec.decode(v)
        }
    }

    func save(_ prefs: StreamPrefs, device: DeviceID) {
        lock.withLock {
            var all = (defaults.dictionary(forKey: Self.key) as? [String: [Int]]) ?? [:]
            let me = Self.hex(device)
            all[me] = StreamPrefsStorageCodec.encode(prefs)
            while all.count > Self.maxDevices, let drop = all.keys.first(where: { $0 != me }) {
                all.removeValue(forKey: drop)
            }
            defaults.set(all, forKey: Self.key)
        }
    }
}
