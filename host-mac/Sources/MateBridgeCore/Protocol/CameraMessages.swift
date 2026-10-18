// Tablet camera messages, docs/PROTOCOL.md 0x0E, 0x0F and 0x60-0x63 (decision 0040). `CAM_FRAME.data` is camera
// content: never log or write it.

/// `CAMERA_PREFS.mode`. Unknown values decode fine and count as OFF.
public struct CameraMode: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let off = CameraMode(rawValue: 0)
    public static let auto = CameraMode(rawValue: 1)
}

/// `CAMERA_PREFS.facing`. Unknown values decode fine and count as FRONT.
public struct CameraFacing: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let front = CameraFacing(rawValue: 0)
    public static let back = CameraFacing(rawValue: 1)
}

/// `CAMERA_PREFS` (C->H, 0x0E). The host ignores `facing` (the client switches cameras on the same connection).
public struct CameraPrefs: Equatable, Sendable {
    public var mode: CameraMode
    public var facing: CameraFacing

    public init(mode: CameraMode, facing: CameraFacing = .front) {
        self.mode = mode
        self.facing = facing
    }

    /// Only AUTO is AUTO: any other value, unknown ones included, is OFF.
    public var isAuto: Bool { mode == .auto }

    func write(_ w: inout ByteWriter) {
        w.u8(mode.rawValue)
        w.u8(facing.rawValue)
        w.u16(0)
    }

    static func read(_ r: inout ByteReader) throws -> CameraPrefs {
        let prefs = CameraPrefs(mode: CameraMode(rawValue: try r.u8()), facing: CameraFacing(rawValue: try r.u8()))
        try r.skip(2)  // reserved
        return prefs
    }
}

/// `CAMERA_CONTROL.state`. Unknown values decode fine and count as STOP.
public struct CameraControlState: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let stop = CameraControlState(rawValue: 0)
    public static let start = CameraControlState(rawValue: 1)
    public static let unavailable = CameraControlState(rawValue: 2)
}

/// `CAMERA_CONTROL` (H->C, 0x0F, 15 bytes).
public struct CameraControl: Equatable, Sendable {
    public static let recommendedWidth: UInt16 = 1920
    public static let recommendedHeight: UInt16 = 1080
    public static let recommendedFps: UInt8 = 30
    public static let recommendedBitrateKbps: UInt32 = 6000

    public var state: CameraControlState
    public var camID: UInt16
    public var port: UInt16
    public var width: UInt16
    public var height: UInt16
    public var fps: UInt8
    public var bitrateKbps: UInt32

    public init(state: CameraControlState, camID: UInt16, port: UInt16 = 0, width: UInt16 = 0, height: UInt16 = 0,
                fps: UInt8 = 0, bitrateKbps: UInt32 = 0) {
        self.state = state
        self.camID = camID
        self.port = port
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
    }

    public static func start(camID: UInt16, port: UInt16) -> CameraControl {
        CameraControl(state: .start, camID: camID, port: port, width: recommendedWidth, height: recommendedHeight,
                      fps: recommendedFps, bitrateKbps: recommendedBitrateKbps)
    }

    public static func stop(camID: UInt16) -> CameraControl { CameraControl(state: .stop, camID: camID) }
    public static let unavailable = CameraControl(state: .unavailable, camID: 0)

    func write(_ w: inout ByteWriter) {
        w.u8(state.rawValue)
        w.u16(camID)
        w.u16(port)
        w.u16(width)
        w.u16(height)
        w.u8(fps)
        w.u8(0)  // reserved
        w.u32(bitrateKbps)
    }

    static func read(_ r: inout ByteReader) throws -> CameraControl {
        let state = CameraControlState(rawValue: try r.u8())
        let camID = try r.u16(), port = try r.u16(), width = try r.u16(), height = try r.u16()
        let fps = try r.u8()
        try r.skip(1)  // reserved
        return CameraControl(state: state, camID: camID, port: port, width: width, height: height, fps: fps,
                             bitrateKbps: try r.u32())
    }
}

/// `CAM_HELLO` (C->H, 0x60, plain): the first message of the camera connection.
public struct CamHello: Equatable, Sendable {
    public var protocolVersion: UInt16
    public var sessionID: UInt32
    public var camID: UInt16
    /// Fresh random value per camera connection; the keys derive from it and the host's nonce (section 9).
    public var clientNonce: [UInt8]

    public init(protocolVersion: UInt16 = ProtocolConstants.protocolVersion, sessionID: UInt32, camID: UInt16,
                clientNonce: [UInt8]) {
        precondition(clientNonce.count == ProtocolConstants.nonceSize)
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.camID = camID
        self.clientNonce = clientNonce
    }

    func write(_ w: inout ByteWriter) {
        w.u16(protocolVersion)
        w.u32(sessionID)
        w.u16(camID)
        w.raw(clientNonce)
    }

    /// A payload shorter than 24 bytes is a protocol error (`payloadTooShort`).
    static func read(_ r: inout ByteReader) throws -> CamHello {
        CamHello(protocolVersion: try r.u16(), sessionID: try r.u32(), camID: try r.u16(),
                 clientNonce: try r.raw(ProtocolConstants.nonceSize))
    }
}

/// `CAM_HELLO_ACK.status`. Unknown values decode fine and count as REJECTED.
public struct CamHelloStatus: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let ok = CamHelloStatus(rawValue: 0)
    public static let rejected = CamHelloStatus(rawValue: 1)
}

/// `CAM_HELLO_ACK` (H->C, 0x61, plain).
public struct CamHelloAck: Equatable, Sendable {
    public var status: CamHelloStatus
    /// OK: fresh random value per camera connection. REJECTED: all zero.
    public var hostNonce: [UInt8]

    public init(status: CamHelloStatus, hostNonce: [UInt8]) {
        precondition(hostNonce.count == ProtocolConstants.nonceSize)
        self.status = status
        self.hostNonce = hostNonce
    }

    public static let rejected = CamHelloAck(status: .rejected,
                                             hostNonce: [UInt8](repeating: 0, count: ProtocolConstants.nonceSize))

    /// Only OK is OK.
    public var isOK: Bool { status == .ok }

    func write(_ w: inout ByteWriter) {
        w.u8(status.rawValue)
        w.raw(hostNonce)
    }

    static func read(_ r: inout ByteReader) throws -> CamHelloAck {
        CamHelloAck(status: CamHelloStatus(rawValue: try r.u8()), hostNonce: try r.raw(ProtocolConstants.nonceSize))
    }
}

/// `CAM_FRAME.flags`.
public struct CamFrameFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let keyframe = CamFrameFlags(rawValue: 1 << 0)
    /// `data` is only H.264 SPS/PPS.
    public static let codecConfig = CamFrameFlags(rawValue: 1 << 1)
}

/// `CAM_FRAME` (C->H, 0x62): one H.264 access unit (Annex-B) or the SPS/PPS. `data` is camera content: never logged.
public struct CamFrame: Equatable, Sendable {
    /// Largest `data` (PROTOCOL.md 0x62): the camera payload limit minus the 20 byte header.
    public static let maxDataBytes = ProtocolConstants.maxCameraPayload - 20

    public var frameSeq: UInt32
    public var captureTimeUs: UInt64
    public var flags: CamFrameFlags
    public var data: [UInt8]

    public init(frameSeq: UInt32, captureTimeUs: UInt64, flags: CamFrameFlags, data: [UInt8]) {
        self.frameSeq = frameSeq
        self.captureTimeUs = captureTimeUs
        self.flags = flags
        self.data = data
    }

    public var isKeyframe: Bool { flags.contains(.keyframe) }
    public var isCodecConfig: Bool { flags.contains(.codecConfig) }

    func write(_ w: inout ByteWriter) {
        w.u32(frameSeq)
        w.u64(captureTimeUs)
        w.u8(flags.rawValue)
        w.u8(0)  // reserved
        w.u16(0)  // reserved2
        w.u32(UInt32(truncatingIfNeeded: data.count))
        w.raw(data)
    }

    /// `frame_size = 0` is `invalidField("frame_size")`, a payload shorter than `20 + frame_size` is `payloadTooShort`
    /// (both end the camera connection). Extra bytes after `data` are ignored (PROTOCOL.md section 2).
    static func read(_ r: inout ByteReader) throws -> CamFrame {
        let seq = try r.u32(), time = try r.u64()
        let flags = CamFrameFlags(rawValue: try r.u8())
        try r.skip(3)  // reserved, reserved2
        let size = Int(try r.u32())
        guard size >= 1, size <= maxDataBytes else { throw ProtocolError.invalidField("frame_size") }
        return CamFrame(frameSeq: seq, captureTimeUs: time, flags: flags, data: try r.raw(size))
    }
}

/// `CAM_KEYFRAME_REQUEST.reason`. Unknown values are accepted.
public struct CamKeyframeReason: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let startup = CamKeyframeReason(rawValue: 0)
    public static let decodeError = CamKeyframeReason(rawValue: 1)
    public static let framesDropped = CamKeyframeReason(rawValue: 2)
}
