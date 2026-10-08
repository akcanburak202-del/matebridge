// Local cursor messages, docs/PROTOCOL.md 0x0B-0x0D (decision 0036). The shape image and the position are display
// content: never log them (only counts, sizes and times).

/// `CURSOR_PREFS` (C->H, 0x0B, only with `HELLO` bit13): the tablet asks to draw the cursor itself.
public struct CursorPrefs: Equatable, Sendable {
    /// `1` the tablet draws the cursor (no cursor in the video, `CURSOR_*` flow); anything else is `0`.
    public var enabled: Bool

    public init(enabled: Bool) { self.enabled = enabled }

    func write(_ w: inout ByteWriter) {
        w.u8(enabled ? 1 : 0)
        w.u8(0)
        w.u16(0)
    }

    /// A payload shorter than 4 bytes is a protocol error; an unknown `enabled` value counts as `0`.
    static func read(_ r: inout ByteReader) throws -> CursorPrefs {
        let enabled = try r.u8()
        try r.skip(3)
        return CursorPrefs(enabled: enabled == 1)
    }
}

/// `CURSOR_SHAPE.format`. Unknown values decode fine; the client ignores the image (PROTOCOL.md 0x0C).
public struct CursorShapeFormat: OpenCode {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// RGBA, sRGB, straight (non-premultiplied) alpha.
    public static let png = CursorShapeFormat(rawValue: 1)
}

/// `CURSOR_SHAPE` (H->C, 0x0C): one cursor image with its hotspot. `data_len` on the wire is `data.count`.
public struct CursorShape: Equatable, Sendable {
    /// Fixed part before `data`: shape_id, width, height, hot_x, hot_y (pt x 16), format, reserved, data_len.
    public static let fixedSize = 16
    /// Largest image the host sends: 128 x 128 px.
    public static let maxPixels = 128
    /// Longest `data` (PROTOCOL.md 0x0C).
    public static let maxDataBytes = 61_440

    /// Identity of the image + hotspot digest; `0` is never used for a shape.
    public var shapeID: UInt32
    /// Size and hotspot in Mac points x 16.
    public var widthPt16: UInt16
    public var heightPt16: UInt16
    public var hotXPt16: UInt16
    public var hotYPt16: UInt16
    public var format: CursorShapeFormat
    public var data: [UInt8]

    public init(shapeID: UInt32, widthPt16: UInt16, heightPt16: UInt16, hotXPt16: UInt16, hotYPt16: UInt16,
                format: CursorShapeFormat = .png, data: [UInt8]) {
        self.shapeID = shapeID
        self.widthPt16 = widthPt16
        self.heightPt16 = heightPt16
        self.hotXPt16 = hotXPt16
        self.hotYPt16 = hotYPt16
        self.format = format
        self.data = data
    }

    func write(_ w: inout ByteWriter) {
        w.u32(shapeID)
        w.u16(widthPt16)
        w.u16(heightPt16)
        w.u16(hotXPt16)
        w.u16(hotYPt16)
        w.u8(format.rawValue)
        w.u8(0)
        w.u16(UInt16(clamping: data.count))
        w.raw(data)
    }

    /// `data_len` of 0 or above 61 440, or a payload shorter than `16 + data_len`, is a protocol error. Trailing
    /// bytes are future fields and ignored.
    static func read(_ r: inout ByteReader) throws -> CursorShape {
        let shapeID = try r.u32()
        let width = try r.u16(), height = try r.u16(), hotX = try r.u16(), hotY = try r.u16()
        let format = CursorShapeFormat(rawValue: try r.u8())
        try r.skip(1)
        let dataLen = Int(try r.u16())
        guard (1...maxDataBytes).contains(dataLen) else { throw ProtocolError.invalidField("data_len") }
        return CursorShape(shapeID: shapeID, widthPt16: width, heightPt16: height, hotXPt16: hotX, hotYPt16: hotY,
                           format: format, data: try r.raw(dataLen))
    }
}

/// `CURSOR_STATE` (H->C, 0x0D): where the cursor is and which shape to draw.
public struct CursorState: Equatable, Sendable {
    /// +1 for every state of the session.
    public var seq: UInt32
    /// Hotspot position, normalized on the video surface (PROTOCOL.md 1).
    public var x: UInt16
    public var y: UInt16
    public var visible: Bool
    /// `CURSOR_SHAPE.shape_id` to draw; `0` (or an id the client lacks) means the built-in arrow.
    public var shapeID: UInt32
    /// Host monotonic microseconds at the time of the sample (measurement only).
    public var hostTimeUs: UInt64

    public init(seq: UInt32, x: UInt16, y: UInt16, visible: Bool, shapeID: UInt32, hostTimeUs: UInt64) {
        self.seq = seq
        self.x = x
        self.y = y
        self.visible = visible
        self.shapeID = shapeID
        self.hostTimeUs = hostTimeUs
    }

    func write(_ w: inout ByteWriter) {
        w.u32(seq)
        w.u16(x)
        w.u16(y)
        w.u8(visible ? 1 : 0)
        w.u8(0)
        w.u32(shapeID)
        w.u64(hostTimeUs)
    }

    /// An unknown `visible` value counts as hidden (PROTOCOL.md 0x0D).
    static func read(_ r: inout ByteReader) throws -> CursorState {
        let seq = try r.u32()
        let x = try r.u16(), y = try r.u16()
        let visible = try r.u8()
        try r.skip(1)
        return CursorState(seq: seq, x: x, y: y, visible: visible == 1, shapeID: try r.u32(), hostTimeUs: try r.u64())
    }
}
