/// Rate limit for the (expensive) cursor shape check (T-309, decision 0036). Position and visibility are read on every
/// sample; the shape (`NSCursor.currentSystem` copies the image from WindowServer, then it is rendered and hashed) is
/// looked at most once per `minIntervalNs`, so a shape change is noticed at most that much late. A check is also forced
/// when there is no shape yet or the cursor was hidden and shows again. A value type for one context.
public struct CursorShapeCheckGate: Sendable {
    /// ~17 Hz. A check happens only on a sample, so a change waits at most this plus one timer period (8.33 ms):
    /// 57 + 8.33 = 65.3 ms, inside the 70 ms the card allows.
    public static let defaultMinIntervalNs: UInt64 = 57_000_000

    public let minIntervalNs: UInt64
    private var lastCheckNs: UInt64?
    private var wasHidden = false
    public private(set) var checks = 0

    public init(minIntervalNs: UInt64 = CursorShapeCheckGate.defaultMinIntervalNs) {
        self.minIntervalNs = minIntervalNs
    }

    /// True when the shape must be read now. The first attempt is always made; later ones, including retries while no
    /// shape could be built yet (`hasShape` false), are rate limited the same way so a failing render cannot spin.
    public mutating func shouldCheck(nowNs: UInt64, hidden: Bool, hasShape: Bool) -> Bool {
        let reappeared = wasHidden && !hidden
        wasHidden = hidden
        // A hidden cursor needs no image: the last shape stays until it shows again.
        if hidden && hasShape { return false }
        if !reappeared, let last = lastCheckNs, nowNs >= last, nowNs - last < minIntervalNs { return false }
        lastCheckNs = nowNs
        checks += 1
        return true
    }

    /// Forget the timing (new session): the next sample checks.
    public mutating func reset() {
        lastCheckNs = nil
        wasHidden = false
    }
}
