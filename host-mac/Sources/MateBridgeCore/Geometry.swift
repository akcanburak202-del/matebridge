// Coordinate, pressure and tilt conversions (docs/PROTOCOL.md section 1).

public enum NormalizedCoord {
    public static let maxValue: UInt16 = 65535

    /// Client side: `round(clamp(px / surface, 0, 1) * 65535)`. Non-finite input maps to 0.
    public static func encode(px: Double, surface: Double) -> UInt16 {
        guard px.isFinite, surface.isFinite, surface > 0 else { return 0 }
        let unit = min(max(px / surface, 0), 1)
        return UInt16((unit * 65535).rounded())
    }

    /// Host side: point in global display coordinates, clamped to `[origin, origin + extent - 1/scale]`.
    /// `extent` is the display width or height in points, `scale` the backing scale factor.
    public static func toPoints(_ v: UInt16, origin: Double, extent: Double, scale: Double) -> Double {
        let raw = origin + Double(v) / 65535 * extent
        let upper = origin + extent - 1 / (scale > 0 ? scale : 1)
        return min(max(raw, origin), Swift.max(upper, origin))
    }
}

public enum PressureCodec {
    /// 0...1 to u16 (`round(v * 65535)`), clamped. Non-finite maps to 0.
    public static func encode(_ v: Double) -> UInt16 {
        guard v.isFinite else { return 0 }
        return UInt16((min(max(v, 0), 1) * 65535).rounded())
    }

    public static func decode(_ raw: UInt16) -> Double { Double(raw) / 65535 }
}

public enum TiltCodec {
    /// -1...1 to i16 (`round(v * 32767)`), clamped. Non-finite maps to 0.
    public static func encode(_ v: Double) -> Int16 {
        guard v.isFinite else { return 0 }
        return Int16((min(max(v, -1), 1) * 32767).rounded())
    }

    /// i16 to -1...1; -32768 counts as -32767.
    public static func decode(_ raw: Int16) -> Double { Double(Swift.max(raw, -32767)) / 32767 }
}
