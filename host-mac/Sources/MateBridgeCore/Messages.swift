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
public struct PenGestureKind: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let doubleTap = PenGestureKind(rawValue: 1)
}

public enum HelloStatus: UInt8, Sendable {
    case accepted = 0, pendingApproval = 1, rejected = 2, versionMismatch = 3, busy = 4
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

    public init(protocolVersion: UInt16 = ProtocolConstants.protocolVersion, deviceID: DeviceID,
                screenWidthPx: UInt16, screenHeightPx: UInt16, densityDpi: UInt16, maxRefreshHz: UInt16,
                capabilities: Capabilities, deviceName: String) {
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
    }

    static func read(_ r: inout ByteReader) throws -> Hello {
        let version = try r.u16()
        guard let id = DeviceID(bytes: try r.raw(ProtocolConstants.deviceIDSize)) else {
            throw ProtocolError.invalidField("device_id")
        }
        return Hello(protocolVersion: version, deviceID: id, screenWidthPx: try r.u16(),
                     screenHeightPx: try r.u16(), densityDpi: try r.u16(), maxRefreshHz: try r.u16(),
                     capabilities: Capabilities(rawValue: try r.u32()), deviceName: try r.str8())
    }
}

public struct HelloAck: Equatable, Sendable {
    public var protocolVersion: UInt16
    public var status: HelloStatus
    public var sessionID: UInt32
    public var videoPort: UInt16
    public var hostName: String

    public init(protocolVersion: UInt16 = ProtocolConstants.protocolVersion, status: HelloStatus,
                sessionID: UInt32, videoPort: UInt16, hostName: String) {
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
    }

    static func read(_ r: inout ByteReader) throws -> HelloAck {
        let version = try r.u16()
        guard let status = HelloStatus(rawValue: try r.u8()) else { throw ProtocolError.invalidField("status") }
        try r.skip(1)
        return HelloAck(protocolVersion: version, status: status, sessionID: try r.u32(),
                        videoPort: try r.u16(), hostName: try r.str8())
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

    public init(configID: UInt16, codec: Codec, widthPx: UInt16, heightPx: UInt16, widthPt: UInt16,
                heightPt: UInt16, fps: UInt16, bitrateKbps: UInt32, colorPrimaries: UInt8, transfer: UInt8,
                matrix: UInt8, fullRange: Bool) {
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
    }

    func write(_ w: inout ByteWriter) {
        w.u16(configID)
        w.u8(codec.rawValue)
        w.u8(0)
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
        try r.skip(1)
        return StreamConfig(configID: id, codec: codec, widthPx: try r.u16(), heightPx: try r.u16(),
                            widthPt: try r.u16(), heightPt: try r.u16(), fps: try r.u16(),
                            bitrateKbps: try r.u32(), colorPrimaries: try r.u8(), transfer: try r.u8(),
                            matrix: try r.u8(), fullRange: try r.u8() != 0)
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
}

// MARK: - Video messages

public struct VideoHello: Equatable, Sendable {
    public var protocolVersion: UInt16
    public var configID: UInt16
    public var sessionID: UInt32
    public init(protocolVersion: UInt16 = ProtocolConstants.protocolVersion, configID: UInt16, sessionID: UInt32) {
        self.protocolVersion = protocolVersion
        self.configID = configID
        self.sessionID = sessionID
    }
}

public struct VideoFrame: Equatable, Sendable {
    public var frameSeq: UInt32
    public var captureTimeUs: UInt64
    public var flags: VideoFrameFlags
    public var fragmentIndex: UInt16
    public var fragmentCount: UInt16
    public var frameSize: UInt32
    /// Annex-B NAL units.
    public var data: [UInt8]

    /// Single-fragment (TCP) frame: `frameSize` is derived from `data`.
    public init(frameSeq: UInt32, captureTimeUs: UInt64, flags: VideoFrameFlags, data: [UInt8]) {
        self.frameSeq = frameSeq
        self.captureTimeUs = captureTimeUs
        self.flags = flags
        self.fragmentIndex = 0
        self.fragmentCount = 1
        self.frameSize = UInt32(data.count)
        self.data = data
    }

    public init(frameSeq: UInt32, captureTimeUs: UInt64, flags: VideoFrameFlags, fragmentIndex: UInt16,
                fragmentCount: UInt16, frameSize: UInt32, data: [UInt8]) {
        self.frameSeq = frameSeq
        self.captureTimeUs = captureTimeUs
        self.flags = flags
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.frameSize = frameSize
        self.data = data
    }

    func write(_ w: inout ByteWriter) {
        w.u32(frameSeq)
        w.u64(captureTimeUs)
        w.u8(flags.rawValue)
        w.u8(0)
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
        try r.skip(1)
        let index = try r.u16()
        let count = try r.u16()
        try r.skip(2)
        let size = try r.u32()
        // TCP carries whole frames only (PROTOCOL.md VIDEO_FRAME).
        // `data` is exactly frame_size bytes; trailing bytes are future fields and ignored.
        guard index == 0, count == 1, Int(size) <= r.remaining else {
            throw ProtocolError.invalidField("video fragment")
        }
        return VideoFrame(frameSeq: seq, captureTimeUs: capture, flags: VideoFrameFlags(rawValue: flags),
                          fragmentIndex: index, fragmentCount: count, frameSize: size,
                          data: try r.raw(Int(size)))
    }
}
