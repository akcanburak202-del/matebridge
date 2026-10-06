/// Reports a value only when it differs from the previous one (the first value always counts as a change).
public struct ChangeTracker<Value: Equatable> {
    public private(set) var last: Value?
    public private(set) var changes = 0

    public init() {}

    /// Returns true if `value` is new. `changes` counts every true result including the first.
    @discardableResult
    public mutating func update(_ value: Value) -> Bool {
        if let last, last == value { return false }
        last = value
        changes += 1
        return true
    }
}
