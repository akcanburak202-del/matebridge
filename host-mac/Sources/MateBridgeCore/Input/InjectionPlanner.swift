// MARK: - Planner

/// Turns the state machine's `InjectAction`s into resolved `MacEvent`s and keeps the injector's own view of what is
/// held on the Mac (the shadow state). The state machine decides WHAT should happen; this decides what CAN happen
/// right now and remembers what it actually posted.
///
/// - Opening actions (proximity enter, hover, down, cursor moves, button down, scroll begin, wheel) are dropped
///   unless `environment.isOpen`: no permission, or no virtual display, means no input (never on another display).
/// - Closing actions (up, leave, button up, scroll end, magnify end) are produced whenever the shadow state holds the thing being
///   closed, whatever the environment says. An event that was never posted is never released, and one that was posted
///   is always released, at the last known position when the display is gone.
/// - The injector owns what the state machine does not: the last injected cursor position (a `mouseButton` applies
///   there), click counts, scroll and relative-move remainders. Zero-delta `scroll(.changed)` (the client's
///   keepalive) is never injected. Scroll momentum is never generated, so none follows a forced end and none is left
///   to stop at release-all.
/// - Relative pointer moves (T-103) start at the LIVE cursor when the Host sampled it (`environment.cursor`) and it is
///   on the virtual display: games warp the cursor or detach it, and a model of our own drifts into invisible walls.
///   Their `deltaX/Y` is the client's raw movement (never clamped); the position is still clamped to the display.
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
        /// Zero-delta `scroll(.changed)` and `pinch(.changed)` keepalives (never injected).
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
    private var magnifyOpen = false
    /// Keys and modifiers posted and not yet released, in press order. The flags of every keyboard event come from
    /// `heldModifiers`, so a modifier that was dropped at the gate never shows up in a later key's flags.
    private var heldKeys: [UInt16] = []
    private var heldModifiers: [ModifierKey] = []
    /// The Caps Lock state the planner last knew the Mac to have (sampled, or set by a `.capsLock` event it produced).
    private var capsLockOn = false
    private var scrollCarryX = 0.0
    private var scrollCarryY = 0.0
    /// Fractions of relative movement not yet reported in the whole-point `deltaX/Y`.
    private var relCarryX = 0.0
    private var relCarryY = 0.0
    private var clicks: ClickCounter
    /// The geometry of the call in progress (nil: no display). Every cached position is resolved against it.
    private var display: DisplayGeometry?

    public init(configuration: Configuration = Configuration()) {
        clicks = ClickCounter(configuration: configuration.clicks)
    }

    /// True while anything posted to the Mac has not been released.
    public var isHoldingInput: Bool {
        proximity != nil || penContact || !heldButtons.isEmpty || scrollOpen || magnifyOpen || !heldKeys.isEmpty || !heldModifiers.isEmpty
    }
    public var isPenInRange: Bool { proximity != nil }
    public var isPenInContact: Bool { penContact }
    public var heldMouseButtons: Set<MouseButton> { Set(heldButtons.keys) }
    public var isScrollOpen: Bool { scrollOpen }
    public var isMagnifyOpen: Bool { magnifyOpen }
    public var heldKeyCodes: [UInt16] { heldKeys }
    public var heldModifierKeys: [ModifierKey] { heldModifiers }

    /// PLAN-*: plan one ordered action list. `now` is the host clock at the moment the message was received.
    public mutating func plan(_ actions: [InjectAction], environment env: InjectionEnvironment,
                              now: UInt64) -> [MacEvent] {
        display = env.geometry
        adoptLiveCursor(env)
        var out: [MacEvent] = []
        for action in actions {
            let start = out.count
            apply(action, env, now, &out)
            stampFlags(&out, from: start)
        }
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
        if magnifyOpen { closeMagnify(&out) }
        stampFlags(&out, from: 0)
        // Keys last pressed first, then modifiers (each up carries the flags that remain).
        while let code = heldKeys.popLast() { out.append(.key(MacKey(kind: .keyUp, keyCode: code, flags: currentFlags))) }
        while let m = heldModifiers.popLast() {
            out.append(.key(MacKey(kind: .modifierUp, keyCode: m.keyCode, flags: currentFlags)))
        }
        clicks.reset()
        relCarryX = 0
        relCarryY = 0
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
            case .magnify(let g):
                if g.phase == .began { magnifyOpen = false }
            case .key(let k):
                // A repeat does not open anything: its key stays down.
                if k.kind == .keyDown, !k.isRepeat { heldKeys.removeAll { $0 == k.keyCode } }
                if k.kind == .modifierDown { heldModifiers.removeAll { $0.keyCode == k.keyCode } }
            case .capsLock:
                break
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
                // Starts at the live cursor (adopted in `plan`), else the last known position, else the display
                // center. The position is clamped; the delta is the raw movement, so there is no wall at the edge.
                let fx = dx.isFinite ? Double(dx) : 0, fy = dy.isFinite ? Double(dy) : 0
                let base = validCursor ?? g.center
                target = g.moved(base, dx: fx, dy: fy)
                delta = takeRelativeDelta(fx, fy)
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

        case .pinch(let phase, let scale, let center):
            applyPinch(phase, scale, center, env, &out)

        case .keyDown(let code, let autorepeat):
            if autorepeat {
                // Continues a key that was posted; needs permission and a display, not "new input" checks.
                guard heldKeys.contains(code) else { counters.droppedNotHeld += 1; return }
                guard env.canInject else { counters.droppedNoPermission += 1; return }
                guard env.geometry != nil else { counters.droppedNoDisplay += 1; return }
                out.append(.key(MacKey(kind: .keyDown, keyCode: code, flags: currentFlags, isRepeat: true)))
            } else {
                guard openGate(env) != nil else { return }
                guard !heldKeys.contains(code) else { counters.droppedNotHeld += 1; return }
                heldKeys.append(code)
                out.append(.key(MacKey(kind: .keyDown, keyCode: code, flags: currentFlags)))
            }

        case .keyUp(let code):
            // Closing: never gated.
            guard let index = heldKeys.firstIndex(of: code) else { counters.droppedNotHeld += 1; return }
            heldKeys.remove(at: index)
            out.append(.key(MacKey(kind: .keyUp, keyCode: code, flags: currentFlags)))

        case .modifierDown(let m):
            guard openGate(env) != nil else { return }
            guard !heldModifiers.contains(m) else { counters.droppedNotHeld += 1; return }
            heldModifiers.append(m)
            out.append(.key(MacKey(kind: .modifierDown, keyCode: m.keyCode, flags: currentFlags)))

        case .modifierUp(let m):
            guard let index = heldModifiers.firstIndex(of: m) else { counters.droppedNotHeld += 1; return }
            heldModifiers.remove(at: index)
            out.append(.key(MacKey(kind: .modifierUp, keyCode: m.keyCode, flags: currentFlags)))

        case .setCapsLock(let on):
            // Compared with the Mac's own state when the Host sampled it; without a sample nothing is known to differ.
            guard let mac = env.capsLockOn else { return }
            capsLockOn = mac
            guard mac != on else { return }
            guard openGate(env) != nil else { return }
            capsLockOn = on
            out.append(.capsLock(on: on))

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

    /// Magnify gesture (decision 0009). Opening needs the gate; changes need permission and a display; the end is
    /// never gated and is always produced while the shadow state holds an open gesture.
    private mutating func applyPinch(_ phase: InjectPinchPhase, _ scale: Float, _ center: PinchCenter?,
                                     _ env: InjectionEnvironment, _ out: inout [MacEvent]) {
        switch phase {
        case .began:
            guard let g = openGate(env) else { return }
            if magnifyOpen { closeMagnify(&out) }
            if let center {
                // A touchscreen pinch is applied at the cursor by the apps: move the cursor to the finger center first
                // (a plain move, no drag: no button is held, the machine ignores a BEGAN while the left one is).
                let target = g.point(x: center.x, y: center.y)
                var delta = DisplayPoint.zero
                if let c = validCursor { delta = DisplayPoint(x: target.x - c.x, y: target.y - c.y) }
                out.append(.mouse(MacMouse(kind: .moved, button: .left, position: target, deltaX: delta.x,
                                           deltaY: delta.y, clickState: 0)))
                cursor = target
            }
            magnifyOpen = true
            let position = resolved(cursor)
            cursor = position
            out.append(.magnify(MacMagnify(phase: .began, value: 0, position: position)))

        case .changed:
            guard magnifyOpen else { counters.droppedNotHeld += 1; return }
            // The client's keepalive carries no change and must not reach the Mac.
            guard scale != 0 else { counters.droppedKeepalive += 1; return }
            guard env.canInject else { counters.droppedNoPermission += 1; return }
            guard env.geometry != nil else { counters.droppedNoDisplay += 1; return }
            out.append(.magnify(MacMagnify(phase: .changed, value: Self.magnification(scale), position: resolved(cursor))))

        case .ended, .cancelled, .forcedEnd:
            guard magnifyOpen else { counters.droppedNotHeld += 1; return }
            closeMagnify(&out)
        }
    }

    private mutating func closeMagnify(_ out: inout [MacEvent]) {
        magnifyOpen = false
        out.append(.magnify(MacMagnify(phase: .ended, value: 0, position: resolved(cursor))))
    }

    /// The per-message range of PROTOCOL.md section 4 PINCH, enforced here too: a bad client cannot zoom absurdly.
    static func magnification(_ scale: Float) -> Double {
        guard scale.isFinite else { return 0 }
        return Swift.min(Swift.max(Double(scale), -0.5), 1.0)
    }

    // MARK: Helpers

    /// The one rule for keyboard modifiers on pointer, pen and scroll events: every such event carries the flags
    /// current when it is emitted (an explicit value, so the Mac's own keyboard state never leaks in). Key events are
    /// built with their own flags and left alone.
    private func stampFlags(_ out: inout [MacEvent], from start: Int) {
        let flags = currentFlags
        for i in start..<out.count {
            switch out[i] {
            case .tabletPoint, .mouse, .scroll, .magnify: out[i] = out[i].with(flags: flags)
            case .key, .tabletProximity, .capsLock: break
            }
        }
    }

    /// What the planner holds of the keyboard right now, for flags of replayed releases (`OwedRelease.replay`).
    public var keyboardSnapshot: KeyboardSnapshot { KeyboardSnapshot(modifiers: Set(heldModifiers), capsLock: capsLockOn) }

    /// Modifier flags of everything held right now, plus Caps Lock when the Mac has it on (an explicit `flags` on a
    /// CGEvent replaces the system's, which would otherwise lose the Caps Lock bit and type lowercase).
    private var currentFlags: KeyFlags {
        var flags = KeyFlags(holding: heldModifiers)
        if capsLockOn { flags.insert(.capsLock) }
        return flags
    }

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

    /// T-103: the Host's live cursor sample becomes the cached cursor when it is on the virtual display and more than a
    /// point away from it on either axis (the system may round the cursor; a closer sample is the position we put there,
    /// whose fraction is kept). A sample on another display is ignored: input never lands there, so relative movement
    /// goes on from the last known position on the virtual display (the cursor comes back to it, as before T-103).
    private mutating func adoptLiveCursor(_ env: InjectionEnvironment) {
        guard let sample = env.cursor, let g = display, let live = g.onDisplay(sample) else { return }
        if let c = cursor, g.contains(c), abs(c.x - live.x) < 1, abs(c.y - live.y) < 1 { return }
        cursor = live
    }

    /// Whole points of a relative move for `deltaX/Y`, truncated toward zero; the remainder (always within (-1, 1))
    /// is carried to the next move so slow movement is not lost.
    private mutating func takeRelativeDelta(_ dx: Double, _ dy: Double) -> DisplayPoint {
        let tx = relCarryX + dx, ty = relCarryY + dy
        let wx = tx.rounded(.towardZero), wy = ty.rounded(.towardZero)
        relCarryX = tx - wx
        relCarryY = ty - wy
        return DisplayPoint(x: Double(Self.pixels(wx)), y: Double(Self.pixels(wy)))
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

