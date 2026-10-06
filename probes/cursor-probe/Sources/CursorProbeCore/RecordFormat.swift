/// Description of one cursor image as the probe sees it (no pixel data, only what a wire message would need).
public struct ShapeInfo: Equatable, Sendable {
    /// Digest of the largest representation rendered to sRGB RGBA8 (premultiplied), see `Digest`.
    public var digest: UInt64
    /// Pixel size of the largest representation.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// NSImage size in points (the logical cursor size).
    public var pointWidth: Double
    public var pointHeight: Double
    /// Hot spot in points, origin top-left of the image (NSCursor convention).
    public var hotSpotX: Double
    public var hotSpotY: Double
    /// Representations as "WxH" pixel sizes, largest first.
    public var reps: [String]

    public init(digest: UInt64, pixelWidth: Int, pixelHeight: Int, pointWidth: Double, pointHeight: Double,
                hotSpotX: Double, hotSpotY: Double, reps: [String]) {
        self.digest = digest
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.hotSpotX = hotSpotX
        self.hotSpotY = hotSpotY
        self.reps = reps
    }

    /// Pixels per point of the largest representation (2.0 means a Retina cursor image).
    public var scale: Double { pointWidth > 0 ? Double(pixelWidth) / pointWidth : 0 }

    public var id: String { Digest.hex(digest) }

    /// File name for a PNG dump of this shape.
    public var dumpFileName: String { "cursor-\(id)-\(pixelWidth)x\(pixelHeight)-\(f(scale))x.png" }
}

/// One line of the record log. Plain `key=value` tokens. Never contains keys or text.
public enum RecordLine {
    public static func shape(t: Double, source: String, _ s: ShapeInfo) -> String {
        "\(ts(t)) shape src=\(source) id=\(s.id) px=\(s.pixelWidth)x\(s.pixelHeight) pt=\(f(s.pointWidth))x\(f(s.pointHeight))"
            + " scale=\(f(s.scale)) hot=\(f(s.hotSpotX)),\(f(s.hotSpotY)) reps=\(s.reps.joined(separator: "|"))"
    }

    public static func shapeNil(t: Double, source: String) -> String { "\(ts(t)) shape src=\(source) nil" }

    public static func visible(t: Double, source: String, _ v: Bool?) -> String {
        "\(ts(t)) visible src=\(source) value=\(v.map { $0 ? "1" : "0" } ?? "n/a")"
    }

    public static func position(t: Double, x: Double, y: Double) -> String { "\(ts(t)) pos x=\(f(x)) y=\(f(y))" }

    public static func windowCursor(t: Double, present: Bool, x: Double, y: Double, w: Double, h: Double, alpha: Double) -> String {
        present ? "\(ts(t)) cursorwindow present x=\(f(x)) y=\(f(y)) w=\(f(w)) h=\(f(h)) alpha=\(f(alpha))" : "\(ts(t)) cursorwindow absent"
    }

    /// Seconds since the start of the run with millisecond precision.
    public static func ts(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        let frac = String(ms % 1000)
        return "\(ms / 1000).\(String(repeating: "0", count: 3 - frac.count))\(frac)"
    }
}
