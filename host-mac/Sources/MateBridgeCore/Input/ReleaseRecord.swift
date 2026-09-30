// What a release did, for the log (docs/LOGGING.md: counts and names only, never coordinates).

extension ReleaseCause {
    /// A stable snake_case name for the log.
    public var logName: String {
        switch self {
        case .clientRequest(let r): "client_request_\(r.rawValue)"
        case .bye: "bye"
        case .disconnected: "disconnected"
        case .protocolError: "protocol_error"
        case .silence: "silence"
        case .timeout: "timeout"
        case .superseded: "superseded"
        case .shutdown: "shutdown"
        case .gateLost: "gate_lost"
        }
    }
}

/// One release by `InputPipeline` and how many events of which kind it produced. Also used for the two housekeeping
/// records: replaying owed releases (`owed_replay`) and the retry cadence of owed releases dropping to the slow one
/// (`owed_slow`). Owed releases are never given up on.
public struct ReleaseRecord: Equatable, Sendable {
    /// `ReleaseCause.logName`, or `owed_replay`, `owed_slow`, `session_start`.
    public var reason: String
    public var cause: ReleaseCause?
    /// Events produced (all kinds).
    public var events: Int
    public var penUps = 0
    public var penLeaves = 0
    public var buttonUps = 0
    public var scrollEnds = 0
    public var keyUps = 0
    /// Owed slots whose retry cadence dropped to the slow one (only for `owed_slow`).
    public var slowed = 0

    public init(reason: String, cause: ReleaseCause? = nil, events: [MacEvent], slowed: Int = 0) {
        self.reason = reason
        self.cause = cause
        self.events = events.count
        self.slowed = slowed
        for event in events {
            switch event {
            case .tabletPoint(let p) where p.kind == .up: penUps += 1
            case .tabletProximity(_, let entering) where !entering: penLeaves += 1
            case .mouse(let m) where m.kind == .up: buttonUps += 1
            case .scroll(let s) where s.phase == .ended || s.phase == .cancelled: scrollEnds += 1
            case .key(let k) where k.kind == .keyUp || k.kind == .modifierUp: keyUps += 1
            default: break
            }
        }
    }

    /// `key=value` fields for the log line.
    public var logFields: String {
        var f = "cause=\(reason) events=\(events) pen_up=\(penUps) pen_leave=\(penLeaves) buttons=\(buttonUps) scroll=\(scrollEnds)"
        if keyUps > 0 { f += " keys=\(keyUps)" }
        if slowed > 0 { f += " slowed=\(slowed)" }
        return f
    }
}
