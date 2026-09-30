// Output vocabulary of `InputStateMachine` (docs/PROTOCOL.md sections 4 and 7).
//
// An `InjectAction` is one abstract event for the injector (T-023) to turn into a CGEvent. The list a machine
// call returns is ordered and must be executed in order. Nothing here knows about CGEvent, the display or
// coordinates in points: positions stay in the protocol's normalized form and are converted in one place
// by the injector.

/// Mac mouse button. The raw value is the CGEvent `mouseEventButtonNumber`.
public enum MouseButton: UInt8, CaseIterable, Sendable {
    case left = 0
    case right = 1
    case middle = 2
    case back = 3
    case forward = 4

    /// The matching `POINTER_*` button bit.
    public var pointerButton: PointerButtons {
        switch self {
        case .left: .left
        case .right: .right
        case .middle: .middle
        case .back: .back
        case .forward: .forward
        }
    }
}

extension PointerButtons {
    /// The five buttons the protocol defines; undefined bits are ignored everywhere.
    static let known: PointerButtons = [.left, .right, .middle, .back, .forward]
}

/// One pen position with pressure and tilt, as sent by the tablet (raw protocol units).
public struct PenPoint: Equatable, Sendable {
    /// Normalized position on the video surface, 0...65535 (PROTOCOL.md section 1).
    public var x: UInt16
    public var y: UInt16
    /// 0...65535. Always 0 for hover, up and leave-adjacent events.
    public var pressure: UInt16
    /// Raw i16 of -1...1. Use `tiltXUnit` / `tiltYUnit` for `NSEvent.tilt` semantics.
    public var tiltX: Int16
    public var tiltY: Int16

    public init(x: UInt16, y: UInt16, pressure: UInt16, tiltX: Int16, tiltY: Int16) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
    }

    /// -1 (left) ... +1 (right).
    public var tiltXUnit: Double { TiltCodec.decode(tiltX) }
    /// -1 (top) ... +1 (bottom).
    public var tiltYUnit: Double { TiltCodec.decode(tiltY) }
    /// 0...1.
    public var pressureUnit: Double { PressureCodec.decode(pressure) }

    func withPressure(_ p: UInt16) -> PenPoint {
        PenPoint(x: x, y: y, pressure: p, tiltX: tiltX, tiltY: tiltY)
    }
}

/// How a `mouseMove` action moves the cursor.
public enum MouseMotion: Equatable, Sendable {
    /// Move to a normalized position (`POINTER_ABS`).
    case absolute(x: UInt16, y: UInt16)
    /// Move by a delta in Mac points, +y down (`POINTER_REL`).
    case relative(dx: Float, dy: Float)
}

/// Phase of a precise scroll gesture on the Mac side. The injector can tell the three ways a gesture ends apart
/// (PROTOCOL.md section 4 SCROLL):
/// - `ended`: the client finished normally; momentum may follow (host setting).
/// - `cancelled`: the client sent `CANCELLED`; the Mac sees a cancelled gesture.
/// - `forcedEnd`: the host ended it itself (new `BEGAN` over an open gesture, the 500 ms watchdog, release-all); the
///   Mac sees a normal `ENDED` but the injector must not generate momentum, and must stop any momentum in progress.
public enum InjectScrollPhase: Equatable, Sendable {
    case began
    case changed
    case ended
    case cancelled
    case forcedEnd
}

/// One abstract event for the injector. Execute in list order.
public enum InjectAction: Equatable, Sendable {
    // MARK: Pen (tablet events; the pen presses the left button, tablet-point subtype)

    /// Tablet proximity event. `entering == true` is enter, `false` is leave. Always preceded by
    /// `penUp` when contact was held.
    case penProximity(tool: PenTool, entering: Bool)
    /// Pen in range, not touching: `mouseMoved` with tablet-point data.
    case penHover(tool: PenTool, PenPoint)
    /// Pen touches: `leftMouseDown` with tablet-point data and pressure.
    case penDown(tool: PenTool, PenPoint)
    /// Pen moves while touching: `leftMouseDragged`.
    case penDrag(tool: PenTool, PenPoint)
    /// Pen lifts (also on cancel, watchdog, tool change and release-all): `leftMouseUp`, pressure 0.
    case penUp(tool: PenTool, PenPoint)

    // MARK: Mouse and touch pointer

    /// Move the cursor. `dragging` is the button currently held on the Mac (left before right, middle,
    /// back, forward): the injector posts the matching `*MouseDragged`, or `mouseMoved` when nil.
    /// Within one message the move always comes before its button changes.
    case mouseMove(MouseMotion, dragging: MouseButton?)
    /// A Mac button changes state at the cursor's current position (set by the preceding `mouseMove`,
    /// or unchanged when no move was emitted). Also used for the up that pen priority or release-all issue
    /// on behalf of a source.
    case mouseButton(MouseButton, down: Bool)

    // MARK: Scroll

    /// One step of a precise scroll gesture. `dx`/`dy` are finger movement in Mac points; `forcedEnd` carries 0.
    case scroll(InjectScrollPhase, dx: Float, dy: Float)
    /// A single mouse wheel step (`SCROLL phase = NONE`); carries no state.
    case scrollWheel(dx: Float, dy: Float)
}
