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

/// Whether the Mac's cursor is hidden right now (T-272): a game hides it and works from mouse deltas.
public protocol CursorVisibilityChecking: Sendable {
    /// True only when the system says the cursor is hidden. Unknown counts as visible (today's behavior).
    func isHidden() -> Bool
}

/// `CGCursorIsVisible` (public, deprecated), looked up with `dlsym` so a Mac without the symbol still builds and runs
/// (the answer is then always "visible"). T-271 recorded it flipping with the game's hide and show of the cursor;
/// a call costs a few nanoseconds, so every relative message may ask. It takes no arguments and posts nothing.
public struct SystemCursorVisibility: CursorVisibilityChecking {
    private typealias Fn = @convention(c) () -> UInt32
    private static let function: Fn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else { return nil }  // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: Fn.self)
    }()

    public init() {}

    public func isHidden() -> Bool {
        guard let function = Self.function else { return false }
        return function() == 0
    }
}
