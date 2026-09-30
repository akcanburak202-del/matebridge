/// The tablet panel rate last reported by `DISPLAY_RATE` and what it means for the encoder feed (T-058).
///
/// The target encode rate is `min(stream fps, hz)`. `hz` 0 (unknown) or at/above the stream fps means the stream
/// fps, so a session that never sends the message behaves as before. Implausibly low values are clamped so a
/// garbled report cannot starve the stream.
public struct DisplayRateState: Equatable, Sendable {
    public static let minimumFps = 24

    /// Last reported value, 0 = none/unknown.
    public private(set) var hz = 0

    public init() {}

    public static func effectiveFps(streamFps: Int, hz: Int) -> Int {
        guard hz > 0, hz < streamFps else { return streamFps }
        return max(min(streamFps, minimumFps), hz)
    }

    public func effectiveFps(streamFps: Int) -> Int { Self.effectiveFps(streamFps: streamFps, hz: hz) }

    /// Stores the report; true when it differs from the previous one (the caller logs only then).
    @discardableResult
    public mutating func update(hz newHz: UInt16) -> Bool {
        defer { hz = Int(newHz) }
        return hz != Int(newHz)
    }

    public mutating func reset() { hz = 0 }
}
