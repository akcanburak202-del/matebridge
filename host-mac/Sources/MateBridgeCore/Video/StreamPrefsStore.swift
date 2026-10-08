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

/// The persisted form of a device's `STREAM_PREFS` (T-049, T-106, T-214, T-237, T-240):
/// `[fps, scale_permille, bitrate_kbps, display_width_px, display_height_px, dynamic_range, chroma]`. Like the wire
/// format the display pair is an optional tail, written only when either is non-zero or the range group follows;
/// `dynamic_range` is written when it or `chroma` is non-zero (decision 0032), `chroma` only when non-zero (decision
/// 0033). So a record without a game display, HDR or sharp chroma keeps its older shape and stays readable by older
/// builds (an older build reads a longer record than it knows as none: the mode default). Records written before T-106
/// are `[fps, scale_permille]` and read back with `bitrate_kbps = 0` (the mode default); 2- and 3-value records read
/// back with display 0x0 (the native display); records without the 6th value read back as SDR, without the 7th as
/// normal chroma.
public enum StreamPrefsStorageCodec {
    public static func encode(_ prefs: StreamPrefs) -> [Int] {
        let p = prefs.normalized
        var v = [Int(p.fps), Int(p.scalePermille), Int(p.bitrateKbps)]
        let rangeGroup = p.dynamicRange != 0 || p.chroma != 0
        if p.displayWidthPx != 0 || p.displayHeightPx != 0 || rangeGroup {
            v += [Int(p.displayWidthPx), Int(p.displayHeightPx)]
        }
        if rangeGroup { v.append(Int(p.dynamicRange)) }
        if p.chroma != 0 { v.append(Int(p.chroma)) }
        return v
    }

    /// nil for anything that is not 2, 3, 5, 6 or 7 in-range integers (an unknown `dynamic_range` or `chroma` reads
    /// back as 0).
    public static func decode(_ values: [Int]) -> StreamPrefs? {
        guard [2, 3, 5, 6, 7].contains(values.count) else { return nil }
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
        let u8 = 0...Int(UInt8.max)
        if values.count >= 6 {
            guard u8.contains(values[5]) else { return nil }
            prefs.dynamicRange = UInt8(values[5])
        }
        if values.count == 7 {
            guard u8.contains(values[6]) else { return nil }
            prefs.chroma = UInt8(values[6])
        }
        return prefs.normalized
    }
}

extension VideoSettings {
    /// Settings a session starts with: `defaults` (HELLO + experiment knobs) with the device's stored prefs on top
    /// (a stored game display included, unless `allowGameDisplay` is false after `game_display_failed`).
    /// An unknown device (nil) gets `defaults` unchanged.
    public static func initialSettings(defaults: VideoSettings, stored: StreamPrefs?,
                                       allowGameDisplay: Bool = true, allowHDR: Bool = true) -> VideoSettings {
        guard let stored else { return defaults }
        return defaults.applying(stored, allowGameDisplay: allowGameDisplay, allowHDR: allowHDR)
    }
}

extension DeviceID {
    /// First 4 bytes in hex: enough to tell devices apart in a log, not the whole identifier.
    public var shortHex: String { bytes.prefix(4).map { String(format: "%02x", $0) }.joined() }
}
