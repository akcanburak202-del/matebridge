/// Which image of a cursor to send, at what size, and its id (decision 0036, PROTOCOL.md 0x0C). Pure arithmetic: the
/// host shell renders and encodes.
public enum CursorShapeLayout {
    /// Pixel size of one cursor image representation.
    public struct Size: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// The tablet draws a point as `surface px / STREAM_CONFIG.width_pt` pixels: 2 for the 2x virtual display, 1 for a
    /// game display, and in between when the surface is scaled. Two pixels per point is the most it can use.
    public static let pixelsPerPointCeiling = 2.0

    /// The representation to render: the smallest one with at least two pixels per point in both directions (a
    /// 10x-scaled arrow is not rendered at 280 x 400 when 56 x 80 is there), or the largest when none reaches it.
    /// nil when there is no usable representation. Ties go to the first.
    public static func chooseRepresentation(_ sizes: [Size], pointWidth: Double, pointHeight: Double) -> Int? {
        let usable = sizes.enumerated().filter { $0.element.width > 0 && $0.element.height > 0 }
        guard !usable.isEmpty else { return nil }
        let needW = pointWidth * pixelsPerPointCeiling, needH = pointHeight * pixelsPerPointCeiling
        let enough = usable.filter { Double($0.element.width) >= needW && Double($0.element.height) >= needH }
        if let best = enough.min(by: { $0.element.width * $0.element.height < $1.element.width * $1.element.height }) {
            return best.offset
        }
        return usable.max(by: { $0.element.width * $0.element.height < $1.element.width * $1.element.height })?.offset
    }

    /// The image size to send: the representation, shrunk (aspect kept, at least 1 px each way) until it fits
    /// `maxPixels` in both directions; never enlarged.
    public static func sentSize(of size: Size, maxPixels: Int = CursorShape.maxPixels) -> Size {
        let longest = max(size.width, size.height)
        guard longest > maxPixels else { return size }
        let scale = Double(maxPixels) / Double(longest)
        return Size(width: min(maxPixels, max(1, Int((Double(size.width) * scale).rounded()))),
                    height: min(maxPixels, max(1, Int((Double(size.height) * scale).rounded()))))
    }

    /// A smaller try when the PNG came out over `CursorShape.maxDataBytes`: 3/4 of both sides. nil below 8 px.
    public static func smaller(_ size: Size) -> Size? {
        let w = size.width * 3 / 4, h = size.height * 3 / 4
        guard w >= 8, h >= 8 else { return nil }
        return Size(width: w, height: h)
    }

    /// Points to the wire's 1/16 point, rounded and clamped to `UInt16`. Non-finite and negative values are 0.
    public static func pt16(_ points: Double) -> UInt16 {
        guard points.isFinite, points > 0 else { return 0 }
        return UInt16(min((points * 16).rounded(), Double(UInt16.max)))
    }

    /// `shape_id` of an image: the hash of its pixel bytes mixed with the wire size and hotspot, folded to 32 bits,
    /// never 0. Equal images with the same size and hotspot get the same id, so a repeat is never sent twice.
    public static func shapeID(pixelHash: UInt64, widthPt16: UInt16, heightPt16: UInt16, hotXPt16: UInt16,
                               hotYPt16: UInt16) -> UInt32 {
        var h = pixelHash
        for v in [widthPt16, heightPt16, hotXPt16, hotYPt16] {
            h = (h ^ UInt64(v)) &* 0x0000_0100_0000_01b3
            h ^= h >> 29
        }
        let id = UInt32(truncatingIfNeeded: h) ^ UInt32(truncatingIfNeeded: h >> 32)
        return id == 0 ? 1 : id
    }

    /// FNV-1a family hash, a word at a time (8x fewer multiplies than bytewise; a 280 x 400 RGBA image is 448 KB).
    /// Deterministic for the same bytes and length; not cryptographic.
    public static func pixelHash(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ UInt64(bytes.count)
        let words = bytes.count / 8
        for i in 0..<words {
            h = (h ^ bytes.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) &* 0x0000_0100_0000_01b3
            h ^= h >> 29
        }
        for i in (words * 8)..<bytes.count {
            h = (h ^ UInt64(bytes[i])) &* 0x0000_0100_0000_01b3
        }
        return h
    }
}

extension DisplayGeometry {
    /// The inverse of `point(x:y:)` (PROTOCOL.md 1) for the cursor: a position in global points to the normalized
    /// position on the video surface. A point outside the display is clamped to its nearest edge; a non-finite one maps
    /// to 0. The display's own scale does not matter (a 1x game display and the 2x virtual display map alike).
    public func normalizedPosition(of p: DisplayPoint) -> (x: UInt16, y: UInt16) {
        (NormalizedCoord.encode(px: p.x - originX, surface: widthPt),
         NormalizedCoord.encode(px: p.y - originY, surface: heightPt))
    }
}
