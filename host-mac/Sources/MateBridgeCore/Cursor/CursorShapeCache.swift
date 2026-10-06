/// The shape ids the host assumes the tablet has (PROTOCOL.md 0x0C): at most `capacity` (32), least recently used
/// first out. A use is a `CURSOR_SHAPE` or a `CURSOR_STATE` that names the id. The tablet keeps at least twice as many,
/// so everything in here is on the tablet. Cleared with the session, and whenever the tablet turns the flow off (it may
/// drop its images then).
public struct CursorShapeCache: Sendable {
    public static let defaultCapacity = 32

    public let capacity: Int
    /// Oldest use first.
    private var ids: [UInt32] = []

    public init(capacity: Int = CursorShapeCache.defaultCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { ids.count }
    public func contains(_ id: UInt32) -> Bool { ids.contains(id) }

    /// Records a use of `id`. Returns true when the tablet already has it (nothing to send); false when the shape has
    /// to go out first (it is now assumed present: call this only when the unit is really about to be written).
    /// `0` is the built-in arrow: never sent, always "present".
    public mutating func use(_ id: UInt32) -> Bool {
        guard id != 0 else { return true }
        if let i = ids.firstIndex(of: id) {
            ids.remove(at: i)
            ids.append(id)
            return true
        }
        ids.append(id)
        if ids.count > capacity { ids.removeFirst() }
        return false
    }

    /// The tablet is not assumed to have `id` after all (the image could not be sent).
    public mutating func forget(_ id: UInt32) { ids.removeAll { $0 == id } }

    public mutating func removeAll() { ids.removeAll() }
}

/// The encoded shapes the host holds for sending: at most `capacity` (48, more than the 32 the tablet is assumed to
/// hold), the least recently used pushed out first. Written by the tracker when it builds a shape and read when the unit that needs it is
/// written; the owner holds a lock around it.
public struct CursorShapeStore: Sendable {
    public static let defaultCapacity = 48

    public let capacity: Int
    private var shapes: [UInt32: CursorShape] = [:]
    /// Oldest use first.
    private var order: [UInt32] = []

    public init(capacity: Int = CursorShapeStore.defaultCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { shapes.count }

    public mutating func put(_ shape: CursorShape) {
        order.removeAll { $0 == shape.shapeID }
        order.append(shape.shapeID)
        shapes[shape.shapeID] = shape
        while order.count > capacity { shapes[order.removeFirst()] = nil }
    }

    /// The shape, counted as used. nil when it was never stored or has been pushed out.
    public mutating func use(_ id: UInt32) -> CursorShape? {
        guard let shape = shapes[id] else { return nil }
        if let i = order.firstIndex(of: id) {
            order.remove(at: i)
            order.append(id)
        }
        return shape
    }

    public func contains(_ id: UInt32) -> Bool { shapes[id] != nil }

    public mutating func removeAll() {
        shapes.removeAll()
        order.removeAll()
    }
}

/// The host side of "at most one cursor unit waiting" (PROTOCOL.md section 5): a unit (a state and, if needed, its
/// shape) is written only after the previous one was entirely written to the socket; a newer unit replaces the one
/// that waits (which is never written, and so never counted as present on the tablet).
///
/// Not thread safe: the owner holds a lock around it. `generation` changes on `reset()`, so the completion of a unit
/// of an ended session cannot release the next session's.
public struct CursorOutbox<Unit: Sendable>: Sendable {
    private var pending: Unit?
    private var inFlight = false
    private var kickScheduled = false
    /// Units that were replaced before they were written.
    public private(set) var replaced = 0
    public private(set) var generation = 0

    public init() {}

    public var hasPending: Bool { pending != nil }
    public var isWriting: Bool { inFlight }

    /// A new unit. Returns true when the caller must schedule one `take()` pass on the writer's queue (nothing is being
    /// written and no pass is scheduled yet).
    public mutating func submit(_ unit: Unit) -> Bool {
        if pending != nil { replaced += 1 }
        pending = unit
        guard !inFlight, !kickScheduled else { return false }
        kickScheduled = true
        return true
    }

    /// The unit to write now, if nothing is being written. Marks it as being written.
    public mutating func take() -> Unit? {
        kickScheduled = false
        guard !inFlight, let unit = pending else { return nil }
        pending = nil
        inFlight = true
        return unit
    }

    /// The unit taken last was entirely written (or the write failed). A stale generation is ignored. The caller then
    /// calls `take()` again.
    public mutating func completed(generation: Int) {
        guard generation == self.generation else { return }
        inFlight = false
    }

    /// Drops the waiting unit only (the flow stopped; the one being written finishes).
    public mutating func discardPending() { pending = nil }

    /// Session over: drops the waiting unit and forgets the one being written.
    public mutating func reset() {
        pending = nil
        inFlight = false
        kickScheduled = false
        generation += 1
    }
}
