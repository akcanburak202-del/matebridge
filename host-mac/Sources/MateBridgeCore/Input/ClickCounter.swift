// MARK: - Click state

/// Counts consecutive presses of the same button close in time and place (`mouseEventClickState`, PROTOCOL.md
/// section 4 POINTER_REL). The client sends only button states; double clicks are the host's to make.
public struct ClickCounter: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Maximum time between two presses that still count as a multi-click (`NSEvent.doubleClickInterval`).
        public var intervalUs: UInt64 = 500_000
        /// Maximum distance between two presses, in points. On the 12.2" virtual display one point is about 0.19 mm,
        /// so 12 pt is about 2 mm: the scatter of two finger taps meant as one double tap (pens never count clicks).
        public var distancePt: Double = 12
        public init() {}
    }

    private struct Last: Sendable {
        var button: MouseButton
        var position: DisplayPoint
        var time: UInt64
        var count: Int
    }

    public let configuration: Configuration
    private var last: Last?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The click count for a press of `button` at `position` at host time `now` (1 for a first click).
    public mutating func press(_ button: MouseButton, at position: DisplayPoint, now: UInt64) -> Int {
        var count = 1
        if let l = last, l.button == button, now >= l.time, now - l.time <= configuration.intervalUs,
           Self.distance(l.position, position) <= configuration.distancePt {
            count = l.count + 1
        }
        last = Last(button: button, position: position, time: now, count: count)
        return count
    }

    /// Forgets the click history (release-all: a press after a release never continues an old sequence).
    public mutating func reset() { last = nil }

    private static func distance(_ a: DisplayPoint, _ b: DisplayPoint) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

