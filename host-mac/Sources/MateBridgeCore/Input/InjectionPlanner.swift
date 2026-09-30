// MARK: - Planner

/// Turns the state machine's `InjectAction`s into resolved `MacEvent`s and keeps the injector's own view of what is
/// held on the Mac (the shadow state). The state machine decides WHAT should happen; this decides what CAN happen
/// right now and remembers what it actually posted.
///
/// - Opening actions (proximity enter, hover, down, cursor moves, button down, scroll begin, wheel) are dropped
///   unless `environment.isOpen`: no permission, or no virtual display, means no input (never on another display).
/// - Closing actions (up, leave, button up, scroll end) are produced whenever the shadow state holds the thing being
///   closed, whatever the environment says. An event that was never posted is never released, and one that was posted
///   is always released, at the last known position when the display is gone.
/// - The injector owns what the state machine does not: the last injected cursor position (a `mouseButton` applies
///   there), click counts, scroll remainders. Zero-delta `scroll(.changed)` (the client's keepalive) is never
///   injected. Scroll momentum is never generated, so none follows a forced end and none is left to stop at release-all.
public struct InjectionPlanner: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var clicks = ClickCounter.Configuration()
        public init() {}
    }

    public struct Counters: Equatable, Sendable {
        /// Events produced.
        public var events = 0
        /// Opening actions dropped because Accessibility permission is missing.
        public var droppedNoPermission = 0
        /// Opening or continuing actions dropped because the virtual display is missing.
        public var droppedNoDisplay = 0
        /// Continuing or closing actions for something the shadow state never opened (its opening was dropped).
        public var droppedNotHeld = 0
        /// Opening actions dropped because a release is owed: a newer press must not be overtaken by an older release.
        public var droppedOwed = 0
        /// Zero-delta `scroll(.changed)` keepalives (never injected).
        public var droppedKeepalive = 0
        public init() {}
    }

    public private(set) var counters = Counters()
    /// The last injected cursor position, if any.
    public private(set) var cursor: DisplayPoint?

    // Shadow state: what has been posted and not yet released.
    private var proximity: PenTool?
    private var penContact = false
    private var lastTablet: MacTabletPoint?
    /// Held mouse buttons and the click count of their down (the matching up repeats it).
    private var heldButtons: [MouseButton: Int] = [:]
    private var scrollOpen = false
    private var scrollCarryX = 0.0
    private var scrollCarryY = 0.0
    private var clicks: ClickCounter
    /// The geometry of the call in progress (nil: no display). Every cached position is resolved against it.
    private var display: DisplayGeometry?

    public init(configuration: Configuration = Configuration()) {
        clicks = ClickCounter(configuration: configuration.clicks)
    }

    /// True while anything posted to the Mac has not been released.
    public var isHoldingInput: Bool { proximity != nil || penContact || !heldButtons.isEmpty || scrollOpen }
    public var isPenInRange: Bool { proximity != nil }
    public var isPenInContact: Bool { penContact }
    public var heldMouseButtons: Set<MouseButton> { Set(heldButtons.keys) }
    public var isScrollOpen: Bool { scrollOpen }

    /// PLAN-*: plan one ordered action list. `now` is the host clock at the moment the message was received.
    public mutating func plan(_ actions: [InjectAction], environment env: InjectionEnvironment,
                              now: UInt64) -> [MacEvent] {
        display = env.geometry
        var out: [MacEvent] = []
        for action in actions { apply(action, env, now, &out) }
        counters.events += out.count
        return out
    }

    /// Releases everything the shadow state holds, in the state machine's order (pen up, left button, pen leave,
    /// other buttons, scroll end). Releasing is never gated; the environment only says where the cached positions are
    /// still valid (see `resolved`). Idempotent. This is the safety net under the state machine's own release-all.
    public mutating func releaseAll(environment env: InjectionEnvironment) -> [MacEvent] {
        display = env.geometry
        var out: [MacEvent] = []
        if penContact { releasePenContact(&out) }
        if let cs = heldButtons.removeValue(forKey: .left) { emitButtonUp(.left, cs, &out) }
        if proximity != nil { closePen(&out) }
        for button in MouseButton.allCases where button != .left {
            if let cs = heldButtons.removeValue(forKey: button) { emitButtonUp(button, cs, &out) }
        }
        if scrollOpen { closeScroll(.ended, dx: 0, dy: 0, &out) }
        clicks.reset()
        counters.events += out.count
        return out
    }

    /// These events were produced but could not be posted. Undo what the OPENING ones would have opened in the shadow
    /// state, so it keeps following what really is on the Mac (the machine may still believe a pen contact or a
    /// press exists; the planner then drops the rest of that stroke or press). Closing events are not touched: they
    /// are owed (`OwedRelease`), and the shadow state has released them already.
    public mutating func notPosted(_ events: [MacEvent]) {
        for event in events {
            switch event {
            case .tabletProximity(let tool, let entering):
                if entering, proximity == tool {
                    proximity = nil
                    penContact = false
                }
            case .tabletPoint(let p):
                if p.kind == .down { penContact = false }
            case .mouse(let m):
                if m.kind == .down { heldButtons[m.button] = nil }
            case .scroll(let s):
                if s.phase == .began {
                    scrollOpen = false
                    scrollCarryX = 0
                    scrollCarryY = 0
                }
            }
        }
    }

    // MARK: Actions

    private mutating func apply(_ action: InjectAction, _ env: InjectionEnvironment, _ now: UInt64,
                                _ out: inout [MacEvent]) {
        switch action {
        case .penProximity(let tool, let entering):
            if entering {
                guard openGate(env) != nil else { return }
                enterProximity(tool, &out)
            } else {
                if proximity == nil { counters.droppedNotHeld += 1 } else { closePen(&out) }
            }

        case .penHover(let tool, let p):
            guard let g = openGate(env) else { return }
            enterProximity(tool, &out)
            guard !penContact else { counters.droppedNotHeld += 1; return }
            let e = tablet(.hover, tool, g.point(p), p, clickState: 0)
            cursor = e.position
            lastTablet = e
            out.append(.tabletPoint(e))

        case .penDown(let tool, let p):
            guard let g = openGate(env) else { return }
            enterProximity(tool, &out)
            guard !penContact else { counters.droppedNotHeld += 1; return }
            let e = tablet(.down, tool, g.point(p), p, clickState: 1)
            cursor = e.position
            lastTablet = e
            penContact = true
            out.append(.tabletPoint(e))

        case .penDrag(_, let p):
            // Continues a stroke that was posted; needs a position and permission, not "new input" checks.
            guard penContact, let active = proximity else { counters.droppedNotHeld += 1; return }
            guard env.canInject else { counters.droppedNoPermission += 1; return }
            guard let g = env.geometry else { counters.droppedNoDisplay += 1; return }
            let e = tablet(.drag, active, g.point(p), p, clickState: 0)
            cursor = e.position
            lastTablet = e
            out.append(.tabletPoint(e))

        case .penUp(_, let p):
            guard penContact, let active = proximity else { counters.droppedNotHeld += 1; return }
            // Closing: never gated. Without a display the pen lifts where it last was.
            let position = env.geometry.map { $0.point(p) } ?? resolved(lastTablet?.position ?? cursor)
            let e = tablet(.up, active, position, p.withPressure(0), clickState: 1)
            cursor = e.position
            lastTablet = e
            penContact = false
            out.append(.tabletPoint(e))

        case .mouseMove(let motion, let dragging):
            guard let g = openGate(env) else { return }
            let target: DisplayPoint
            var delta = DisplayPoint.zero
            switch motion {
            case .absolute(let x, let y):
                target = g.point(x: x, y: y)
                if let c = validCursor { delta = DisplayPoint(x: target.x - c.x, y: target.y - c.y) }
            case .relative(let dx, let dy):
                // A relative move needs a starting point; before any injected position that is the display center.
                let base = validCursor ?? g.center
                target = g.moved(base, dx: Double(dx), dy: Double(dy))
                delta = DisplayPoint(x: target.x - base.x, y: target.y - base.y)
            }
            // A drag only if that button's down was really posted; otherwise it is a plain move.
            let held = dragging.flatMap { heldButtons[$0] != nil ? $0 : nil }
            out.append(.mouse(MacMouse(kind: held == nil ? .moved : .dragged, button: held ?? .left, position: target,
                                       deltaX: delta.x, deltaY: delta.y, clickState: 0)))
            cursor = target

        case .mouseButton(let button, let down):
            if down {
                guard let g = openGate(env) else { return }
                guard heldButtons[button] == nil else { counters.droppedNotHeld += 1; return }
                let position = validCursor ?? g.center
                cursor = position
                let count = clicks.press(button, at: position, now: now)
                heldButtons[button] = count
                out.append(.mouse(MacMouse(kind: .down, button: button, position: position, deltaX: 0, deltaY: 0,
                                           clickState: count)))
            } else if let count = heldButtons.removeValue(forKey: button) {
                emitButtonUp(button, count, &out)
            } else {
                counters.droppedNotHeld += 1
            }

        case .scroll(let phase, let dx, let dy):
            applyScroll(phase, dx, dy, env, &out)

        case .scrollWheel(let dx, let dy):
            guard openGate(env) != nil else { return }
            let px = Self.pixels(Double(dx)), py = Self.pixels(Double(dy))
            if px != 0 || py != 0 {
                let position = resolved(cursor)
                cursor = position
                out.append(.scroll(MacScroll(phase: .none, dx: px, dy: py, position: position)))
            }
        }
    }

    private mutating func applyScroll(_ phase: InjectScrollPhase, _ dx: Float, _ dy: Float, _ env: InjectionEnvironment,
                                      _ out: inout [MacEvent]) {
        switch phase {
        case .began:
            guard openGate(env) != nil else { return }
            if scrollOpen { closeScroll(.ended, dx: 0, dy: 0, &out) }
            scrollOpen = true
            scrollCarryX = 0
            scrollCarryY = 0
            let (px, py) = takePixels(Double(dx), Double(dy))
            let position = resolved(cursor)
            cursor = position
            out.append(.scroll(MacScroll(phase: .began, dx: px, dy: py, position: position)))

        case .changed:
            guard scrollOpen else { counters.droppedNotHeld += 1; return }
            // The client's keepalive carries no movement and must not reach the Mac.
            guard dx != 0 || dy != 0 else { counters.droppedKeepalive += 1; return }
            guard env.canInject else { counters.droppedNoPermission += 1; return }
            guard env.geometry != nil else { counters.droppedNoDisplay += 1; return }
            let (px, py) = takePixels(Double(dx), Double(dy))
            if px != 0 || py != 0 {
                let position = resolved(cursor)
                cursor = position
                out.append(.scroll(MacScroll(phase: .changed, dx: px, dy: py, position: position)))
            }

        case .ended, .cancelled:
            guard scrollOpen else { counters.droppedNotHeld += 1; return }
            // Closing is never gated, but the final movement is only injected while input is allowed.
            let (px, py) = env.isOpen ? takePixels(Double(dx), Double(dy)) : (0, 0)
            closeScroll(phase == .ended ? .ended : .cancelled, dx: px, dy: py, &out)

        case .forcedEnd:
            guard scrollOpen else { counters.droppedNotHeld += 1; return }
            // The Mac sees a normal ENDED with no movement; no momentum follows (none is ever generated).
            closeScroll(.ended, dx: 0, dy: 0, &out)
        }
    }

    // MARK: Helpers

    /// nil (and a counted drop) unless new input is allowed.
    private mutating func openGate(_ env: InjectionEnvironment) -> DisplayGeometry? {
        guard env.canInject else { counters.droppedNoPermission += 1; return nil }
        guard let g = env.geometry else { counters.droppedNoDisplay += 1; return nil }
        guard !env.opensBlocked else { counters.droppedOwed += 1; return nil }
        return g
    }

    /// Makes `tool` the tool in range: a different tool in range is closed first (up, leave), then enter.
    private mutating func enterProximity(_ tool: PenTool, _ out: inout [MacEvent]) {
        if proximity == tool { return }
        if proximity != nil { closePen(&out) }
        out.append(.tabletProximity(tool: tool, entering: true))
        proximity = tool
    }

    /// Up (if touching) at the last pen position, then leave.
    private mutating func closePen(_ out: inout [MacEvent]) {
        guard let tool = proximity else { return }
        if penContact { releasePenContact(&out) }
        out.append(.tabletProximity(tool: tool, entering: false))
        proximity = nil
    }

    private mutating func releasePenContact(_ out: inout [MacEvent]) {
        guard penContact, let tool = proximity else { return }
        let last = lastTablet
        let e = MacTabletPoint(kind: .up, tool: tool, position: resolved(last?.position ?? cursor), pressure: 0,
                               tiltX: last?.tiltX ?? 0, tiltY: last?.tiltY ?? 0, clickState: 1)
        lastTablet = e
        penContact = false
        out.append(.tabletPoint(e))
    }

    private func emitButtonUp(_ button: MouseButton, _ clickState: Int, _ out: inout [MacEvent]) {
        out.append(.mouse(MacMouse(kind: .up, button: button, position: resolved(cursor), deltaX: 0, deltaY: 0,
                                   clickState: clickState)))
    }

    private mutating func closeScroll(_ phase: MacScroll.Phase, dx: Int32, dy: Int32, _ out: inout [MacEvent]) {
        scrollOpen = false
        scrollCarryX = 0
        scrollCarryY = 0
        out.append(.scroll(MacScroll(phase: phase, dx: dx, dy: dy, position: resolved(cursor))))
    }

    /// The cached cursor if it is still on the display of this call.
    private var validCursor: DisplayPoint? {
        guard let c = cursor, let g = display, g.contains(c) else { return nil }
        return c
    }

    /// Where a cached position (last cursor, last pen point) is used now. With a display it is that position if it
    /// still lies on it, otherwise the display center: a display that came back at another origin or size must never
    /// receive a click at the old point, which could be on a physical monitor. Without a display (closing events only)
    /// it is the last known position, or the origin as a last resort that a closing event never actually reaches.
    private func resolved(_ p: DisplayPoint?) -> DisplayPoint {
        guard let g = display else { return p ?? .zero }
        if let p, g.contains(p) { return p }
        return g.center
    }

    private func tablet(_ kind: MacTabletPoint.Kind, _ tool: PenTool, _ position: DisplayPoint, _ p: PenPoint,
                        clickState: Int) -> MacTabletPoint {
        MacTabletPoint(kind: kind, tool: tool, position: position, pressure: p.pressureUnit, tiltX: p.tiltXUnit,
                       tiltY: p.tiltYUnit, clickState: clickState)
    }

    /// Whole pixels of a movement, carrying the fraction over to the next call so slow scrolling is not lost.
    private mutating func takePixels(_ dx: Double, _ dy: Double) -> (Int32, Int32) {
        let tx = scrollCarryX + dx, ty = scrollCarryY + dy
        let px = Self.pixels(tx, rounding: .towardZero), py = Self.pixels(ty, rounding: .towardZero)
        scrollCarryX = tx - Double(px)
        scrollCarryY = ty - Double(py)
        return (px, py)
    }

    private static func pixels(_ v: Double, rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> Int32 {
        guard v.isFinite else { return 0 }
        return Int32(Swift.min(Swift.max(v.rounded(rounding), Double(Int32.min)), Double(Int32.max)))
    }
}

