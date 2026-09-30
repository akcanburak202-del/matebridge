// Which `MacEvent`s close something that was opened on the Mac, and how such an event degrades when the rich form
// cannot be built. Used by the owed-release logic (`OwedRelease`) and by the Host poster.

extension MacEvent {
    /// True for the events that release something held on the Mac: a button up, a pen up, a proximity leave and the end
    /// of a scroll gesture. These are the ones that must never be forgotten.
    public var isClosing: Bool {
        switch self {
        case .tabletProximity(_, let entering): !entering
        case .tabletPoint(let p): p.kind == .up
        case .mouse(let m): m.kind == .up
        case .scroll(let s): s.phase == .ended || s.phase == .cancelled
        case .magnify(let g): g.phase == .ended
        case .key(let k): k.kind == .keyUp || k.kind == .modifierUp
        case .capsLock: false
        }
    }

    /// The plainest event that still releases the same thing, for when the rich event cannot be built: a pen up
    /// becomes a bare left mouse up (no tablet data). Nil when there is no plainer form.
    public var plainRelease: MacEvent? {
        guard case .tabletPoint(let p) = self, p.kind == .up else { return nil }
        return .mouse(MacMouse(kind: .up, button: .left, position: p.position, deltaX: 0, deltaY: 0,
                               clickState: p.clickState, flags: p.flags))
    }

    /// The same event with its keyboard flags replaced (pointer, pen and scroll events; others are unchanged).
    func with(flags: KeyFlags) -> MacEvent {
        switch self {
        case .tabletPoint(var e): e.flags = flags; return .tabletPoint(e)
        case .mouse(var e): e.flags = flags; return .mouse(e)
        case .scroll(var e): e.flags = flags; return .scroll(e)
        case .magnify(var e): e.flags = flags; return .magnify(e)
        case .key(var k): k.flags = flags; return .key(k)
        case .tabletProximity, .capsLock: return self
        }
    }

    /// The position of an event that has one (proximity events have none).
    public var position: DisplayPoint? {
        switch self {
        case .tabletProximity, .key, .capsLock: nil
        case .tabletPoint(let p): p.position
        case .mouse(let m): m.position
        case .scroll(let s): s.position
        case .magnify(let g): g.position
        }
    }

    /// The same event at another position.
    func moved(to p: DisplayPoint) -> MacEvent {
        switch self {
        case .tabletProximity, .key, .capsLock: return self
        case .tabletPoint(var e):
            e.position = p
            return .tabletPoint(e)
        case .mouse(var e):
            e.position = p
            return .mouse(e)
        case .scroll(var e):
            e.position = p
            return .scroll(e)
        case .magnify(var e):
            e.position = p
            return .magnify(e)
        }
    }

    /// With a display: the event keeps its position if that is still on it, else it moves to the display center (a
    /// display that came back elsewhere must not receive events at old points). Without a display: unchanged.
    func placed(on geometry: DisplayGeometry?) -> MacEvent {
        guard let g = geometry, let p = position, !g.contains(p) else { return self }
        return moved(to: g.center)
    }
}
