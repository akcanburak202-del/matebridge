import Foundation

/// What the clipboard bridge needs from the pasteboard; `NSPasteboard.general` in the app, a fake in tests.
public protocol PasteboardAccess: Sendable {
    var changeCount: Int { get }
    var string: String? { get }
    /// True when the current content is marked concealed, transient or auto-generated (password managers).
    var isConcealed: Bool { get }
    /// Replaces the contents with `text` and returns the new `changeCount`.
    func write(_ text: String) -> Int
}

/// Holds at most one pending value; a newer value replaces the older one. `put` says whether the caller must start a
/// drain (none is in flight); `take` returns the value and, when empty, ends the drain. Thread-safe.
public final class LatestValueSlot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var draining = false

    public init() {}

    /// Returns true when the caller has to schedule a drain.
    public func put(_ newValue: Value) -> Bool {
        lock.withLock {
            value = newValue
            if draining { return false }
            draining = true
            return true
        }
    }

    public func take() -> Value? {
        lock.withLock {
            let v = value
            value = nil
            if v == nil { draining = false }
            return v
        }
    }

    public func clear() {
        lock.withLock { value = nil }
    }
}

/// `ClipboardSync` plus the pasteboard: one consistent-snapshot poll step and the incoming write. Not thread-safe;
/// the bridge confines it to one queue.
public struct ClipboardEngine {
    public private(set) var sync: ClipboardSync
    private let pasteboard: PasteboardAccess

    public init(pasteboard: PasteboardAccess, enabled: Bool) {
        self.pasteboard = pasteboard
        self.sync = ClipboardSync(enabled: enabled)
    }

    public mutating func begin() { sync.begin(changeCount: pasteboard.changeCount) }
    public mutating func end() { sync.end() }
    public mutating func setEnabled(_ on: Bool) { sync.setEnabled(on, changeCount: pasteboard.changeCount) }

    /// One poll. The content is read as a snapshot: changeCount, then the concealment markers, then (only when not
    /// concealed) the string, then changeCount again. If it moved in between, the snapshot is discarded and the change
    /// is retried on the next poll, so a password can never be read under "not concealed" markers.
    public mutating func poll() -> ClipboardSync.Decision {
        let before = pasteboard.changeCount
        guard sync.hasChanged(changeCount: before) else { return .nothing }
        let concealed = pasteboard.isConcealed
        let text = concealed ? nil : pasteboard.string
        guard pasteboard.changeCount == before else { return .nothing }
        return sync.observe(changeCount: before, text: text, isConcealed: concealed)
    }

    /// Writes an incoming message to the pasteboard when `ClipboardSync` accepts it; returns the byte count written.
    public mutating func applyIncoming(_ clip: Clipboard) -> Int? {
        guard let text = sync.receive(clip) else { return nil }
        sync.didWrite(changeCount: pasteboard.write(text))
        return clip.data.count
    }
}
