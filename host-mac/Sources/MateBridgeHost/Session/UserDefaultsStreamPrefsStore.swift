import Foundation
import MateBridgeCore

/// `StreamPrefsStoring` in UserDefaults: `{device hex: [fps, scale_permille]}`. The device id is not secret; at most
/// `maxDevices` entries are kept.
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
                  let v = all[Self.hex(device)], v.count == 2,
                  (0...Int(UInt16.max)).contains(v[0]), (0...Int(UInt16.max)).contains(v[1]) else { return nil }
            return StreamPrefs(fps: UInt16(v[0]), scalePermille: UInt16(v[1])).normalized
        }
    }

    func save(_ prefs: StreamPrefs, device: DeviceID) {
        lock.withLock {
            var all = (defaults.dictionary(forKey: Self.key) as? [String: [Int]]) ?? [:]
            let p = prefs.normalized
            let me = Self.hex(device)
            all[me] = [Int(p.fps), Int(p.scalePermille)]
            while all.count > Self.maxDevices, let drop = all.keys.first(where: { $0 != me }) {
                all.removeValue(forKey: drop)
            }
            defaults.set(all, forKey: Self.key)
        }
    }
}
