public enum ProtocolConstants {
    public static let protocolVersion: UInt16 = 0
    public static let headerSize = 5
    public static let maxControlPayload = 65_536
    public static let maxVideoPayload = 16_777_216
    public static let maxStringBytes = 64
    public static let deviceIDSize = 16
    public static let penSampleSize = 16
    public static let penMaxSamples = 64
    public static let penFixedSize = 12
}

public enum MessageType: UInt8, Sendable, CaseIterable {
    case hello = 0x01
    case helloAck = 0x02
    case streamConfig = 0x03
    case bye = 0x04
    case pen = 0x10
    case key = 0x11
    case pointerRel = 0x12
    case pointerAbs = 0x13
    case scroll = 0x14
    case penGesture = 0x15
    case releaseAll = 0x16
    case pinch = 0x17
    case ping = 0x20
    case pong = 0x21
    case stats = 0x22
    case keyframeRequest = 0x23
    case videoHello = 0x40
    case videoFrame = 0x41
}
