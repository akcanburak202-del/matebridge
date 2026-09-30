// Display-space half of host input injection (T-023): everything between the state machine's `InjectAction`s and
// the CGEvent poster that can be decided without a Mac, so it is unit-tested.
//
//   InjectAction --InjectionPlanner--> MacEvent --(Host: CGEventPoster)--> CGEvent.post
//
// Sections: DisplayGeometry (the one coordinate conversion, PROTOCOL.md section 1), MacEvent (the seam vocabulary),
// ClickCounter, InjectionPlanner (the injector's own state) and InputPipeline (session lifecycle and release-all).
// Nothing here posts events, checks permissions or looks at the screen; the Host passes an `InjectionEnvironment`.
//
// The file is one file because T-023 may add exactly one file under Core/Input (see the card's Open questions).
//
// Rule identifiers used as test-name prefixes: GEO-* geometry, CLICK-* click state, PLAN-* planner, PIPE-* pipeline.

// MARK: - Display geometry

/// A position in the global display coordinate space (points, origin top-left of the main display, y down).
public struct DisplayPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = DisplayPoint(x: 0, y: 0)
}

/// The virtual display in global coordinates: `CGDisplayBounds` plus its backing scale. This is the single place that
/// turns normalized `u16` positions into points (PROTOCOL.md section 1): `x_pt = origin + v / 65535 * extent`,
/// clamped to `[origin, origin + extent - 1/scale]`. The origin is never assumed to be (0, 0).
public struct DisplayGeometry: Equatable, Sendable {
    public let originX: Double
    public let originY: Double
    public let widthPt: Double
    public let heightPt: Double
    /// Pixels per point (2 for the HiDPI virtual display).
    public let scale: Double

    /// nil for a display that cannot be mapped onto: non-finite values, empty size or a non-positive scale.
    public init?(originX: Double, originY: Double, widthPt: Double, heightPt: Double, scale: Double) {
        guard originX.isFinite, originY.isFinite, widthPt.isFinite, heightPt.isFinite, scale.isFinite,
              widthPt > 0, heightPt > 0, scale > 0 else { return nil }
        self.originX = originX
        self.originY = originY
        self.widthPt = widthPt
        self.heightPt = heightPt
        self.scale = scale
    }

    /// GEO-*: normalized position to global points.
    public func point(x: UInt16, y: UInt16) -> DisplayPoint {
        DisplayPoint(x: NormalizedCoord.toPoints(x, origin: originX, extent: widthPt, scale: scale),
                     y: NormalizedCoord.toPoints(y, origin: originY, extent: heightPt, scale: scale))
    }

    public func point(_ p: PenPoint) -> DisplayPoint { point(x: p.x, y: p.y) }

    public var center: DisplayPoint { DisplayPoint(x: originX + widthPt / 2, y: originY + heightPt / 2) }

    /// The same bounds `point(x:y:)` uses. A non-finite value maps to the origin.
    public func clamped(_ p: DisplayPoint) -> DisplayPoint {
        DisplayPoint(x: Self.clamp(p.x, origin: originX, extent: widthPt, scale: scale),
                     y: Self.clamp(p.y, origin: originY, extent: heightPt, scale: scale))
    }

    /// Relative cursor movement (`POINTER_REL`): the cursor stays on the display.
    public func moved(_ p: DisplayPoint, dx: Double, dy: Double) -> DisplayPoint {
        clamped(DisplayPoint(x: p.x + dx, y: p.y + dy))
    }

    private static func clamp(_ v: Double, origin: Double, extent: Double, scale: Double) -> Double {
        guard v.isFinite else { return origin }
        let upper = Swift.max(origin + extent - 1 / scale, origin)
        return Swift.min(Swift.max(v, origin), upper)
    }
}

// MARK: - The seam vocabulary

/// A tablet-point mouse event (subtype `tabletPoint`): the pen. `pressure` 0...1, tilt -1...1 (`NSEvent.tilt` sense).
public struct MacTabletPoint: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `mouseMoved` (pen in range, not touching).
        case hover
        /// `leftMouseDown`.
        case down
        /// `leftMouseDragged`.
        case drag
        /// `leftMouseUp`, pressure 0.
        case up
    }

    public var kind: Kind
    public var tool: PenTool
    public var position: DisplayPoint
    public var pressure: Double
    public var tiltX: Double
    public var tiltY: Double
    /// 1 on down and up (as in the Phase 0 probe), 0 (unset) otherwise.
    public var clickState: Int

    public init(kind: Kind, tool: PenTool, position: DisplayPoint, pressure: Double, tiltX: Double, tiltY: Double,
                clickState: Int) {
        self.kind = kind
        self.tool = tool
        self.position = position
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.clickState = clickState
    }
}

/// An ordinary mouse event for touch, mouse and trackpad pointers.
public struct MacMouse: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case moved
        /// `*MouseDragged` of `button`.
        case dragged
        case down
        case up
    }

    public var kind: Kind
    /// The button of a down, up or drag; `.left` (ignored) for `moved`.
    public var button: MouseButton
    public var position: DisplayPoint
    /// Movement since the previous injected position, clamped to the display.
    public var deltaX: Double
    public var deltaY: Double
    /// Click count on down and up (an up repeats its down's), 0 otherwise.
    public var clickState: Int

    public init(kind: Kind, button: MouseButton, position: DisplayPoint, deltaX: Double, deltaY: Double,
                clickState: Int) {
        self.kind = kind
        self.button = button
        self.position = position
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.clickState = clickState
    }
}

/// A scroll wheel event in pixel units; +dy scrolls like a finger moving down (natural direction, unverified).
/// There is no momentum field: the injector never generates momentum (phase 3).
public struct MacScroll: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// A single wheel step (no gesture).
        case none
        case began
        case changed
        case ended
        case cancelled
    }

    public var phase: Phase
    public var dx: Int32
    public var dy: Int32

    public init(phase: Phase, dx: Int32, dy: Int32) {
        self.phase = phase
        self.dx = dx
        self.dy = dy
    }
}

/// One event for the CGEvent poster, fully resolved: global positions, real units, click counts.
public enum MacEvent: Equatable, Sendable {
    case tabletProximity(tool: PenTool, entering: Bool)
    case tabletPoint(MacTabletPoint)
    case mouse(MacMouse)
    case scroll(MacScroll)
}

/// What the Host knows right now. Sampled by the Host before every call; the Core never queries the system.
public struct InjectionEnvironment: Equatable, Sendable {
    /// Accessibility permission granted (events can be posted).
    public var canInject: Bool
    /// The virtual display, or nil when there is none (input is ignored, nothing may land on another display).
    public var geometry: DisplayGeometry?

    public init(canInject: Bool, geometry: DisplayGeometry?) {
        self.canInject = canInject
        self.geometry = geometry
    }

    /// New input may start.
    public var isOpen: Bool { canInject && geometry != nil }
}

// MARK: - Click state

/// Counts consecutive presses of the same button close in time and place (`mouseEventClickState`, PROTOCOL.md
/// section 4 POINTER_REL). The client sends only button states; double clicks are the host's to make.
public struct ClickCounter: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Maximum time between two presses that still count as a multi-click (`NSEvent.doubleClickInterval`).
        public var intervalUs: UInt64 = 500_000
        /// Maximum distance between two presses, in points.
        public var distancePt: Double = 5
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
        var out: [MacEvent] = []
        for action in actions { apply(action, env, now, &out) }
        counters.events += out.count
        return out
    }

    /// Releases everything the shadow state holds, in the state machine's order (left button, pen leave, other
    /// buttons, scroll end). Needs no environment: releasing is never gated. Idempotent. This is the safety net under
    /// the state machine's own release-all.
    public mutating func releaseAll() -> [MacEvent] {
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
            let position = env.geometry.map { $0.point(p) } ?? lastTablet?.position ?? cursor ?? .zero
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
                if let c = cursor { delta = DisplayPoint(x: target.x - c.x, y: target.y - c.y) }
            case .relative(let dx, let dy):
                // A relative move needs a starting point; before any injected position that is the display center.
                let base = cursor ?? g.center
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
                let position = cursor ?? g.center
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
            if px != 0 || py != 0 { out.append(.scroll(MacScroll(phase: .none, dx: px, dy: py))) }
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
            out.append(.scroll(MacScroll(phase: .began, dx: px, dy: py)))

        case .changed:
            guard scrollOpen else { counters.droppedNotHeld += 1; return }
            // The client's keepalive carries no movement and must not reach the Mac.
            guard dx != 0 || dy != 0 else { counters.droppedKeepalive += 1; return }
            guard env.canInject else { counters.droppedNoPermission += 1; return }
            guard env.geometry != nil else { counters.droppedNoDisplay += 1; return }
            let (px, py) = takePixels(Double(dx), Double(dy))
            if px != 0 || py != 0 { out.append(.scroll(MacScroll(phase: .changed, dx: px, dy: py))) }

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
        let e = MacTabletPoint(kind: .up, tool: tool, position: last?.position ?? cursor ?? .zero, pressure: 0,
                               tiltX: last?.tiltX ?? 0, tiltY: last?.tiltY ?? 0, clickState: 1)
        lastTablet = e
        penContact = false
        out.append(.tabletPoint(e))
    }

    private func emitButtonUp(_ button: MouseButton, _ clickState: Int, _ out: inout [MacEvent]) {
        out.append(.mouse(MacMouse(kind: .up, button: button, position: cursor ?? .zero, deltaX: 0, deltaY: 0,
                                   clickState: clickState)))
    }

    private mutating func closeScroll(_ phase: MacScroll.Phase, dx: Int32, dy: Int32, _ out: inout [MacEvent]) {
        scrollOpen = false
        scrollCarryX = 0
        scrollCarryY = 0
        out.append(.scroll(MacScroll(phase: phase, dx: dx, dy: dy)))
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

// MARK: - Pipeline

/// One injector's whole input side: the injector state that outlives sessions (`InjectionPlanner`, which mirrors the
/// Mac) plus the state machine of the CURRENT session, which never outlives it (PROTOCOL.md section 7: a session's
/// input state is not carried to the next).
///
/// Threading: a value type with no locking; call it from one serial context only (the Host's input queue). Every
/// release-all trigger of PROTOCOL.md section 7 ends in `release(_:now:environment:)`: `RELEASE_ALL` and `BYE`
/// (either direction), connection loss, protocol error, heartbeat silence, takeover and app shutdown all arrive as a
/// `ReleaseCause` from `SessionMachine`, and `sessionEnded` / `shutdown` release again as a backstop.
public struct InputPipeline: Sendable {
    public internal(set) var planner: InjectionPlanner
    /// The current session's machine; nil between sessions.
    public private(set) var machine: InputStateMachine?
    /// The cause of the most recent release.
    public private(set) var lastReleaseCause: ReleaseCause?
    /// How often the safety net found the planner holding something the machine did not (must stay 0).
    public private(set) var reconciliations = 0
    private let machineConfiguration: InputStateMachine.Configuration

    public init(planner: InjectionPlanner.Configuration = .init(), machine: InputStateMachine.Configuration = .init()) {
        self.planner = InjectionPlanner(configuration: planner)
        machineConfiguration = machine
    }

    public var hasSession: Bool { machine != nil }

    /// Anything held on the Mac, or by the machine.
    public var isHoldingInput: Bool { planner.isHoldingInput || machine?.hasHeldInput == true }

    /// PIPE-*: a new approved session. Leftovers on the Mac (there should be none) are released first; then the
    /// session gets a FRESH machine, latched from the start (PROTOCOL.md section 4).
    public mutating func sessionStarted() -> [MacEvent] {
        let out = planner.releaseAll()
        machine = InputStateMachine(configuration: machineConfiguration)
        lastReleaseCause = nil
        return out
    }

    /// The session is over: release everything (whatever the cause was), drop its machine.
    public mutating func sessionEnded(now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        let out = release(lastReleaseCause ?? .disconnected, now: now, environment: env)
        machine = nil
        return out
    }

    /// The host app is quitting.
    public mutating func shutdown(now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        let out = release(.shutdown, now: now, environment: env)
        machine = nil
        return out
    }

    /// One message of the active session (`now` = host clock when it was received).
    public mutating func handle(_ message: Message, now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        guard machine != nil else { return [] }
        var out = releaseIfGateLost(now: now, environment: env)
        let actions = machine?.handle(message, now: now) ?? []
        out += planner.plan(actions, environment: env, now: now)
        out += reconcile()
        return out
    }

    /// Watchdogs without a message; call when the timer at `nextDeadline(now:)` fires.
    public mutating func tick(now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        guard machine != nil else { return [] }
        var out = releaseIfGateLost(now: now, environment: env)
        let actions = machine?.tick(now: now) ?? []
        out += planner.plan(actions, environment: env, now: now)
        out += reconcile()
        return out
    }

    /// When the next watchdog is due (see `InputStateMachine.nextDeadline(now:)`, which mutates for the same reason).
    public mutating func nextDeadline(now: UInt64) -> UInt64? {
        machine?.nextDeadline(now: now)
    }

    /// Releases everything: the machine's release-all first (its actions go through the planner), then the planner's
    /// own safety net for anything still on the Mac. Idempotent; safe with no session, no display and no permission.
    public mutating func release(_ cause: ReleaseCause, now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        lastReleaseCause = cause
        let actions = machine?.releaseAll(cause) ?? []
        var out = planner.plan(actions, environment: env, now: now)
        out += planner.releaseAll()
        return out
    }

    /// Losing the display or the permission while the Mac holds our input releases it right away (the release itself
    /// is not gated), instead of waiting for the client to lift the pen.
    private mutating func releaseIfGateLost(now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        guard !env.isOpen, planner.isHoldingInput else { return [] }
        return release(.disconnected, now: now, environment: env)
    }

    /// Safety net: the planner can only hold what the machine holds. If it does not, release the leftover.
    private mutating func reconcile() -> [MacEvent] {
        guard planner.isHoldingInput, machine?.hasHeldInput != true else { return [] }
        reconciliations += 1
        return planner.releaseAll()
    }
}
