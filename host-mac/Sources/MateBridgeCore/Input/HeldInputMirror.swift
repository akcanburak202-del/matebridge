/// What is currently held on the Mac, as seen from the events that were really posted (T-325 review round 2).
///
/// It is the input of the emergency release: if the input queue is wedged, the stall restart cannot ask the pipeline
/// what is held, so it reads this mirror instead and posts the matching closing events itself. Pure value type; the
/// host keeps one under a lock and updates it right after every successful post.
public struct HeldInputMirror: Equatable, Sendable {
    /// Non-modifier keys currently down.
    public private(set) var keys: [UInt16] = []
    /// Modifier keys (`flagsChanged` keycodes) currently down.
    public private(set) var modifiers: [UInt16] = []
    public private(set) var buttons: [MouseButton] = []
    /// Where the last pointer event of the held buttons was.
    public private(set) var pointer = DisplayPoint(x: 0, y: 0)
    /// The pen touches the surface (a tablet-point down or drag without its up).
    public private(set) var penContact: PenTool?
    /// The pen is in proximity (entered without leaving).
    public private(set) var penProximity: PenTool?
    public private(set) var penPosition = DisplayPoint(x: 0, y: 0)
    public private(set) var scrollOpen = false
    public private(set) var magnifyOpen = false
    private var gesturePosition = DisplayPoint(x: 0, y: 0)

    public init() {}

    public var isEmpty: Bool {
        keys.isEmpty && modifiers.isEmpty && buttons.isEmpty && penContact == nil && penProximity == nil
            && !scrollOpen && !magnifyOpen
    }

    /// Records one event that reached the Mac.
    public mutating func posted(_ event: MacEvent) {
        switch event {
        case .key(let k):
            switch k.kind {
            case .keyDown: if !keys.contains(k.keyCode) { keys.append(k.keyCode) }
            case .keyUp: keys.removeAll { $0 == k.keyCode }
            case .modifierDown: if !modifiers.contains(k.keyCode) { modifiers.append(k.keyCode) }
            case .modifierUp: modifiers.removeAll { $0 == k.keyCode }
            }
        case .mouse(let m):
            pointer = m.position
            switch m.kind {
            case .down: if !buttons.contains(m.button) { buttons.append(m.button) }
            case .up: buttons.removeAll { $0 == m.button }
            case .moved, .dragged: break
            }
        case .tabletProximity(let tool, let entering):
            penProximity = entering ? tool : nil
            if !entering { penContact = nil }
        case .tabletPoint(let p):
            penPosition = p.position
            switch p.kind {
            case .down, .drag: penContact = p.tool
            case .up: penContact = nil
            case .hover: break
            }
        case .scroll(let s):
            gesturePosition = s.position
            switch s.phase {
            case .began, .changed: scrollOpen = true
            case .ended, .cancelled: scrollOpen = false
            case .none: break
            }
        case .magnify(let g):
            gesturePosition = g.position
            magnifyOpen = g.phase != .ended
        case .capsLock:
            break
        }
    }

    /// Records the events of a batch that the poster accepted. The poster returns the failed event and everything after
    /// it, so the accepted part is the prefix.
    public mutating func postedBatch(_ events: [MacEvent], failedCount: Int) {
        for e in events.prefix(max(0, events.count - failedCount)) { posted(e) }
    }

    /// The closing events that release everything held, in a safe order: pen up with zero pressure, then pen leave,
    /// mouse ups, scroll and magnify ends, key-ups, and last the modifiers (flags cleared). Empty when nothing is held.
    public func emergencyRelease() -> [MacEvent] {
        var out: [MacEvent] = []
        if let tool = penContact {
            out.append(.tabletPoint(MacTabletPoint(kind: .up, tool: tool, position: penPosition, pressure: 0,
                                                   tiltX: 0, tiltY: 0, clickState: 1)))
        }
        if let tool = penProximity ?? penContact { out.append(.tabletProximity(tool: tool, entering: false)) }
        for b in buttons {
            out.append(.mouse(MacMouse(kind: .up, button: b, position: pointer, deltaX: 0, deltaY: 0, clickState: 1)))
        }
        if scrollOpen { out.append(.scroll(MacScroll(phase: .ended, dx: 0, dy: 0, position: gesturePosition))) }
        if magnifyOpen { out.append(.magnify(MacMagnify(phase: .ended, value: 0, position: gesturePosition))) }
        for k in keys { out.append(.key(MacKey(kind: .keyUp, keyCode: k, flags: []))) }
        for m in modifiers { out.append(.key(MacKey(kind: .modifierUp, keyCode: m, flags: []))) }
        return out
    }
}
