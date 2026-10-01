import Foundation

/// Last applied `STREAM_PREFS` per tablet (T-049), so a reconnect starts in the mode the user chose and the tablet's
/// first `STREAM_PREFS` usually changes nothing (no display recreate, no extra video reconnect).
public protocol StreamPrefsStoring: Sendable {
    func load(device: DeviceID) -> StreamPrefs?
    func save(_ prefs: StreamPrefs, device: DeviceID)
}

public final class InMemoryStreamPrefsStore: StreamPrefsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DeviceID: StreamPrefs] = [:]
    public init() {}
    public func load(device: DeviceID) -> StreamPrefs? { lock.withLock { values[device] } }
    public func save(_ prefs: StreamPrefs, device: DeviceID) { lock.withLock { values[device] = prefs.normalized } }
}

/// The persisted form of a device's `STREAM_PREFS` (T-049, T-106): `[fps, scale_permille, bitrate_kbps]`. Records
/// written before T-106 are `[fps, scale_permille]` and read back with `bitrate_kbps = 0` (the mode default).
public enum StreamPrefsStorageCodec {
    public static func encode(_ prefs: StreamPrefs) -> [Int] {
        let p = prefs.normalized
        return [Int(p.fps), Int(p.scalePermille), Int(p.bitrateKbps)]
    }

    /// nil for anything that is not 2 or 3 in-range integers.
    public static func decode(_ values: [Int]) -> StreamPrefs? {
        guard values.count == 2 || values.count == 3 else { return nil }
        let u16 = 0...Int(UInt16.max)
        guard u16.contains(values[0]), u16.contains(values[1]) else { return nil }
        var bitrate: UInt32 = 0
        if values.count == 3 {
            guard (0...Int(UInt32.max)).contains(values[2]) else { return nil }
            bitrate = UInt32(values[2])
        }
        return StreamPrefs(fps: UInt16(values[0]), scalePermille: UInt16(values[1]), bitrateKbps: bitrate).normalized
    }
}

extension VideoSettings {
    /// Settings a session starts with: `defaults` (HELLO + experiment knobs) with the device's stored prefs on top.
    /// An unknown device (nil) gets `defaults` unchanged.
    public static func initialSettings(defaults: VideoSettings, stored: StreamPrefs?,
                                       defaultRefreshHz: Int) -> VideoSettings {
        guard let stored else { return defaults }
        return defaults.applying(stored, defaultRefreshHz: defaultRefreshHz)
    }
}

extension DeviceID {
    /// First 4 bytes in hex: enough to tell devices apart in a log, not the whole identifier.
    public var shortHex: String { bytes.prefix(4).map { String(format: "%02x", $0) }.joined() }
}
