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

/// The persisted form of a device's `STREAM_PREFS` (T-049, T-106, T-214, T-237):
/// `[fps, scale_permille, bitrate_kbps, display_width_px, display_height_px, dynamic_range]`. Like the wire format
/// the display pair is an optional tail, written only when either is non-zero or `dynamic_range` follows, and
/// `dynamic_range` is written only when non-zero (decision 0032), so a record without a game display or HDR stays
/// readable by older builds (an older build reads a 6-value record as none: the mode default). Records written before
/// T-106 are `[fps, scale_permille]` and read back with `bitrate_kbps = 0` (the mode default); 2- and 3-value records
/// read back with display 0x0 (the native display); records without the 6th value read back as SDR.
public enum StreamPrefsStorageCodec {
    public static func encode(_ prefs: StreamPrefs) -> [Int] {
        let p = prefs.normalized
        var v = [Int(p.fps), Int(p.scalePermille), Int(p.bitrateKbps)]
        if p.displayWidthPx != 0 || p.displayHeightPx != 0 || p.dynamicRange != 0 {
            v += [Int(p.displayWidthPx), Int(p.displayHeightPx)]
        }
        if p.dynamicRange != 0 { v.append(Int(p.dynamicRange)) }
        return v
    }

    /// nil for anything that is not 2, 3, 5 or 6 in-range integers (an unknown `dynamic_range` reads back as 0).
    public static func decode(_ values: [Int]) -> StreamPrefs? {
        guard [2, 3, 5, 6].contains(values.count) else { return nil }
        let u16 = 0...Int(UInt16.max)
        guard u16.contains(values[0]), u16.contains(values[1]) else { return nil }
        var prefs = StreamPrefs(fps: UInt16(values[0]), scalePermille: UInt16(values[1]))
        if values.count >= 3 {
            guard (0...Int(UInt32.max)).contains(values[2]) else { return nil }
            prefs.bitrateKbps = UInt32(values[2])
        }
        if values.count >= 5 {
            guard u16.contains(values[3]), u16.contains(values[4]) else { return nil }
            prefs.displayWidthPx = UInt16(values[3])
            prefs.displayHeightPx = UInt16(values[4])
        }
        if values.count == 6 {
            guard (0...Int(UInt8.max)).contains(values[5]) else { return nil }
            prefs.dynamicRange = UInt8(values[5])
        }
        return prefs.normalized
    }
}

extension VideoSettings {
    /// Settings a session starts with: `defaults` (HELLO + experiment knobs) with the device's stored prefs on top
    /// (a stored game display included, unless `allowGameDisplay` is false after `game_display_failed`).
    /// An unknown device (nil) gets `defaults` unchanged.
    public static func initialSettings(defaults: VideoSettings, stored: StreamPrefs?, defaultRefreshHz: Int,
                                       allowGameDisplay: Bool = true, allowHDR: Bool = true) -> VideoSettings {
        guard let stored else { return defaults }
        return defaults.applying(stored, defaultRefreshHz: defaultRefreshHz, allowGameDisplay: allowGameDisplay,
                                 allowHDR: allowHDR)
    }
}

extension DeviceID {
    /// First 4 bytes in hex: enough to tell devices apart in a log, not the whole identifier.
    public var shortHex: String { bytes.prefix(4).map { String(format: "%02x", $0) }.joined() }
}
