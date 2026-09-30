import Testing
@testable import MateBridgeCore

// Shared helpers for the T-022 input state machine tests.

let msec: UInt64 = 1_000

// Pen flag shorthands.
let hoverFlags: PenFlags = .inRange
let touchFlags: PenFlags = [.inRange, .contact]
let startFlags: PenFlags = [.inRange, .contact, .strokeStart]

let defaultTiltX: Int16 = 100
let defaultTiltY: Int16 = -200

func penSample(_ x: UInt16 = 1000, _ y: UInt16 = 2000, _ flags: PenFlags, pressure: UInt16 = 0) -> PenSample {
    PenSample(dtUs: 0, x: x, y: y, pressure: pressure, tiltX: defaultTiltX, tiltY: defaultTiltY, flags: flags)
}

func penMsg(_ tool: PenTool = .pen, _ samples: PenSample...) -> Message {
    var fixed = samples
    for i in fixed.indices { fixed[i].dtUs = UInt32(i) * 3000 }
    return .pen(PenBatch(tool: tool, baseTimeUs: 0, samples: fixed))
}

/// The `PenPoint` a `sample(x, y, ...)` turns into.
func penPt(_ x: UInt16 = 1000, _ y: UInt16 = 2000, _ pressure: UInt16 = 0) -> PenPoint {
    PenPoint(x: x, y: y, pressure: pressure, tiltX: defaultTiltX, tiltY: defaultTiltY)
}

func relMsg(_ dx: Float = 0, _ dy: Float = 0, _ buttons: PointerButtons = []) -> Message {
    .pointerRel(PointerRel(timeUs: 0, dx: dx, dy: dy, buttons: buttons))
}

func absMsg(_ source: PointerSource, _ x: UInt16 = 500, _ y: UInt16 = 600, _ buttons: PointerButtons = []) -> Message {
    .pointerAbs(PointerAbs(timeUs: 0, x: x, y: y, buttons: buttons, source: source))
}

func scrollMsg(_ phase: ScrollPhase, _ dx: Float = 0, _ dy: Float = 0) -> Message {
    .scroll(Scroll(timeUs: 0, dx: dx, dy: dy, phase: phase))
}

let doubleTap: Message = .penGesture(PenGesture(timeUs: 0, gesture: .doubleTap))

func penEnter(_ tool: PenTool = .pen) -> InjectAction { .penProximity(tool: tool, entering: true) }
func penLeave(_ tool: PenTool = .pen) -> InjectAction { .penProximity(tool: tool, entering: false) }

/// Absolute move to the default touch/mouse position with no button held on the Mac.
func moveAbs(_ x: UInt16 = 500, _ y: UInt16 = 600, dragging: MouseButton? = nil) -> InjectAction {
    .mouseMove(.absolute(x: x, y: y), dragging: dragging)
}

/// Every way the host can decide to release everything (PROTOCOL.md section 7 triggers).
let allReleaseCauses: [ReleaseCause] = [
    .clientRequest(.user), .clientRequest(.background), .clientRequest(.focusLost),
    .clientRequest(.deviceDetached), .clientRequest(ReleaseReason(rawValue: 99)),
    .bye, .disconnected, .protocolError, .silence, .timeout, .superseded, .shutdown, .gateLost,
]

/// A machine plus a clock the test advances explicitly.
struct Driver {
    var machine: InputStateMachine
    var now: UInt64

    init(configuration: InputStateMachine.Configuration = .init(), start: UInt64 = 10_000_000) {
        machine = InputStateMachine(configuration: configuration)
        now = start
    }

    /// Advances the clock by `after` microseconds, then delivers the message.
    @discardableResult
    mutating func send(_ message: Message, after: UInt64 = 1 * msec) -> [InjectAction] {
        now += after
        return machine.handle(message, now: now)
    }

    /// Moves the clock by a signed amount (never below 0): zero and backwards steps are allowed.
    mutating func jump(_ delta: Int64) {
        now = delta >= 0 ? now &+ UInt64(delta) : now - Swift.min(now, UInt64(-delta))
    }

    @discardableResult
    mutating func send(_ message: Message, delta: Int64) -> [InjectAction] {
        jump(delta)
        return machine.handle(message, now: now)
    }

    @discardableResult
    mutating func tick(delta: Int64) -> [InjectAction] {
        jump(delta)
        return machine.tick(now: now)
    }

    @discardableResult
    mutating func tick(after: UInt64) -> [InjectAction] {
        now += after
        return machine.tick(now: now)
    }

    @discardableResult
    mutating func release(_ cause: ReleaseCause = .clientRequest(.user)) -> [InjectAction] {
        machine.releaseAll(cause)
    }
}

/// Independent model of what the Mac ends up holding, built only from the `InjectAction` stream. Any action that
/// would be impossible on a real Mac (second down, up without down, leave while touching, ...) is a violation.
struct MacInputModel {
    var proximity: PenTool?
    var penContact = false
    var buttonsDown: Set<MouseButton> = []
    var scrollOpen = false
    var keysDown: Set<UInt16> = []
    var modifiersDown: Set<ModifierKey> = []
    private(set) var violations: [String] = []

    var isIdle: Bool {
        proximity == nil && !penContact && buttonsDown.isEmpty && !scrollOpen && keysDown.isEmpty && modifiersDown.isEmpty
    }
    var leftIsDown: Bool { penContact || buttonsDown.contains(.left) }

    private mutating func fail(_ text: String, _ action: InjectAction) { violations.append("\(text): \(action)") }

    mutating func apply(_ actions: [InjectAction]) { for a in actions { apply(a) } }

    mutating func apply(_ action: InjectAction) {
        switch action {
        case .penProximity(let tool, let entering):
            if entering {
                if proximity != nil { fail("enter while in proximity", action) }
                proximity = tool
            } else {
                if proximity != tool { fail("leave without matching enter", action) }
                if penContact { fail("leave while touching", action) }
                proximity = nil
            }
        case .penHover(let tool, let p):
            if proximity != tool { fail("hover outside proximity", action) }
            if penContact { fail("hover while touching", action) }
            if p.pressure != 0 { fail("hover with pressure", action) }
            if buttonsDown.contains(.left) { fail("pen hover while a pointer owns the left button", action) }
        case .penDown(let tool, _):
            if proximity != tool { fail("down outside proximity", action) }
            if leftIsDown { fail("pen down while left button is down", action) }
            penContact = true
        case .penDrag(let tool, _):
            if proximity != tool || !penContact { fail("drag without contact", action) }
        case .penUp(let tool, let p):
            if proximity != tool || !penContact { fail("up without contact", action) }
            if p.pressure != 0 { fail("up with pressure", action) }
            penContact = false
        case .mouseMove(_, let dragging):
            if penContact { fail("mouse move during pen contact", action) }
            let expected = MouseButton.allCases.first { buttonsDown.contains($0) }
            if dragging != expected { fail("wrong drag button (expected \(String(describing: expected)))", action) }
        case .mouseButton(let button, let down):
            if down {
                if buttonsDown.contains(button) { fail("button already down", action) }
                if button == .left && penContact { fail("left down during pen contact", action) }
                buttonsDown.insert(button)
            } else {
                if !buttonsDown.contains(button) { fail("button up without down", action) }
                buttonsDown.remove(button)
            }
        case .scroll(let phase, _, _):
            switch phase {
            case .began:
                if scrollOpen { fail("scroll began while open", action) }
                scrollOpen = true
            case .changed:
                if !scrollOpen { fail("scroll changed while closed", action) }
            case .ended, .cancelled, .forcedEnd:
                if !scrollOpen { fail("scroll end while closed", action) }
                scrollOpen = false
            }
        case .scrollWheel, .setCapsLock:
            break
        case .keyDown(let code, let autorepeat):
            if autorepeat {
                if !keysDown.contains(code) { fail("repeat of a key that is not down", action) }
            } else {
                if keysDown.contains(code) { fail("key already down", action) }
                keysDown.insert(code)
            }
        case .keyUp(let code):
            if !keysDown.contains(code) { fail("key up without down", action) }
            keysDown.remove(code)
        case .modifierDown(let m):
            if modifiersDown.contains(m) { fail("modifier already down", action) }
            modifiersDown.insert(m)
        case .modifierUp(let m):
            if !modifiersDown.contains(m) { fail("modifier up without down", action) }
            modifiersDown.remove(m)
        }
    }
}
