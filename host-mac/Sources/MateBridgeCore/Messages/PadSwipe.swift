/// Direction the fingers went (PROTOCOL.md section 4 PAD_SWIPE, decision 0043).
public enum PadSwipeDirection: UInt8, Sendable {
    case up = 1, down = 2, left = 3, right = 4

    /// The Mac shortcut this swipe stands for (PROTOCOL.md section 4 table): Control plus this arrow. Fingers
    /// going left show the desktop on the right, as on a real trackpad.
    /// macOS virtual keycodes: kVK_UpArrow 0x7E, kVK_DownArrow 0x7D, kVK_LeftArrow 0x7B, kVK_RightArrow 0x7C.
    public var arrowKeyCode: UInt16 {
        switch self {
        case .up: 0x7E
        case .down: 0x7D
        case .left: 0x7C
        case .right: 0x7B
        }
    }
}

/// PROTOCOL.md section 4 PAD_SWIPE: a three-finger swipe on the touchpad. Unknown `direction` values are not a
/// protocol error: the message decodes and the state machine ignores it, so `directionRaw` keeps the wire value.
public struct PadSwipe: Equatable, Sendable {
    public var timeUs: UInt64
    public var directionRaw: UInt8
    public var fingers: UInt8

    public init(timeUs: UInt64, direction: PadSwipeDirection, fingers: UInt8 = 3) {
        self.init(timeUs: timeUs, directionRaw: direction.rawValue, fingers: fingers)
    }

    public init(timeUs: UInt64, directionRaw: UInt8, fingers: UInt8) {
        self.timeUs = timeUs
        self.directionRaw = directionRaw
        self.fingers = fingers
    }

    /// nil for a value this host does not know.
    public var direction: PadSwipeDirection? { PadSwipeDirection(rawValue: directionRaw) }

    func write(_ w: inout ByteWriter) {
        w.u64(timeUs)
        w.u8(directionRaw)
        w.u8(fingers)
        w.u16(0)
    }

    static func read(_ r: inout ByteReader) throws -> PadSwipe {
        let t = try r.u64()
        let direction = try r.u8()
        let fingers = try r.u8()
        try r.skip(2)
        return PadSwipe(timeUs: t, directionRaw: direction, fingers: fingers)
    }
}
