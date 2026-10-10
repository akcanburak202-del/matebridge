// Value types for every message in docs/PROTOCOL.md section 4.
// Reserved fields are written as 0 and ignored on decode. Bytes beyond the known layout are ignored.

// MARK: - Enums and flag sets

/// Enum whose unknown values are tolerated (PROTOCOL.md defines no error for them).
public protocol OpenCode: RawRepresentable, Equatable, Sendable where RawValue == UInt8 {
    init(rawValue: UInt8)
}

public struct ByeReason: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let normal = ByeReason(rawValue: 0)
    public static let protocolError = ByeReason(rawValue: 1)
    public static let rejected = ByeReason(rawValue: 2)
    public static let timeout = ByeReason(rawValue: 3)
    public static let shuttingDown = ByeReason(rawValue: 4)
    public static let superseded = ByeReason(rawValue: 5)
    /// The Mac is going to sleep (T-132): the client does not reconnect or wake it on its own.
    public static let hostSleep = ByeReason(rawValue: 6)
}

public struct ReleaseReason: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let user = ReleaseReason(rawValue: 0)
    public static let background = ReleaseReason(rawValue: 1)
    public static let focusLost = ReleaseReason(rawValue: 2)
    public static let deviceDetached = ReleaseReason(rawValue: 3)
}

public struct KeyframeReason: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let startup = KeyframeReason(rawValue: 0)
    public static let decodeError = KeyframeReason(rawValue: 1)
    public static let framesDropped = KeyframeReason(rawValue: 2)
}

/// Unknown gestures are ignored by the host, so they decode successfully.
/// `KEYFRAME_REQUEST.view` (decision 0034): which stream of a packed full colour pair needs the keyframe. An absent
/// field (`nil` in `Message.keyframeRequest`) and every unknown value mean both streams.
public enum KeyframeView: UInt8, Equatable, Sendable {
    case main = 0
    case auxiliary = 1
    case both = 2

    /// A wire value: unknown values are `both`.
    public init(wire: UInt8) { self = KeyframeView(rawValue: wire) ?? .both }

    public var wantsMain: Bool { self != .auxiliary }
    public var wantsAuxiliary: Bool { self != .main }

    /// Log value: `main` / `aux` / `both`.
    public var logName: String {
        switch self {
        case .main: return "main"
        case .auxiliary: return "aux"
        case .both: return "both"
        }
    }

    /// The union of two requests: asking for the main and the auxiliary stream separately is asking for both.
    public func merged(with other: KeyframeView) -> KeyframeView {
        let main = wantsMain || other.wantsMain, aux = wantsAuxiliary || other.wantsAuxiliary
        return main && aux ? .both : (main ? .main : .auxiliary)
    }
}

public struct PenGestureKind: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let doubleTap = PenGestureKind(rawValue: 1)
}

public enum HelloStatus: UInt8, Sendable {
    case accepted = 0, pendingApproval = 1, rejected = 2, versionMismatch = 3, busy = 4
}

/// HELLO_ACK.key_mode (PROTOCOL.md 4, 9). An unknown value is a protocol error.
public enum KeyMode: UInt8, Sendable {
    /// Terminal answer (VERSION_MISMATCH, BUSY, a first-answer REJECTED) and the second, encrypted HELLO_ACK: no key exchange.
    case none = 0
    /// Known device with a pair key: `ikm = pair_key || ecdh`.
    case paired = 1
    /// New pairing: `ikm = ecdh`, both sides show the same code.
    case pairing = 2
}

public enum Codec: UInt8, Sendable {
    case h264 = 1, hevc = 2
}

public enum PenTool: UInt8, Sendable {
    case pen = 0, eraser = 1
}

public enum KeyAction: UInt8, Sendable {
    case up = 0, down = 1
}

public enum PointerSource: UInt8, Sendable {
    case touch = 0, mouse = 1
}

public enum ScrollPhase: UInt8, Sendable {
    case none = 0, began = 1, changed = 2, ended = 3, cancelled = 4
}

public struct Capabilities: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let pen = Capabilities(rawValue: 1 << 0)
    public static let penHover = Capabilities(rawValue: 1 << 1)
    public static let penTilt = Capabilities(rawValue: 1 << 2)
    public static let keyboard = Capabilities(rawValue: 1 << 3)
    public static let touchpad = Capabilities(rawValue: 1 << 4)
    public static let touch = Capabilities(rawValue: 1 << 5)
    public static let decodeH264 = Capabilities(rawValue: 1 << 6)
    public static let decodeHEVC = Capabilities(rawValue: 1 << 7)
    /// The client handles the audio messages (0x30-0x32) and plays PCM s16le 48 kHz stereo.
    public static let audioPCM = Capabilities(rawValue: 1 << 8)
    /// The client can open its settings panel while streaming and handles `SETTINGS_OPEN` (decision 0013).
    public static let settingsPanel = Capabilities(rawValue: 1 << 9)
    /// The client can serve its files over WebDAV and sends `FILES_INFO` (decision 0015).
    public static let files = Capabilities(rawValue: 1 << 10)
    /// The client handles `chroma_layout = 1` (two 4:2:0 streams, `VIDEO_FRAME.view`) and passed its capability test
    /// (decision 0034).
    public static let fullChroma = Capabilities(rawValue: 1 << 11)
    /// The client handles `FILES_INFO(STANDBY)`, `FILES_NET` and the file connections of Wi-Fi tablet files
    /// (decision 0035).
    public static let filesNet = Capabilities(rawValue: 1 << 12)
    /// The client can draw the cursor itself: it sends `CURSOR_PREFS` and handles `CURSOR_SHAPE` / `CURSOR_STATE`
    /// (decision 0036).
    public static let localCursor = Capabilities(rawValue: 1 << 13)
    /// The client decodes `AUDIO_CONFIG.format = 2` (AAC-LC 48 kHz stereo) and writes `AUDIO_PREFS.codec` (decision 0038).
    public static let audioAAC = Capabilities(rawValue: 1 << 14)
}

public struct PenFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let inRange = PenFlags(rawValue: 1 << 0)
    public static let contact = PenFlags(rawValue: 1 << 1)
    public static let button = PenFlags(rawValue: 1 << 2)
    public static let strokeStart = PenFlags(rawValue: 1 << 3)

    /// PROTOCOL.md 4 PEN: `CONTACT` without `IN_RANGE` is treated as `flags = 0`.
    public var normalized: PenFlags {
        contains(.contact) && !contains(.inRange) ? [] : self
    }
}

public struct PointerButtons: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left = PointerButtons(rawValue: 1 << 0)
    public static let right = PointerButtons(rawValue: 1 << 1)
    public static let middle = PointerButtons(rawValue: 1 << 2)
    public static let back = PointerButtons(rawValue: 1 << 3)
    public static let forward = PointerButtons(rawValue: 1 << 4)
}

public struct VideoFrameFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let keyframe = VideoFrameFlags(rawValue: 1 << 0)
    public static let codecConfig = VideoFrameFlags(rawValue: 1 << 1)
}

/// 16 random bytes generated at install time.
public struct DeviceID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init?(bytes: [UInt8]) {
        guard bytes.count == ProtocolConstants.deviceIDSize else { return nil }
        self.bytes = bytes
    }
}

// MARK: - Session messages

public struct Hello: Equatable, Sendable {
    public var protocolVersion: UInt16
    public var deviceID: DeviceID
    public var screenWidthPx: UInt16
    public var screenHeightPx: UInt16
    public var densityDpi: UInt16
    public var maxRefreshHz: UInt16
    public var capabilities: Capabilities
    /// Shown in the approval dialog. Never log it.
    public var deviceName: String
    /// 16 random bytes per connection (PROTOCOL.md 9).
    public var clientNonce: [UInt8]
    /// Ephemeral P-256 public key, uncompressed (`04 || X || Y`, 65 bytes).
    public var clientEphPub: [UInt8]
    /// The payload exactly as received. The handshake transcript hashes these bytes, not a re-encoding
    /// (extra trailing bytes or non-canonical UTF-8 must not change the hash). nil for locally built values.
    public internal(set) var wirePayload: [UInt8]?

    public init(protocolVersion: UInt16 = ProtocolConstants.protocolVersion, deviceID: DeviceID,
                screenWidthPx: UInt16, screenHeightPx: UInt16, densityDpi: UInt16, maxRefreshHz: UInt16,
                capabilities: Capabilities, deviceName: String,
                clientNonce: [UInt8] = [UInt8](repeating: 0, count: ProtocolConstants.nonceSize),
                clientEphPub: [UInt8] = [UInt8](repeating: 0, count: ProtocolConstants.publicKeySize)) {
        precondition(clientNonce.count == ProtocolConstants.nonceSize
                     && clientEphPub.count == ProtocolConstants.publicKeySize)
        self.clientNonce = clientNonce
        self.clientEphPub = clientEphPub
        self.wirePayload = nil
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.screenWidthPx = screenWidthPx
        self.screenHeightPx = screenHeightPx
        self.densityDpi = densityDpi
        self.maxRefreshHz = maxRefreshHz
        self.capabilities = capabilities
        self.deviceName = deviceName
    }

    func write(_ w: inout ByteWriter) {
        w.u16(protocolVersion)
        w.raw(deviceID.bytes)
        w.u16(screenWidthPx)
        w.u16(screenHeightPx)
        w.u16(densityDpi)
        w.u16(maxRefreshHz)
        w.u32(capabilities.rawValue)
        w.str8(deviceName)
        w.raw(clientNonce)
        w.raw(clientEphPub)
    }

    /// Reads `protocol_version` first. When it is not the current version nothing else is read (an older HELLO is
    /// shorter) and the remaining fields are placeholders: the caller answers VERSION_MISMATCH (PROTOCOL.md 3).
    static func read(_ r: inout ByteReader) throws -> Hello {
        let version = try r.u16()
        guard version == ProtocolConstants.protocolVersion else {
            return Hello(protocolVersion: version, deviceID: DeviceID(bytes: [UInt8](repeating: 0, count: 16))!,
                         screenWidthPx: 0, screenHeightPx: 0, densityDpi: 0, maxRefreshHz: 0, capabilities: [],
                         deviceName: "")
        }
        guard let id = DeviceID(bytes: try r.raw(ProtocolConstants.deviceIDSize)) else {
            throw ProtocolError.invalidField("device_id")
        }
        return Hello(protocolVersion: version, deviceID: id, screenWidthPx: try r.u16(),
                     screenHeightPx: try r.u16(), densityDpi: try r.u16(), maxRefreshHz: try r.u16(),
                     capabilities: Capabilities(rawValue: try r.u32()), deviceName: try r.str8(),
                     clientNonce: try r.raw(ProtocolConstants.nonceSize),
                     clientEphPub: try r.raw(ProtocolConstants.publicKeySize))
    }

    /// Bytes the transcript hash covers.
    var transcriptBytes: [UInt8] {
        if let wirePayload { return wirePayload }
        var w = ByteWriter()
        write(&w)
        return w.bytes
    }

    // `wirePayload` is bookkeeping, not protocol content.
    public static func == (a: Hello, b: Hello) -> Bool {
        a.protocolVersion == b.protocolVersion && a.deviceID == b.deviceID
            && a.screenWidthPx == b.screenWidthPx && a.screenHeightPx == b.screenHeightPx
            && a.densityDpi == b.densityDpi && a.maxRefreshHz == b.maxRefreshHz
            && a.capabilities == b.capabilities && a.deviceName == b.deviceName
            && a.clientNonce == b.clientNonce && a.clientEphPub == b.clientEphPub
    }
}

public struct HelloAck: Equatable, Sendable {
    public var protocolVersion: UInt16
    public var status: HelloStatus
    public var sessionID: UInt32
    public var videoPort: UInt16
    public var hostName: String
    public var keyMode: KeyMode
    /// The host's persistent random id (zero when `keyMode == .none`).
    public var hostID: [UInt8]
    public var hostNonce: [UInt8]
    /// The host's ephemeral P-256 public key (zero when `keyMode == .none`).
    public var hostEphPub: [UInt8]

    public init(protocolVersion: UInt16 = ProtocolConstants.protocolVersion, status: HelloStatus,
                sessionID: UInt32, videoPort: UInt16, hostName: String, keyMode: KeyMode = .none,
                hostID: [UInt8] = [UInt8](repeating: 0, count: ProtocolConstants.deviceIDSize),
                hostNonce: [UInt8] = [UInt8](repeating: 0, count: ProtocolConstants.nonceSize),
                hostEphPub: [UInt8] = [UInt8](repeating: 0, count: ProtocolConstants.publicKeySize)) {
        precondition(hostID.count == ProtocolConstants.deviceIDSize && hostNonce.count == ProtocolConstants.nonceSize
                     && hostEphPub.count == ProtocolConstants.publicKeySize)
        self.keyMode = keyMode
        self.hostID = hostID
        self.hostNonce = hostNonce
        self.hostEphPub = hostEphPub
        self.protocolVersion = protocolVersion
        self.status = status
        self.sessionID = sessionID
        self.videoPort = videoPort
        self.hostName = hostName
    }

    func write(_ w: inout ByteWriter) {
        w.u16(protocolVersion)
        w.u8(status.rawValue)
        w.u8(0)
        w.u32(sessionID)
        w.u16(videoPort)
        w.str8(hostName)
        w.u8(keyMode.rawValue)
        w.raw(hostID)
        w.raw(hostNonce)
        w.raw(hostEphPub)
    }

    static func read(_ r: inout ByteReader) throws -> HelloAck {
        let version = try r.u16()
        guard let status = HelloStatus(rawValue: try r.u8()) else { throw ProtocolError.invalidField("status") }
        try r.skip(1)
        let sessionID = try r.u32()
        let videoPort = try r.u16()
        let hostName = try r.str8()
        guard let keyMode = KeyMode(rawValue: try r.u8()) else { throw ProtocolError.invalidField("key_mode") }
        return HelloAck(protocolVersion: version, status: status, sessionID: sessionID, videoPort: videoPort,
                        hostName: hostName, keyMode: keyMode, hostID: try r.raw(ProtocolConstants.deviceIDSize),
                        hostNonce: try r.raw(ProtocolConstants.nonceSize),
                        hostEphPub: try r.raw(ProtocolConstants.publicKeySize))
    }
}

public struct StreamConfig: Equatable, Sendable {
    public var configID: UInt16
    public var codec: Codec
    public var widthPx: UInt16
    public var heightPx: UInt16
    public var widthPt: UInt16
    public var heightPt: UInt16
    public var fps: UInt16
    public var bitrateKbps: UInt32
    public var colorPrimaries: UInt8
    public var transfer: UInt8
    public var matrix: UInt8
    public var fullRange: Bool
    /// Decision 0034 (the former `reserved` byte): `0` normal single 4:2:0 stream, `1` packed full colour (main +
    /// auxiliary 4:2:0 streams, AVC444v2 layout). The client counts any other value as 0.
    public var chromaLayout: UInt8

    public init(configID: UInt16, codec: Codec, widthPx: UInt16, heightPx: UInt16, widthPt: UInt16,
                heightPt: UInt16, fps: UInt16, bitrateKbps: UInt32, colorPrimaries: UInt8, transfer: UInt8,
                matrix: UInt8, fullRange: Bool, chromaLayout: UInt8 = 0) {
        self.configID = configID
        self.codec = codec
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.widthPt = widthPt
        self.heightPt = heightPt
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        self.colorPrimaries = colorPrimaries
        self.transfer = transfer
        self.matrix = matrix
        self.fullRange = fullRange
        self.chromaLayout = chromaLayout
    }

    /// The stream is a packed full colour pair (`chroma_layout = 1`).

    func write(_ w: inout ByteWriter) {
        w.u16(configID)
        w.u8(codec.rawValue)
        w.u8(chromaLayout)
        w.u16(widthPx)
        w.u16(heightPx)
        w.u16(widthPt)
        w.u16(heightPt)
        w.u16(fps)
        w.u32(bitrateKbps)
        w.u8(colorPrimaries)
        w.u8(transfer)
        w.u8(matrix)
        w.u8(fullRange ? 1 : 0)
    }

    static func read(_ r: inout ByteReader) throws -> StreamConfig {
        let id = try r.u16()
        guard let codec = Codec(rawValue: try r.u8()) else { throw ProtocolError.invalidField("codec") }
        let layout = try r.u8()
        return StreamConfig(configID: id, codec: codec, widthPx: try r.u16(), heightPx: try r.u16(),
                            widthPt: try r.u16(), heightPt: try r.u16(), fps: try r.u16(),
                            bitrateKbps: try r.u32(), colorPrimaries: try r.u8(), transfer: try r.u8(),
                            matrix: try r.u8(), fullRange: try r.u8() != 0, chromaLayout: layout)
    }
}

/// `STREAM_PREFS` (C->H): the user's stream mode request (docs/PROTOCOL.md 0x05). Raw wire values; the host applies
/// `normalized` (unknown fps -> 60, scale clamped).
public struct StreamPrefs: Equatable, Sendable {
    public static let supportedFps: [Int] = [15, 30, 60, 120, 144]
    public static let scaleRange: ClosedRange<Int> = 500...1000

    public var fps: UInt16
    public var scalePermille: UInt16
    /// The user's target bitrate (decision 0013); 0 = host default for the mode. Older clients send 0 here (the
    /// field used to be `reserved`).
    public var bitrateKbps: UInt32
    /// Optional trailing group (decision 0029, "game display"): the requested 1x virtual display size in pixels.
    /// 0x0 = the native display (HELLO size, HiDPI). Absent on the wire = 0x0; written when either is non-zero, or
    /// when the dynamic range group follows (it may then be 0x0).
    public var displayWidthPx: UInt16
    public var displayHeightPx: UInt16
    /// Second optional group (decision 0032): the raw `dynamic_range` (0 SDR, 1 HDR10; the host counts any other
    /// value as 0, see `normalized`). Absent on the wire = 0.
    public var dynamicRange: UInt8
    /// Same group (decision 0033, the former `reserved` byte): the raw `chroma` (0 normal 4:2:0, 1 sharp colour edges,
    /// 2 full colour / packed 4:4:4, decision 0034; the host counts any other value as 0). Absent on the wire = 0. The group is written only when `dynamicRange`
    /// or `chroma` is non-zero.
    public var chroma: UInt8
    /// Third optional group (decision 0038): the raw `link` (0 normal, 1 remote / least data; the host counts any
    /// other value as 0, see `normalized`). Absent on the wire = 0. The group is written only when `link` is non-zero
    /// (the earlier two groups are then written too).
    public var link: UInt8

    public init(fps: UInt16, scalePermille: UInt16, bitrateKbps: UInt32 = 0,
                displayWidthPx: UInt16 = 0, displayHeightPx: UInt16 = 0, dynamicRange: UInt8 = 0,
                chroma: UInt8 = 0, link: UInt8 = 0) {
        self.fps = fps
        self.scalePermille = scalePermille
        self.bitrateKbps = bitrateKbps
        self.displayWidthPx = displayWidthPx
        self.displayHeightPx = displayHeightPx
        self.dynamicRange = dynamicRange
        self.chroma = chroma
        self.link = link
    }

    /// What the host honours: fps in {15, 30, 60, 120, 144} (anything else is 60), scale clamped to 500...1000, and
    /// `dynamicRange` in {0, 1}, `chroma` in {0, 1, 2} and `link` in {0, 1} (anything else is 0, PROTOCOL.md 0x05). `bitrateKbps` and
    /// `displayWidthPx`/`displayHeightPx` are carried through unchanged (the game display size is validated by the
    /// host's policy, not here).
    public var normalized: StreamPrefs {
        let f = Self.supportedFps.contains(Int(fps)) ? fps : 60
        let s = min(max(Int(scalePermille), Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        return StreamPrefs(fps: f, scalePermille: UInt16(s), bitrateKbps: bitrateKbps,
                           displayWidthPx: displayWidthPx, displayHeightPx: displayHeightPx,
                           dynamicRange: DynamicRange(wire: dynamicRange).rawValue,
                           chroma: ChromaPreference(wire: chroma).rawValue,
                           link: link == 1 ? 1 : 0)
    }

    /// The session is a remote (least data) one (decision 0038): `link = 1`.
    public var isRemote: Bool { link == 1 }

    /// The requested dynamic range as the host reads it (unknown values are SDR).
    public var requestedDynamicRange: DynamicRange { DynamicRange(wire: dynamicRange) }

    /// The requested chroma path as the host reads it (unknown values are normal).
    public var requestedChroma: ChromaPreference { ChromaPreference(wire: chroma) }

    func write(_ w: inout ByteWriter) {
        w.u16(fps)
        w.u16(scalePermille)
        w.u32(bitrateKbps)
        let linkGroup = link != 0
        let rangeGroup = dynamicRange != 0 || chroma != 0 || linkGroup
        if displayWidthPx != 0 || displayHeightPx != 0 || rangeGroup {
            w.u16(displayWidthPx)
            w.u16(displayHeightPx)
        }
        if rangeGroup {
            w.u8(dynamicRange)
            w.u8(chroma)
        }
        if linkGroup {
            w.u8(link)
            w.u8(0)  // reserved
        }
    }

    static func read(_ r: inout ByteReader) throws -> StreamPrefs {
        var prefs = StreamPrefs(fps: try r.u16(), scalePermille: try r.u16(), bitrateKbps: try r.u32())
        // Optional trailing groups (PROTOCOL.md 2, 0x05): absent -> 0; partially present -> payload too short
        // (9-11, 13 and 15 bytes); anything after the third group is ignored (long payload rule).
        if r.remaining > 0 {
            prefs.displayWidthPx = try r.u16()
            prefs.displayHeightPx = try r.u16()
        }
        if r.remaining > 0 {
            prefs.dynamicRange = try r.u8()
            prefs.chroma = try r.u8()
        }
        if r.remaining > 0 {
            prefs.link = try r.u8()
            try r.skip(1)  // reserved
        }
        return prefs
    }
}

/// `STREAM_PREFS.dynamic_range` as the host reads it (decision 0032).
public enum DynamicRange: UInt8, Equatable, Sendable {
    case sdr = 0
    /// HEVC Main10, BT.2020 / PQ (ST 2084) / BT.2020 NCL, limited range, MDCV + CLL SEI.
    case hdr10 = 1

    /// A wire value: unknown values are SDR (PROTOCOL.md 0x05).
    public init(wire: UInt8) { self = DynamicRange(rawValue: wire) ?? .sdr }

    /// Log value: `sdr` / `hdr10`.
    public var logName: String { self == .sdr ? "sdr" : "hdr10" }
}

/// `STREAM_PREFS.chroma` as the host reads it (decision 0033).
public enum ChromaPreference: UInt8, Equatable, Sendable {
    /// Today's 4:2:0 path.
    case normal = 0
    /// Sharp colour edges: luma-adjusted 4:2:0 (T-235 `sharp_nearest`). Ignored while HDR10 is applied.
    case sharp = 1
    /// Full colour (decision 0034): packed 4:4:4 as two 4:2:0 streams. Applied only where PROTOCOL.md 0x05 allows it
    /// (`VideoSettings.applying`), else as `sharp`.
    case full = 2

    /// A wire value: unknown values are normal (PROTOCOL.md 0x05).
    public init(wire: UInt8) { self = ChromaPreference(rawValue: wire) ?? .normal }

    /// Log value: `normal` / `sharp` / `full`.
    public var logName: String {
        switch self {
        case .normal: return "normal"
        case .sharp: return "sharp"
        case .full: return "full"
        }
    }
}

/// `SETTINGS_OPEN` (H->C, docs/PROTOCOL.md 0x08): asks the tablet to show its settings panel while streaming
/// (decision 0013). Send only in an ACCEPTED session whose HELLO has `Capabilities.settingsPanel`.
public struct SettingsOpen: Equatable, Sendable {
    public init() {}

    func write(_ w: inout ByteWriter) {
        w.u32(0)
    }

    static func read(_ r: inout ByteReader) throws -> SettingsOpen {
        try r.skip(4)
        return SettingsOpen()
    }
}

/// `DISPLAY_RATE` (C->H, docs/PROTOCOL.md 0x07): the tablet panel's current refresh rate. Transient; it never
/// reconfigures the stream, the host only decimates captured frames to `min(stream fps, hz)`.
public struct DisplayRate: Equatable, Sendable {
    /// Measured panel rate rounded to an integer; 0 = unknown.
    public var hz: UInt16

    public init(hz: UInt16) { self.hz = hz }

    func write(_ w: inout ByteWriter) {
        w.u16(hz)
        w.u16(0)
    }

    static func read(_ r: inout ByteReader) throws -> DisplayRate {
        let hz = try r.u16()
        try r.skip(2)
        return DisplayRate(hz: hz)
    }
}

/// `CLIPBOARD` (both directions, docs/PROTOCOL.md 0x06). `kind` stays raw: unknown kinds decode fine and are ignored
/// by the receiver. The contents are private: never log `data`.
public struct Clipboard: Equatable, Sendable {
    public static let kindEmpty: UInt8 = 0
    public static let kindTextUTF8: UInt8 = 1

    public var seq: UInt32
    public var kind: UInt8
    public var data: [UInt8]

    public init(seq: UInt32, kind: UInt8, data: [UInt8]) {
        self.seq = seq
        self.kind = kind
        self.data = data
    }

    public static func text(seq: UInt32, _ string: String) -> Clipboard {
        Clipboard(seq: seq, kind: kindTextUTF8, data: Array(string.utf8))
    }

    public static func empty(seq: UInt32) -> Clipboard { Clipboard(seq: seq, kind: kindEmpty, data: []) }

    /// The text of a `TEXT_UTF8` message; nil for any other kind, invalid UTF-8 or no text.
    public var validText: String? {
        guard kind == Self.kindTextUTF8, !data.isEmpty else { return nil }
        return String(validating: data, as: UTF8.self)
    }

    func write(_ w: inout ByteWriter) {
        w.u32(seq)
        w.u8(kind)
        w.u8(0)
        w.u16(UInt16(clamping: data.count))
        w.raw(data)
    }

    static func read(_ r: inout ByteReader) throws -> Clipboard {
        let seq = try r.u32()
        let kind = try r.u8()
        try r.skip(1)
        let length = Int(try r.u16())
        return Clipboard(seq: seq, kind: kind, data: try r.raw(length))
    }
}

// MARK: - Input messages

public struct PenSample: Equatable, Sendable {
    /// Offset from `PenBatch.baseTimeUs`.
    public var dtUs: UInt32
    public var x: UInt16
    public var y: UInt16
    public var pressure: UInt16
    /// Raw i16, -1...1 scaled by 32767. Use `TiltCodec.decode`.
    public var tiltX: Int16
    public var tiltY: Int16
    public var flags: PenFlags

    public init(dtUs: UInt32, x: UInt16, y: UInt16, pressure: UInt16, tiltX: Int16, tiltY: Int16, flags: PenFlags) {
        self.dtUs = dtUs
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.flags = flags
    }
}

public struct PenBatch: Equatable, Sendable {
    public var tool: PenTool
    public var baseTimeUs: UInt64
    /// 1...64 samples, dt_us non-decreasing.
    public var samples: [PenSample]

    public init(tool: PenTool, baseTimeUs: UInt64, samples: [PenSample]) {
        self.tool = tool
        self.baseTimeUs = baseTimeUs
        self.samples = samples
    }

    func write(_ w: inout ByteWriter) {
        // `Message.encode()` rejects counts outside 1...64; never trap here.
        let samples = samples.prefix(ProtocolConstants.penMaxSamples)
        w.u8(tool.rawValue)
        w.u8(UInt8(samples.count))
        w.u16(0)
        w.u64(baseTimeUs)
        for s in samples {
            w.u32(s.dtUs)
            w.u16(s.x)
            w.u16(s.y)
            w.u16(s.pressure)
            w.i16(s.tiltX)
            w.i16(s.tiltY)
            w.u8(s.flags.rawValue)
            w.u8(0)
        }
    }

    static func read(_ r: inout ByteReader) throws -> PenBatch {
        guard let tool = PenTool(rawValue: try r.u8()) else { throw ProtocolError.invalidField("tool") }
        let count = Int(try r.u8())
        guard (1...ProtocolConstants.penMaxSamples).contains(count) else { throw ProtocolError.invalidField("count") }
        try r.skip(2)
        let base = try r.u64()
        var samples: [PenSample] = []
        samples.reserveCapacity(count)
        var previous: UInt32 = 0
        for _ in 0..<count {
            let dt = try r.u32()
            guard dt >= previous else { throw ProtocolError.decreasingSampleTime }
            previous = dt
            let s = PenSample(dtUs: dt, x: try r.u16(), y: try r.u16(), pressure: try r.u16(),
                              tiltX: try r.i16(), tiltY: try r.i16(), flags: PenFlags(rawValue: try r.u8()))
            try r.skip(1)
            samples.append(s)
        }
        return PenBatch(tool: tool, baseTimeUs: base, samples: samples)
    }
}

public struct KeyEvent: Equatable, Sendable {
    public var timeUs: UInt64
    public var scanCode: UInt16
    public var androidKeyCode: UInt16
    public var action: KeyAction
    /// bit0 = Caps Lock on after the event.
    public var capsLockOn: Bool

    public init(timeUs: UInt64, scanCode: UInt16, androidKeyCode: UInt16, action: KeyAction, capsLockOn: Bool) {
        self.timeUs = timeUs
        self.scanCode = scanCode
        self.androidKeyCode = androidKeyCode
        self.action = action
        self.capsLockOn = capsLockOn
    }

    /// `scan_code` if non-zero, else `0x10000 + android_key_code`; nil when both are 0 (no event).
    public var keyIdentity: UInt32? {
        if scanCode != 0 { return UInt32(scanCode) }
        if androidKeyCode != 0 { return 0x10000 + UInt32(androidKeyCode) }
        return nil
    }

    func write(_ w: inout ByteWriter) {
        w.u64(timeUs)
        w.u16(scanCode)
        w.u16(androidKeyCode)
        w.u8(action.rawValue)
        w.u8(capsLockOn ? 1 : 0)
        w.u16(0)
    }

    static func read(_ r: inout ByteReader) throws -> KeyEvent {
        let time = try r.u64()
        let scan = try r.u16()
        let android = try r.u16()
        guard let action = KeyAction(rawValue: try r.u8()) else { throw ProtocolError.invalidField("action") }
        let lock = try r.u8()
        try r.skip(2)
        return KeyEvent(timeUs: time, scanCode: scan, androidKeyCode: android, action: action,
                        capsLockOn: lock & 1 != 0)
    }
}

public struct PointerRel: Equatable, Sendable {
    public var timeUs: UInt64
    public var dx: Float
    public var dy: Float
    public var buttons: PointerButtons

    public init(timeUs: UInt64, dx: Float, dy: Float, buttons: PointerButtons) {
        self.timeUs = timeUs
        self.dx = dx
        self.dy = dy
        self.buttons = buttons
    }

    func write(_ w: inout ByteWriter) {
        w.u64(timeUs)
        w.f32(dx)
        w.f32(dy)
        w.u8(buttons.rawValue)
        w.u8(0)
        w.u16(0)
    }

    static func read(_ r: inout ByteReader) throws -> PointerRel {
        let t = try r.u64()
        let dx = try r.f32("dx")
        let dy = try r.f32("dy")
        let b = try r.u8()
        try r.skip(3)
        return PointerRel(timeUs: t, dx: dx, dy: dy, buttons: PointerButtons(rawValue: b))
    }
}

public struct PointerAbs: Equatable, Sendable {
    public var timeUs: UInt64
    public var x: UInt16
    public var y: UInt16
    public var buttons: PointerButtons
    public var source: PointerSource

    public init(timeUs: UInt64, x: UInt16, y: UInt16, buttons: PointerButtons, source: PointerSource) {
        self.timeUs = timeUs
        self.x = x
        self.y = y
        self.buttons = buttons
        self.source = source
    }

    func write(_ w: inout ByteWriter) {
        w.u64(timeUs)
        w.u16(x)
        w.u16(y)
        w.u8(buttons.rawValue)
        w.u8(source.rawValue)
        w.u16(0)
    }

    static func read(_ r: inout ByteReader) throws -> PointerAbs {
        let t = try r.u64()
        let x = try r.u16()
        let y = try r.u16()
        let b = try r.u8()
        guard let source = PointerSource(rawValue: try r.u8()) else { throw ProtocolError.invalidField("source") }
        try r.skip(2)
        return PointerAbs(timeUs: t, x: x, y: y, buttons: PointerButtons(rawValue: b), source: source)
    }
}

public struct Scroll: Equatable, Sendable {
    public var timeUs: UInt64
    public var dx: Float
    public var dy: Float
    public var phase: ScrollPhase

    public init(timeUs: UInt64, dx: Float, dy: Float, phase: ScrollPhase) {
        self.timeUs = timeUs
        self.dx = dx
        self.dy = dy
        self.phase = phase
    }

    func write(_ w: inout ByteWriter) {
        w.u64(timeUs)
        w.f32(dx)
        w.f32(dy)
        w.u8(phase.rawValue)
        w.u8(0)
        w.u16(0)
    }

    static func read(_ r: inout ByteReader) throws -> Scroll {
        let t = try r.u64()
        let dx = try r.f32("dx")
        let dy = try r.f32("dy")
        guard let phase = ScrollPhase(rawValue: try r.u8()) else { throw ProtocolError.invalidField("phase") }
        try r.skip(3)
        return Scroll(timeUs: t, dx: dx, dy: dy, phase: phase)
    }
}

/// PROTOCOL.md section 4 PINCH. Same numbering as `ScrollPhase` without `none` (0 is invalid).
public enum PinchPhase: UInt8, Sendable {
    case began = 1, changed = 2, ended = 3, cancelled = 4
}

public enum PinchSource: UInt8, Sendable {
    case touch = 0, touchpad = 1
}

public struct Pinch: Equatable, Sendable {
    public var timeUs: UInt64
    /// Relative change of the finger distance since the previous PINCH message. 0 on BEGAN and ENDED.
    public var scale: Float
    /// Normalized center of the two fingers; meaningful for `source == .touch` only.
    public var x: UInt16
    public var y: UInt16
    public var phase: PinchPhase
    public var source: PinchSource

    public init(timeUs: UInt64, scale: Float, x: UInt16, y: UInt16, phase: PinchPhase, source: PinchSource) {
        self.timeUs = timeUs
        self.scale = scale
        self.x = x
        self.y = y
        self.phase = phase
        self.source = source
    }

    func write(_ w: inout ByteWriter) {
        w.u64(timeUs)
        w.f32(scale)
        w.u16(x)
        w.u16(y)
        w.u8(phase.rawValue)
        w.u8(source.rawValue)
        w.u16(0)
    }

    static func read(_ r: inout ByteReader) throws -> Pinch {
        let t = try r.u64()
        let scale = try r.f32("scale")
        let x = try r.u16()
        let y = try r.u16()
        guard let phase = PinchPhase(rawValue: try r.u8()) else { throw ProtocolError.invalidField("phase") }
        guard let source = PinchSource(rawValue: try r.u8()) else { throw ProtocolError.invalidField("source") }
        try r.skip(2)
        return Pinch(timeUs: t, scale: scale, x: x, y: y, phase: phase, source: source)
    }
}

public struct PenGesture: Equatable, Sendable {
    public var timeUs: UInt64
    public var gesture: PenGestureKind

    public init(timeUs: UInt64, gesture: PenGestureKind) {
        self.timeUs = timeUs
        self.gesture = gesture
    }

    func write(_ w: inout ByteWriter) {
        w.u64(timeUs)
        w.u8(gesture.rawValue)
        w.u8(0)
        w.u16(0)
    }

    static func read(_ r: inout ByteReader) throws -> PenGesture {
        let t = try r.u64()
        let g = try r.u8()
        try r.skip(3)
        return PenGesture(timeUs: t, gesture: PenGestureKind(rawValue: g))
    }
}

// MARK: - Maintenance messages

public struct Ping: Equatable, Sendable {
    public var seq: UInt32
    public var senderTimeUs: UInt64
    public init(seq: UInt32, senderTimeUs: UInt64) {
        self.seq = seq
        self.senderTimeUs = senderTimeUs
    }

    func write(_ w: inout ByteWriter) {
        w.u32(seq)
        w.u64(senderTimeUs)
    }

    static func read(_ r: inout ByteReader) throws -> Ping { Ping(seq: try r.u32(), senderTimeUs: try r.u64()) }
}

public struct Pong: Equatable, Sendable {
    public var seq: UInt32
    public var echoTimeUs: UInt64
    public var responderTimeUs: UInt64
    public init(seq: UInt32, echoTimeUs: UInt64, responderTimeUs: UInt64) {
        self.seq = seq
        self.echoTimeUs = echoTimeUs
        self.responderTimeUs = responderTimeUs
    }

    func write(_ w: inout ByteWriter) {
        w.u32(seq)
        w.u64(echoTimeUs)
        w.u64(responderTimeUs)
    }

    static func read(_ r: inout ByteReader) throws -> Pong {
        Pong(seq: try r.u32(), echoTimeUs: try r.u64(), responderTimeUs: try r.u64())
    }
}

public struct Stats: Equatable, Sendable {
    public var intervalMs: UInt32
    public var framesReceived: UInt32
    public var framesDecoded: UInt32
    public var framesRendered: UInt32
    public var framesDropped: UInt32
    public var decodeTimeAvgUs: UInt32
    public var latencyAvgUs: UInt32
    public var bytesReceived: UInt32

    public init(intervalMs: UInt32, framesReceived: UInt32, framesDecoded: UInt32, framesRendered: UInt32,
                framesDropped: UInt32, decodeTimeAvgUs: UInt32, latencyAvgUs: UInt32, bytesReceived: UInt32) {
        self.intervalMs = intervalMs
        self.framesReceived = framesReceived
        self.framesDecoded = framesDecoded
        self.framesRendered = framesRendered
        self.framesDropped = framesDropped
        self.decodeTimeAvgUs = decodeTimeAvgUs
        self.latencyAvgUs = latencyAvgUs
        self.bytesReceived = bytesReceived
    }

    func write(_ w: inout ByteWriter) {
        w.u32(intervalMs)
        w.u32(framesReceived)
        w.u32(framesDecoded)
        w.u32(framesRendered)
        w.u32(framesDropped)
        w.u32(decodeTimeAvgUs)
        w.u32(latencyAvgUs)
        w.u32(bytesReceived)
    }

    static func read(_ r: inout ByteReader) throws -> Stats {
        Stats(intervalMs: try r.u32(), framesReceived: try r.u32(), framesDecoded: try r.u32(),
              framesRendered: try r.u32(), framesDropped: try r.u32(), decodeTimeAvgUs: try r.u32(),
              latencyAvgUs: try r.u32(), bytesReceived: try r.u32())
    }
}

// MARK: - Video messages

public struct VideoHello: Equatable, Sendable {
    public var protocolVersion: UInt16
    public var configID: UInt16
    public var sessionID: UInt32
    /// Fresh random value per video connection; the connection's keys derive from it (PROTOCOL.md 9).
    public var videoNonce: [UInt8]
    public init(protocolVersion: UInt16 = ProtocolConstants.protocolVersion, configID: UInt16, sessionID: UInt32,
                videoNonce: [UInt8] = [UInt8](repeating: 0, count: ProtocolConstants.nonceSize)) {
        precondition(videoNonce.count == ProtocolConstants.nonceSize)
        self.videoNonce = videoNonce
        self.protocolVersion = protocolVersion
        self.configID = configID
        self.sessionID = sessionID
    }

    func write(_ w: inout ByteWriter) {
        w.u16(protocolVersion)
        w.u16(configID)
        w.u32(sessionID)
        w.raw(videoNonce)
    }

    static func read(_ r: inout ByteReader) throws -> VideoHello {
        VideoHello(protocolVersion: try r.u16(), configID: try r.u16(), sessionID: try r.u32(),
                   videoNonce: try r.raw(ProtocolConstants.nonceSize))
    }
}

public struct VideoFrame: Equatable, Sendable {
    public var frameSeq: UInt32
    public var captureTimeUs: UInt64
    public var flags: VideoFrameFlags
    public var fragmentIndex: UInt16
    public var fragmentCount: UInt16
    public var frameSize: UInt32
    /// Decision 0034 (the former `reserved` byte): `0` main (always, in a single stream), `1` auxiliary.
    public var view: UInt8
    /// Annex-B NAL units.
    public var data: [UInt8]

    /// Single-fragment (TCP) frame: `frameSize` is derived from `data`.
    public init(frameSeq: UInt32, captureTimeUs: UInt64, flags: VideoFrameFlags, view: UInt8 = 0, data: [UInt8]) {
        self.frameSeq = frameSeq
        self.captureTimeUs = captureTimeUs
        self.flags = flags
        self.fragmentIndex = 0
        self.fragmentCount = 1
        self.frameSize = UInt32(data.count)
        self.view = view
        self.data = data
    }

    public init(frameSeq: UInt32, captureTimeUs: UInt64, flags: VideoFrameFlags, view: UInt8 = 0,
                fragmentIndex: UInt16, fragmentCount: UInt16, frameSize: UInt32, data: [UInt8]) {
        self.frameSeq = frameSeq
        self.captureTimeUs = captureTimeUs
        self.flags = flags
        self.view = view
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.frameSize = frameSize
        self.data = data
    }

    func write(_ w: inout ByteWriter) {
        w.u32(frameSeq)
        w.u64(captureTimeUs)
        w.u8(flags.rawValue)
        w.u8(view)
        w.u16(fragmentIndex)
        w.u16(fragmentCount)
        w.u16(0)
        w.u32(frameSize)
        w.raw(data)
    }

    static func read(_ r: inout ByteReader) throws -> VideoFrame {
        let seq = try r.u32()
        let capture = try r.u64()
        let flags = try r.u8()
        let view = try r.u8()
        let index = try r.u16()
        let count = try r.u16()
        try r.skip(2)
        let size = try r.u32()
        // TCP carries whole frames only (PROTOCOL.md VIDEO_FRAME).
        // `data` is exactly frame_size bytes; trailing bytes are future fields and ignored.
        guard index == 0, count == 1, Int(size) <= r.remaining else {
            throw ProtocolError.invalidField("video fragment")
        }
        return VideoFrame(frameSeq: seq, captureTimeUs: capture, flags: VideoFrameFlags(rawValue: flags), view: view,
                          fragmentIndex: index, fragmentCount: count, frameSize: size,
                          data: try r.raw(Int(size)))
    }
}
