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
/// and closing events the poster reports as failed (`postFailed`), are kept in `owed` until they are posted (they are
/// never given up on) and replayed first, before any new input, when the permission is back, at the next retry,
/// session start and shutdown (see `OwedRelease`).
///
/// Ordering. While anything is owed, or a replay has been handed out and not yet confirmed, the input gate is closed
/// for OPENING events exactly as if the permission or the display were missing (`InjectionEnvironment.opensBlocked`):
/// opens are dropped and counted, closing events still flow and join the owed set, and the machine keeps its own
/// state, so a finger that is still down does not turn into a phantom press later. Otherwise an older release that is
/// retried later would overtake, and release, a newer press. Input opens again once the owed set is empty and the last
/// replay has been confirmed by the next entry point.
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
    /// Pinch gestures the machine ended on its own since the last `takePinchForcedEnds()` (for the log).
    private var pinchForcedEnds: [PinchEndCause] = []
    private var machineConfiguration: InputStateMachine.Configuration

    public init(planner: InjectionPlanner.Configuration = .init(), machine: InputStateMachine.Configuration = .init()) {
        self.planner = InjectionPlanner(configuration: planner)
        machineConfiguration = machine
    }

    /// The configuration the NEXT session's machine starts with (the current one keeps its own). The Host refreshes
    /// the key repeat settings from macOS here before each session.
    public mutating func setMachineConfiguration(_ configuration: InputStateMachine.Configuration) {
        machineConfiguration = configuration
    }

    /// The configuration new sessions start with.
    public var nextMachineConfiguration: InputStateMachine.Configuration { machineConfiguration }

    public var hasSession: Bool { machine != nil }

    /// Anything held on the Mac, or by the machine.
    public var isHoldingInput: Bool { planner.isHoldingInput || machine?.hasHeldInput == true }

    /// The causes of the pinch gestures the host ended itself since the last call, oldest first (the `cause` of the
    /// `pinch_forced_end` log event). Collected from the machine after every call into it, so none is lost when the
    /// machine goes away with its session.
    public mutating func takePinchForcedEnds() -> [PinchEndCause] {
        defer { pinchForcedEnds.removeAll() }
        return pinchForcedEnds
    }

    private mutating func collectPinchEnds() {
        guard machine != nil else { return }
        let ends = machine?.takePinchForcedEnds() ?? []
        if pinchForcedEnds.count + ends.count > 64 { pinchForcedEnds.removeFirst(pinchForcedEnds.count + ends.count - 64) }
        pinchForcedEnds += ends
    }

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
        collectPinchEnds()
        let gated = gating(env)
        var produced = planner.plan(actions, environment: gated, now: now)
        produced += reconcile(environment: gated)
        return out + emit(produced, now: now, environment: env)
    }

    /// Watchdogs without a message; call when the timer at `nextDeadline(now:)` fires. Also the moment owed releases
    /// are retried when nothing else is going on.
    public mutating func tick(now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        var out = replayOwed(now: now, environment: env, force: false)
        guard machine != nil else { return out }
        out += releaseIfGateLost(now: now, environment: env)
        let actions = machine?.tick(now: now) ?? []
        collectPinchEnds()
        let gated = gating(env)
        var produced = planner.plan(actions, environment: gated, now: now)
        produced += reconcile(environment: gated)
        return out + emit(produced, now: now, environment: env)
    }

    /// A record was received on the active session's control connection at `time` (T-163, see
    /// `InputStateMachine.noteControlActivity(at:)`): call it after that record was handled. True when it ended a stall
    /// pause of the key repeat, so the caller must re-arm its timer from `nextDeadline(now:)`. False with no session.
    @discardableResult
    public mutating func noteControlActivity(at time: UInt64) -> Bool {
        machine?.noteControlActivity(at: time) ?? false
    }

    /// The coalesced activity of a `ControlActivityMailbox` (T-163, see `InputStateMachine.noteControlActivity(_:)`):
    /// hand it over before running the machine. Same result as `noteControlActivity(at:)`.
    @discardableResult
    public mutating func noteControlActivity(_ handoff: ControlActivityHandoff) -> Bool {
        machine?.noteControlActivity(handoff) ?? false
    }

    /// True while the current session's key repeat is armed but paused by a silent control connection (T-163).
    public func isKeyRepeatPaused(at now: UInt64) -> Bool {
        machine?.isKeyRepeatPaused(at: now) ?? false
    }

    /// When the next watchdog is due (see `InputStateMachine.nextDeadline(now:)`, which mutates for the same reason).
    public mutating func nextDeadline(now: UInt64) -> UInt64? {
        machine?.nextDeadline(now: now)
    }

    /// When the next retry of an owed release is due, or nil when nothing is owed. Only worth waking for while the
    /// permission is there: without it a retry is impossible (the host then relies on its 1 s poll).
    public var nextOwedRetry: UInt64? { owed.nextRetryAt }

    /// Releases everything: owed releases first, then the machine's release-all (its actions go through the planner),
    /// then the planner's own safety net for anything still on the Mac. Idempotent; safe with no session, no display
    /// and no permission.
    public mutating func release(_ cause: ReleaseCause, now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        performRelease(cause, now: now, environment: env, replayingOwed: true)
    }

    private mutating func performRelease(_ cause: ReleaseCause, now: UInt64, environment env: InjectionEnvironment,
                                         replayingOwed: Bool) -> [MacEvent] {
        lastReleaseCause = cause
        var out = replayingOwed ? replayOwed(now: now, environment: env, force: true) : []
        let actions = machine?.releaseAll(cause) ?? []
        collectPinchEnds()
        var produced = planner.plan(actions, environment: env, now: now)
        produced += planner.releaseAll(environment: env)
        record(ReleaseRecord(reason: cause.logName, cause: cause, events: produced))
        out += emit(produced, now: now, environment: env)
        return out
    }

    /// The poster could not deliver these events (it could not build them, or the permission was gone when it tried).
    /// Closing events among them are kept and retried until they are posted; the opening ones are dropped, and the
    /// planner's shadow state forgets what they would have opened.
    /// - Parameter permitted: false when the reason was the missing permission (that costs no retry attempt).
    public mutating func postFailed(_ events: [MacEvent], now: UInt64, permitted: Bool) {
        let slowedBefore = owed.slowed
        planner.notPosted(events)
        // A release whose opening is in the same failed batch closes something that never reached the Mac: it is
        // cancelled with it instead of being owed. (A release of something posted earlier is owed as usual.)
        var neverOpened: Set<OwedRelease.Slot> = []
        var toOwe: [MacEvent] = []
        for event in events {
            if let slot = OwedRelease.Slot(closing: event) {
                neverOpened.insert(slot)
            } else if event.isClosing, let slot = OwedRelease.Slot(event), neverOpened.contains(slot) {
                neverOpened.remove(slot)
            } else {
                toOwe.append(event)
            }
        }
        owed.owe(toOwe, now: now, countsAsAttempt: permitted)
        // Logged once per slot when its retries drop to the slow cadence (they never stop).
        if owed.slowed > slowedBefore { record(ReleaseRecord(reason: "owed_slow", events: [], slowed: owed.slowed - slowedBefore)) }
    }

    /// Shutdown drain: retries what is still owed right now, ignoring the retry spacing, up to `attempts` times with
    /// `pause` between them (the caller decides what a pause is: a short sleep on the host, nothing in a test).
    /// Stops at once, without spinning, when the permission is missing (nothing can be posted then), and as soon as
    /// nothing is owed. `post` posts a batch through the poster seam and reports what failed. Returns how many
    /// releases are still owed.
    public mutating func drainOwed(attempts: Int, now: () -> UInt64, environment: () -> InjectionEnvironment,
                                   post: ([MacEvent]) -> (failed: [MacEvent], permitted: Bool),
                                   pause: () -> Void) -> Int {
        var attempt = 0
        while attempt < attempts {
            owed.confirmPosted()
            if owed.isEmpty { break }
            let env = environment()
            guard env.canInject else { break }
            let t = now()
            let events = replayOwed(now: t, environment: env, force: true)
            if events.isEmpty { break }
            let result = post(events)
            if !result.failed.isEmpty { postFailed(result.failed, now: t, permitted: result.permitted) }
            attempt += 1
            if owed.isEmpty { break }
            if attempt < attempts { pause() }
        }
        owed.confirmPosted()
        return owed.count
    }

    /// Losing the display or the permission while the Mac holds our input releases it right away (the release itself
    /// is not gated), instead of waiting for the client to lift the pen.
    private mutating func releaseIfGateLost(now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        guard !env.isOpen, planner.isHoldingInput else { return [] }
        // The owed replay of this call (if any) has just been handed out: it must not be replayed or confirmed again.
        return performRelease(.gateLost, now: now, environment: env, replayingOwed: false)
    }

    /// The environment the planner sees for OPENING events: closed while anything is owed or unconfirmed.
    private func gating(_ env: InjectionEnvironment) -> InjectionEnvironment {
        var g = env
        g.opensBlocked = owed.isBlocking
        return g
    }

    /// Safety net: the planner can only hold what the machine holds. If it does not, release the leftover.
    private mutating func reconcile(environment env: InjectionEnvironment) -> [MacEvent] {
        guard planner.isHoldingInput, machine?.hasHeldInput != true else { return [] }
        reconciliations += 1
        return planner.releaseAll(environment: env)
    }

    /// Events about to be posted. Without permission macOS drops them, so their closing ones are owed. A pen leave
    /// produced while a pen up is still owed is held back into the owed set instead (it goes out right after the up):
    /// closing events flow, but the leave must not overtake the release it depends on.
    private mutating func emit(_ produced: [MacEvent], now: UInt64, environment env: InjectionEnvironment) -> [MacEvent] {
        if !env.canInject {
            owed.owe(produced, now: now, countsAsAttempt: false)
            return produced
        }
        guard owed.owesPenUp else { return produced }
        var flowing: [MacEvent] = []
        var held: [MacEvent] = []
        for event in produced {
            if case .tabletProximity(_, let entering) = event, !entering { held.append(event) } else { flowing.append(event) }
        }
        owed.owe(held, now: now, countsAsAttempt: false)
        return flowing
    }

    /// The owed releases that are due, if the permission is there. They go before anything new.
    private mutating func replayOwed(now: UInt64, environment env: InjectionEnvironment, force: Bool) -> [MacEvent] {
        owed.confirmPosted()  // the last replay, if nobody reported it failed, was posted
        guard env.canInject, !owed.isEmpty else { return [] }
        let events = owed.replay(now: now, force: force, geometry: env.geometry, keyboard: planner.keyboardSnapshot)
        if !events.isEmpty { record(ReleaseRecord(reason: "owed_replay", events: events)) }
        return events
    }

    private mutating func record(_ r: ReleaseRecord) {
        if records.count >= 64 { records.removeFirst() }
        records.append(r)
    }
}

// MARK: - Control activity mailbox (T-163)

/// What a `ControlActivityMailbox` hands to the machine: the newest receive time, and the newest record that followed
/// a receive gap longer than the stall pause (nil when there was none since the last hand-off).
public struct ControlActivityHandoff: Equatable, Sendable {
    public var latest: UInt64
    public var resumedAt: UInt64?
    public init(latest: UInt64, resumedAt: UInt64?) {
        self.latest = latest
        self.resumedAt = resumedAt
    }
}

/// KEY-REPEAT-STALL activity between the session queue (which notes every record of the active control connection)
/// and the input queue (which takes it before running the machine). A value type with no locking: the Host keeps it
/// under a lock, since it is written and read from two queues.
///
/// Coalescing keeps the real receive gaps: the gap is measured between CONSECUTIVE notes, never between hand-offs, so
/// records that arrived on time never look like a stall however rarely the input queue takes them, and a real gap is
/// never lost however many notes follow it before the next hand-off.
///
/// Wake-ups. The input queue disarms its repeat timer whenever the machine looks paused when it re-arms
/// (`setRepeatParked`). That can be a REAL stall, or only the input queue's view lagging the session queue: a record
/// arriving just under the stall pause after the previous one, handled while the threshold passes, is re-armed with the
/// activity from before it and is noted only afterwards. So a wake-up is asked for on a gap AND on any note while the
/// repeat is parked, and also when the repeat gets parked while a note is waiting to be taken. The machine itself only
/// resumes (and moves the next repeat) on a real gap; a wake-up without one just lets the timer see the newest time.
///
/// Wake-ups are bounded: at most one is outstanding (`wakePending`); only `takeForWake()`, the wake-up's own hand-off,
/// clears it, so at most one is ever queued however long the input queue is blocked.
public struct ControlActivityMailbox: Sendable {
    /// A gap longer than this between two notes is a stall (`InputStateMachine.Configuration.keyRepeatStallPauseUs`).
    public let stallGapUs: UInt64
    public private(set) var latest: UInt64?
    /// The newest note that followed a gap, not yet handed off.
    public private(set) var resumedAt: UInt64?
    /// A wake-up was requested and has not run yet.
    public private(set) var wakePending = false
    /// The input queue's last re-arm found an armed repeat paused, so its timer is not waiting for it.
    public private(set) var repeatParked = false
    /// Something was noted since the last hand-off.
    public private(set) var hasUntaken = false

    public init(stallGapUs: UInt64) {
        self.stallGapUs = stallGapUs
    }

    /// One record of the active session at `time`, after it was handled. Returns true when the caller must schedule a
    /// wake-up of the input queue: after a gap (it may have ended a pause whose repeat has no timer) or while the
    /// repeat is parked; false otherwise, including while a wake-up is already outstanding (it takes this note too).
    /// A clock that went backwards is no gap.
    public mutating func note(_ time: UInt64) -> Bool {
        defer { latest = time }
        hasUntaken = true
        var gap = false
        if let previous = latest, time > previous, time - previous > stallGapUs {
            resumedAt = time
            gap = true
        }
        return requestWake(if: gap || repeatParked)
    }

    /// The input queue re-armed its timer; `parked` is whether an armed repeat was paused then (no timer for it).
    /// Returns true when the caller must schedule a wake-up: the repeat got parked while a newer note is waiting.
    public mutating func setRepeatParked(_ parked: Bool) -> Bool {
        repeatParked = parked
        return requestWake(if: parked && hasUntaken)
    }

    /// The activity for the machine (nil when nothing was noted since the session started). Clears the gap.
    public mutating func take() -> ControlActivityHandoff? {
        hasUntaken = false
        guard let latest else { return nil }
        defer { resumedAt = nil }
        return ControlActivityHandoff(latest: latest, resumedAt: resumedAt)
    }

    /// The scheduled wake-up's hand-off: also clears the outstanding wake-up, so a later note may ask for a new one.
    public mutating func takeForWake() -> ControlActivityHandoff? {
        wakePending = false
        return take()
    }

    /// A new session: nothing of the previous one's activity carries over. An outstanding wake-up stays outstanding
    /// (its closure is still queued and will clear it).
    public mutating func reset() {
        latest = nil
        resumedAt = nil
        repeatParked = false
        hasUntaken = false
    }

    private mutating func requestWake(if needed: Bool) -> Bool {
        guard needed, !wakePending else { return false }
        wakePending = true
        return true
    }
}
