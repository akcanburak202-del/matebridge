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
    /// Where the event is located: on the virtual display (the cached cursor if it is still on it, else the center).
    /// A scroll event without a location takes the live cursor, which may be on another display.
    public var position: DisplayPoint

    public init(phase: Phase, dx: Int32, dy: Int32, position: DisplayPoint) {
        self.phase = phase
        self.dx = dx
        self.dy = dy
        self.position = position
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

