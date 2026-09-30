// MARK: - Pipeline

/// One injector's whole input side: the injector state that outlives sessions (`InjectionPlanner`, which mirrors the
/// Mac) plus the state machine of the CURRENT session, which never outlives it (PROTOCOL.md section 7: a session's
/// input state is not carried to the next).
///
/// Threading: a value type with no locking; call it from one serial context only (the Host's input queue). Every
/// release-all trigger of PROTOCOL.md section 7 ends in `release(_:now:environment:)`: `RELEASE_ALL` and `BYE`
/// (either direction), connection loss, protocol error, heartbeat silence, takeover and app shutdown all arrive as a
/// `ReleaseCause` from `SessionMachine`, and `sessionEnded` / `shutdown` release again as a backstop. A gate loss
/// (display or permission gone while something is held) releases with `.gateLost`.
///
/// A release that could not reach the Mac is not forgotten: closing events produced while the permission is missing,
/// and closing events the poster reports as failed (`postFailed`), are kept in `owed` and replayed first, before any
/// new input, when the permission is back, at the next retry, session start and shutdown (see `OwedRelease`).
public struct InputPipeline: Sendable {
    public internal(set) var planner: InjectionPlanner
    /// The current session's machine; nil between sessions.
    public private(set) var machine: InputStateMachine?
    /// The cause of the most recent release.
    public private(set) var lastReleaseCause: ReleaseCause?
    /// How often the safety net found the planner holding something the machine did not (must stay 0).
    public private(set) var reconciliations = 0
    /// Closing events the Mac may not have received.
    public internal(set) var owed = OwedRelease()
    private var records: [ReleaseRecord] = []
    private let machineConfiguration: InputStateMachine.Configuration

    public init(planner: InjectionPlanner.Configuration = .init(), machine: InputStateMachine.Configuration = .init()) {
        self.planner = InjectionPlanner(configuration: planner)
        machineConfiguration = machine
    }

    public var hasSession: Bool { machine != nil }

    /// Anything held on the Mac, or by the machine.
    public var isHoldingInput: Bool { planner.isHoldingInput || machine?.hasHeldInput == true }

    /// The releases done since the last call, for the log (at most the last 64 are kept).
    public mutating func takeReleaseRecords() -> [ReleaseRecord] {
        defer { records.removeAll() }
        return records
    }

    /// PIPE-*: a new approved session. Owed releases go out first (if the permission is there), leftovers on the Mac
    /// (there should be none) are released, then the session gets a FRESH machine, latched from the start
    /// (PROTOCOL.md section 4).
    public mutating func sessionStarted(now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        var out = replayOwed(now: now, environment: env, force: true)
        let leftovers = planner.releaseAll(environment: env)
        if !leftovers.isEmpty { record(ReleaseRecord(reason: "session_start", events: leftovers)) }
        out += emit(leftovers, now: now, environment: env)
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
        var out = replayOwed(now: now, environment: env, force: false)
        guard machine != nil else { return out }
        out += releaseIfGateLost(now: now, environment: env)
        let actions = machine?.handle(message, now: now) ?? []
        var produced = planner.plan(actions, environment: env, now: now)
        produced += reconcile(environment: env)
        return out + emit(produced, now: now, environment: env)
    }

    /// Watchdogs without a message; call when the timer at `nextDeadline(now:)` fires. Also the moment owed releases
    /// are retried when nothing else is going on.
    public mutating func tick(now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        var out = replayOwed(now: now, environment: env, force: false)
        guard machine != nil else { return out }
        out += releaseIfGateLost(now: now, environment: env)
        let actions = machine?.tick(now: now) ?? []
        var produced = planner.plan(actions, environment: env, now: now)
        produced += reconcile(environment: env)
        return out + emit(produced, now: now, environment: env)
    }

    /// When the next watchdog is due (see `InputStateMachine.nextDeadline(now:)`, which mutates for the same reason).
    public mutating func nextDeadline(now: UInt64) -> UInt64? {
        machine?.nextDeadline(now: now)
    }

    /// Releases everything: owed releases first, then the machine's release-all (its actions go through the planner),
    /// then the planner's own safety net for anything still on the Mac. Idempotent; safe with no session, no display
    /// and no permission.
    public mutating func release(_ cause: ReleaseCause, now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        lastReleaseCause = cause
        var out = replayOwed(now: now, environment: env, force: true)
        let actions = machine?.releaseAll(cause) ?? []
        var produced = planner.plan(actions, environment: env, now: now)
        produced += planner.releaseAll(environment: env)
        record(ReleaseRecord(reason: cause.logName, cause: cause, events: produced))
        out += emit(produced, now: now, environment: env)
        return out
    }

    /// The poster could not deliver these events (it could not build them, or the permission was gone when it tried).
    /// Closing events among them are kept and retried; the rest are dropped.
    /// - Parameter permitted: false when the reason was the missing permission (that costs no retry attempt).
    public mutating func postFailed(_ events: [MacEvent], now: UInt64, permitted: Bool) {
        owed.owe(events, now: now, countsAsAttempt: permitted)
    }

    /// Losing the display or the permission while the Mac holds our input releases it right away (the release itself
    /// is not gated), instead of waiting for the client to lift the pen.
    private mutating func releaseIfGateLost(now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        guard !env.isOpen, planner.isHoldingInput else { return [] }
        return release(.gateLost, now: now, environment: env)
    }

    /// Safety net: the planner can only hold what the machine holds. If it does not, release the leftover.
    private mutating func reconcile(environment env: InjectionEnvironment) -> [MacEvent] {
        guard planner.isHoldingInput, machine?.hasHeldInput != true else { return [] }
        reconciliations += 1
        return planner.releaseAll(environment: env)
    }

    /// Events about to be posted. Without permission macOS drops them, so their closing ones are owed.
    private mutating func emit(_ produced: [MacEvent], now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        if !env.canInject { owed.owe(produced, now: now, countsAsAttempt: false) }
        return produced
    }

    /// The owed releases that are due, if the permission is there. They go before anything new.
    private mutating func replayOwed(now: UInt64, environment env: InjectionEnvironment, force: Bool) -> [MacEvent] {
        guard env.canInject, !owed.isEmpty else { return [] }
        let (events, gaveUp) = owed.replay(now: now, force: force, geometry: env.geometry)
        if !events.isEmpty { record(ReleaseRecord(reason: "owed_replay", events: events)) }
        if gaveUp > 0 { record(ReleaseRecord(reason: "owed_giveup", events: [], gaveUp: gaveUp)) }
        return events
    }

    private mutating func record(_ r: ReleaseRecord) {
        if records.count >= 64 { records.removeFirst() }
        records.append(r)
    }
}
