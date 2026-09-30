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
