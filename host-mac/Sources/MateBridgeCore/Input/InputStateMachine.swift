// Pure host-side input state machine (docs/PROTOCOL.md sections 4 and 7, decisions 0003 and 0006).
//
// Input: protocol messages plus `now` (monotonic microseconds, the same clock as `SessionMachine`; the machine has
// no clock of its own). Output: an ordered `[InjectAction]` for the injector (T-023). No CGEvent, no I/O, no logging.
//
// Ownership and lifetime for the consumer:
// - One instance per session; its state is never carried to the next session (PROTOCOL.md section 7). A new machine
//   starts with both pen latches armed (section 4 latch rule, "at session start"), so a first contact sample without
//   `STROKE_START` is hover. Every message of the active session goes to `handle(_:now:)`, a timer calls
//   `tick(now:)` at `nextDeadline(now:)`, and every release-all trigger of PROTOCOL.md section 7 calls
//   `releaseAll(_:)`, which is idempotent and safe to call at any time.
// - Time: `now` is the host's single monotonic clock at the moment the message was RECEIVED (never the message's own
//   `*_time_us`). `handle` first applies every overdue watchdog, exactly as `tick(now:)` would, and returns those
//   actions before the message's own, so the result does not depend on when the timer happened to run. If `now` is
//   earlier than a stored watchdog timestamp the timestamp is re-anchored to `now`. Every public call that takes
//   `now` and can see the backwards clock does this first (`handle`, `tick` and `nextDeadline(now:)`, so the last one
//   mutates), hence a backwards clock delays a watchdog by at most one period after it was first observed, and a
//   `tick` at the time `nextDeadline(now:)` returned always acts.
// - A value type with no locking: mutate it from one queue or actor only (the session queue).
// - Keyboard (`KEY`, `InputStateMachine+Keyboard.swift`): held keys are remembered by identity together with the
//   keycode or modifier that was injected; the host-side auto-repeat is driven by the same `tick` / `nextDeadline`
//   as the watchdogs; `releaseAll` releases keys and modifiers with the rest.
//
// Rule identifiers (used in tests as name prefixes; see the T-022 handoff table):
//   KEY-*    section 4 KEY host rules
//   PEN-*    section 4 PEN table            LATCH-*  section 4 latch rule        WD-*     section 7 watchdogs
//   OWN-*    section 7 left-button owner    OR-*     section 7 other buttons     GATE-*   section 7 + decision 0006 finger gate
//   REL-*    section 7 release-all          ERASER-* decision 0006 double tap    SCROLL-* section 4 SCROLL host rules

public struct InputStateMachine: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Pen `IN_RANGE` without a PEN message for this long: up + leave (PROTOCOL.md section 7).
        public var penWatchdogUs: UInt64 = 500_000
        /// Open scroll gesture without a SCROLL message for this long: end it (PROTOCOL.md section 7).
        public var scrollWatchdogUs: UInt64 = 500_000
        /// Open pinch gesture without a PINCH message for this long: end it (PROTOCOL.md section 7).
        public var pinchWatchdogUs: UInt64 = 500_000
        /// New TOUCH presses are ignored while the pen is in range and for this long after the last pen sample
        /// (decision 0006).
        public var touchGateHoldUs: UInt64 = 1_000_000
        /// Key auto-repeat: delay before the first repeat and spacing of the rest (the Host passes the macOS
        /// settings, `NSEvent.keyRepeatDelay` / `keyRepeatInterval`; these are the macOS defaults).
        public var keyRepeatDelayUs: UInt64 = 500_000
        public var keyRepeatIntervalUs: UInt64 = 83_000
        /// False when macOS has key repeat turned off: no repeat is ever armed.
        public var keyRepeatEnabled = true
        /// Key identity to Mac key (decision 0008 default modifier mapping).
        public var keyMap = KeyMap()
        public init() {}
    }

    /// Who can hold the Mac's left button. The pen presses it with tablet-point events; the rest are pointer sources.
    enum Source: Hashable, CaseIterable, Sendable {
        case pen
        case relative   // POINTER_REL
        case mouse      // POINTER_ABS source = MOUSE
        case touch      // POINTER_ABS source = TOUCH
    }

    /// Per pointer source: what the client last reported, and what of it counts towards the Mac's state.
    struct PointerSourceState: Sendable {
        /// Buttons as the client last reported them. Deliberately NOT cleared by release-all: a stale message that
        /// still says `LEFT` after a release must not look like a fresh press (there is no `STROKE_START` for
        /// pointers). Only a report without the button, then a new press, produces a new down.
        var held: PointerButtons = []
        /// Right, middle, back and forward presses that were accepted and not yet released. The Mac's state for
        /// these buttons is the union over all sources (OR-*). Left is tracked by `leftOwner`, not here.
        var contributing: PointerButtons = []
    }

    struct ActivePen: Sendable {
        var tool: PenTool
        var contact: Bool
    }

    public let configuration: Configuration

    /// Decision 0006: after a PEN_GESTURE `DOUBLE_TAP` the pen is reported to the Mac as the eraser tip.
    public internal(set) var isEraserMode = false
    /// The cause of the most recent `releaseAll`, for diagnostics.
    public private(set) var lastReleaseCause: ReleaseCause?

    // Pen. `activePen != nil` means proximity is entered. Whenever it is non-nil, `lastPenPoint` and
    // `lastPenSampleAt` are non-nil too.
    var activePen: ActivePen?
    var lastPenPoint: PenPoint?
    /// Host time of the most recent PEN message (any flags). Drives the finger gate only; a backwards clock keeps
    /// the gate active (the safe direction), so this is never re-anchored.
    var lastPenSampleAt: UInt64?
    /// The pen watchdog's own copy of the last PEN time. Re-anchored to `now` when the clock goes backwards.
    var penWatchdogAnchor: UInt64 = 0
    /// Tools whose next `CONTACT` sample must be treated as hover (LATCH-*). Both are latched from the start of the
    /// session and again after every release-all.
    var latchedTools: Set<PenTool> = [.pen, .eraser]

    // Left-button ownership and pointer sources.
    var leftOwner: Source?
    var pointerStates: [Source: PointerSourceState] = [:]

    // Scroll.
    var scrollOpen = false
    /// Host time of the last SCROLL BEGAN/CHANGED. Re-anchored to `now` when the clock goes backwards.
    var lastScrollAt: UInt64 = 0

    // Pinch (magnify gesture). Mutually exclusive with scroll (`InputStateMachine+Pinch.swift`).
    var pinchOpen = false
    /// Host time of the last PINCH BEGAN/CHANGED. Re-anchored to `now` when the clock goes backwards.
    var lastPinchAt: UInt64 = 0
    /// PINCH messages seen in this session, for the log (counts only).
    public internal(set) var pinchMessages = 0
    /// Forced ends not yet taken by `takePinchForcedEnds()`, for the `pinch_forced_end` log event.
    var pendingPinchEnds: [PinchEndCause] = []

    // Keyboard.
    /// Keys held, in press order, with what was injected for them (the UP releases the record, never the current
    /// mapping).
    var heldKeys: [HeldKey] = []
    var keyRepeat: KeyRepeat?
    /// Keyboard statistics for the log: counts only, never which keys.
    public internal(set) var keyCounters = KeyCounters()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: Introspection

    /// True while anything is held on the Mac: pen proximity or contact, any button, an open scroll gesture.
    /// After `releaseAll` this is always false.
    public var hasHeldInput: Bool {
        activePen != nil || leftOwner != nil || !macOtherButtons.isEmpty || scrollOpen || pinchOpen || !heldKeys.isEmpty
    }

    /// Pen proximity is currently entered on the Mac.
    public var isPenInRange: Bool { activePen != nil }

    /// Pen contact (left button pressed by the pen) is currently held on the Mac.
    public var isPenInContact: Bool { activePen?.contact == true }

    /// True when new TOUCH presses would be ignored right now (GATE-*).
    public func isTouchGateActive(at now: UInt64) -> Bool {
        if activePen != nil { return true }
        guard let last = lastPenSampleAt else { return false }
        return Self.elapsed(since: last, now: now) < configuration.touchGateHoldUs
    }

    /// The earliest time at which `tick(now:)` (or any `handle`) would produce watchdog actions, given the current
    /// time `now`, or nil when no watchdog is armed. Lets the consumer sleep until then instead of polling.
    ///
    /// MUTATING: like `tick` and `handle` it first re-anchors a watchdog timestamp that is ahead of `now` (clock went
    /// backwards) to `now`. That is what makes the answer binding: a `tick` at the returned time always acts, and
    /// one microsecond earlier never does, even when this call was the first to observe the backwards clock.
    public mutating func nextDeadline(now: UInt64) -> UInt64? {
        reanchorWatchdogs(now: now)
        var earliest: UInt64?
        if activePen != nil { earliest = penWatchdogAnchor &+ configuration.penWatchdogUs }
        if scrollOpen {
            let due = lastScrollAt &+ configuration.scrollWatchdogUs
            earliest = earliest.map { Swift.min($0, due) } ?? due
        }
        if pinchOpen {
            let due = lastPinchAt &+ configuration.pinchWatchdogUs
            earliest = earliest.map { Swift.min($0, due) } ?? due
        }
        if let r = keyRepeat { earliest = earliest.map { Swift.min($0, r.nextAt) } ?? r.nextAt }
        return earliest
    }

    // MARK: Events

    /// Feed one message of the active, approved session. First applies every overdue watchdog (WD-*), then the
    /// message; the returned list is the watchdog actions followed by the message's. Messages that are not pen,
    /// pointer, scroll, key or release input produce no actions of their own.
    public mutating func handle(_ message: Message, now: UInt64) -> [InjectAction] {
        var out = applyWatchdogs(now: now)
        switch message {
        case .pen(let batch):
            out += handlePen(batch, now: now)
        case .pointerRel(let m):
            let motion: MouseMotion? = (m.dx == 0 && m.dy == 0) ? nil : .relative(dx: m.dx, dy: m.dy)
            out += handlePointer(.relative, buttons: m.buttons, motion: motion, now: now)
        case .pointerAbs(let m):
            out += handlePointer(m.source == .touch ? .touch : .mouse, buttons: m.buttons,
                                 motion: .absolute(x: m.x, y: m.y), now: now)
        case .scroll(let m):
            out += handleScroll(m, now: now)
        case .pinch(let m):
            pinchMessages += 1
            out += handlePinch(m, now: now)
        case .penGesture(let g):
            handlePenGesture(g)
        case .releaseAll(let reason):
            out += releaseAll(.clientRequest(reason))
        case .bye:
            out += releaseAll(.bye)
        case .key(let k):
            out += handleKey(k, now: now)
        case .hello, .helloAck, .streamConfig, .streamPrefs, .clipboard, .ping, .pong, .stats, .keyframeRequest, .videoHello, .videoFrame:
            break
        }
        return out
    }

    /// Watchdogs (WD-*) without a message. Call when the timer at `nextDeadline(now:)` fires.
    public mutating func tick(now: UInt64) -> [InjectAction] {
        applyWatchdogs(now: now)
    }

    /// A watchdog timestamp that is ahead of `now` means the clock went backwards: count from `now` instead. The one
    /// place this happens; `nextDeadline(now:)` and `applyWatchdogs(now:)` both call it first.
    private mutating func reanchorWatchdogs(now: UInt64) {
        if activePen != nil, penWatchdogAnchor > now { penWatchdogAnchor = now }
        if scrollOpen, lastScrollAt > now { lastScrollAt = now }
        if pinchOpen, lastPinchAt > now { lastPinchAt = now }
        // A repeat due further ahead than one repeat delay cannot have been scheduled by this clock: count from `now`.
        if let r = keyRepeat, r.nextAt > now &+ Swift.max(configuration.keyRepeatDelayUs, configuration.keyRepeatIntervalUs) {
            keyRepeat?.nextAt = now &+ configuration.keyRepeatIntervalUs
        }
    }

    /// Pen `IN_RANGE` silent for `penWatchdogUs`: up (if touching) + leave. Open scroll silent for
    /// `scrollWatchdogUs`: forced end. A watchdog close is not a release-all: no latch, eraser mode and the other
    /// sources untouched (PROTOCOL.md section 7).
    private mutating func applyWatchdogs(now: UInt64) -> [InjectAction] {
        reanchorWatchdogs(now: now)
        var out: [InjectAction] = []
        if activePen != nil, now - penWatchdogAnchor >= configuration.penWatchdogUs { closePen(into: &out) }
        if scrollOpen {
            if now - lastScrollAt >= configuration.scrollWatchdogUs {
                scrollOpen = false
                out.append(.scroll(.forcedEnd, dx: 0, dy: 0))
            }
        }
        if pinchOpen, now - lastPinchAt >= configuration.pinchWatchdogUs { out += forceEndPinch(.watchdog) }
        out += repeatKeyIfDue(now: now)
        return out
    }

    /// REL-*: release everything held on the Mac, in a fixed order, and arm the latches. Idempotent.
    ///
    /// Order: left button (pen up, or the owner's up), pen leave, right/middle/back/forward ups, scroll forced end,
    /// key ups (last pressed first), modifier ups.
    /// Afterwards: no owner, nothing contributing, no proximity, no open scroll, eraser mode off, both pen tools
    /// latched. The pointer sources' reported button state is kept (see `PointerSourceState.held`), and so is the
    /// time of the last pen sample (the palm is still on the glass after a release).
    public mutating func releaseAll(_ cause: ReleaseCause) -> [InjectAction] {
        lastReleaseCause = cause
        var out: [InjectAction] = []

        if let a = activePen, a.contact {
            out.append(.penUp(tool: a.tool, (lastPenPoint ?? Self.origin).withPressure(0)))
        } else if let owner = leftOwner, owner != .pen {
            out.append(.mouseButton(.left, down: false))
        }
        leftOwner = nil
        if let a = activePen {
            out.append(.penProximity(tool: a.tool, entering: false))
            activePen = nil
        }
        for button in MouseButton.allCases where button != .left && macOtherButtons.contains(button.pointerButton) {
            out.append(.mouseButton(button, down: false))
        }
        for source in pointerStates.keys { pointerStates[source]?.contributing = [] }
        if scrollOpen {
            scrollOpen = false
            out.append(.scroll(.forcedEnd, dx: 0, dy: 0))
        }
        out += forceEndPinch(.releaseAll)
        out += releaseKeys()

        isEraserMode = false
        latchedTools = [.pen, .eraser]
        return out
    }

    // MARK: Shared helpers

    static let origin = PenPoint(x: 0, y: 0, pressure: 0, tiltX: 0, tiltY: 0)

    /// `now - since`, or 0 if the clock appears to go backwards (never underflows).
    static func elapsed(since: UInt64, now: UInt64) -> UInt64 { now >= since ? now - since : 0 }

    /// Union of the accepted right/middle/back/forward presses of all sources (what the Mac sees).
    var macOtherButtons: PointerButtons {
        pointerStates.values.reduce(into: PointerButtons()) { $0.formUnion($1.contributing) }
    }

    /// The button an ongoing move drags with: left before right, middle, back, forward; nil when none is held.
    var macDragButton: MouseButton? {
        if leftOwner != nil { return .left }
        let others = macOtherButtons
        return MouseButton.allCases.first { $0 != .left && others.contains($0.pointerButton) }
    }
}
