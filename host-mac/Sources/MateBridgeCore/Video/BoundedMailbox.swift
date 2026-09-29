import Foundation

/// Bounded, ordered event mailbox with one consumer.
///
/// - Events posted with a `coalesceKey` replace a pending event with the same key (latest wins, position kept),
///   so periodic events (STATS, keyframe requests, ticks) can never pile up.
/// - Events without a key are lifecycle events: at most `capacity` may be pending. Beyond that `post` returns
///   `.overflow` and nothing is stored; the owner reacts (e.g. ends the session) instead of growing.
/// - `forced` events bypass the capacity (used for shutdown only).
public final class BoundedMailbox<Event: Sendable>: @unchecked Sendable {
    public enum PostResult: Equatable, Sendable { case queued, overflow }

    private struct Entry { var event: Event; var key: Int? }

    public let capacity: Int
    /// Wakes the consumer; buffers at most one wake-up.
    public let wake: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var entries: [Entry] = []

    public init(capacity: Int = 16) {
        self.capacity = capacity
        (wake, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    @discardableResult
    public func post(_ event: Event, coalesceKey: Int? = nil, forced: Bool = false) -> PostResult {
        let result: PostResult = lock.withLock {
            if let key = coalesceKey, let i = entries.firstIndex(where: { $0.key == key }) {
                entries[i].event = event
                return .queued
            }
            if coalesceKey == nil, !forced, entries.filter({ $0.key == nil }).count >= capacity {
                return .overflow
            }
            entries.append(Entry(event: event, key: coalesceKey))
            return .queued
        }
        if result == .queued { signal.yield() }
        return result
    }

    /// Oldest pending event, or nil.
    public func take() -> Event? {
        lock.withLock { entries.isEmpty ? nil : entries.removeFirst().event }
    }

    /// Removes and returns every pending event (overflow cleanup).
    public func removeAll() -> [Event] {
        lock.withLock {
            defer { entries.removeAll() }
            return entries.map(\.event)
        }
    }

    public var count: Int { lock.withLock { entries.count } }

    public func finish() { signal.finish() }
}
