import CoreGraphics
import MateBridgeCore

/// Where the Mac's cursor really is right now (T-103), in global points with the origin at the top left of the main
/// display: the same space as `DisplayGeometry`. nil when the system cannot say.
public protocol CursorLocating: Sendable {
    func location() -> DisplayPoint?
}

/// The live cursor through `CGEvent(source: nil).location` (a null-source event carries the current cursor position;
/// nothing is posted). Measured on the M6 Mac mini (macOS 27, 20 000 calls): p50 about 0.1 µs, p99 about 0.15 µs. The
/// very first call in a process costs about 8 to 14 ms (it connects to WindowServer), which is why `InputController`
/// warms it up in `start()`. `NSEvent.mouseLocation` costs about the same but is in flipped Cocoa coordinates.
public struct SystemCursor: CursorLocating {
    public init() {}

    public func location() -> DisplayPoint? {
        guard let p = CGEvent(source: nil)?.location, p.x.isFinite, p.y.isFinite else { return nil }
        return DisplayPoint(x: Double(p.x), y: Double(p.y))
    }
}
