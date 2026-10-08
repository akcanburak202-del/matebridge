import Foundation
import MateBridgeCore
import Synchronization

/// The host's local cursor flow (decision 0036, docs/PROTOCOL.md 0x0B-0x0D and section 5): while the tablet has asked
/// for it (`CURSOR_PREFS(1)`), the Mac's cursor is sampled about 120 times a second and right after every injection, a
/// `CURSOR_STATE` (with the `CURSOR_SHAPE` it needs, once per shape) goes to the tablet, and the cursor is out of the
/// video.
///
/// `SessionServer` owns one and feeds it the session's events; it also writes what the service decides to send. The
/// pure decisions live in Core (`CursorStreamPlanner`, `CursorShapeCache`, `CursorOutbox`, `CursorStats`).
///
/// Threads and queues:
/// - the cursor queue (`queue`): sampling, the planner, the timer and the statistics; every sample is taken here,
///   never on the main thread, the session queue or the input queue;
/// - the session queue (`SessionServer.queue`): the writes. A sample that has to go out is parked in the outbox (one
///   waiting unit, the newest wins) and written from there once the previous unit is entirely in the socket
///   (PROTOCOL.md section 5); a state that waits never makes the control connection grow;
/// - `unitLock` guards the outbox, the shape cache and the sequence number, which both queues touch.
///
/// Input is never held up: the injection hook (`noteInjected`) only sets a flag and queues one coalesced sample.
final class CursorService: @unchecked Sendable {
    /// What `SessionServer` provides.
    struct Link: Sendable {
        /// Run on the session queue, soon.
        var onSessionQueue: @Sendable (@escaping @Sendable () -> Void) -> Void
        /// Session queue: sends the messages to the active control connection in order; `done` runs (on the session
        /// queue) once the last of them is entirely written, or at once when nothing could be sent. False when the
        /// session is not the active one any more.
        var send: @Sendable (_ sessionID: UInt32, _ messages: [Message], _ done: @escaping @Sendable () -> Void) -> Bool
    }

    /// One sample that goes out.
    private struct Unit: Sendable {
        var snapshot: CursorSnapshot
        var hostTimeUs: UInt64
    }

    static let pollInterval: DispatchTimeInterval = .nanoseconds(1_000_000_000 / 120)
    /// A second sample this long after an injection catches the position WindowServer applies a moment later.
    static let followUpDelay: DispatchTimeInterval = .microseconds(1_500)

    private let queue = DispatchQueue(label: "dev.matebridge.cursor", qos: .userInteractive)
    private let sampler: CursorSampler
    private let shapes: SharedShapeStore
    private let video: VideoCursorSwitch
    private let link: Link
    private let logger = SessionLogger(component: "cursor")

    // Cursor queue only.
    private var planner = CursorStreamPlanner()
    private var stats = CursorStats()
    private var timer: DispatchSourceTimer?
    private var retryScheduled = false
    private var sessionID: UInt32 = 0
    private var supported = false
    /// Changes at every session start and end: work queued for an old session is dropped.
    private var epoch = 0
    /// `VideoCursorSwitch.generation` of the live session, read when it starts: a video request of an ended session
    /// carries an older one and is refused by the switch.
    private var videoGeneration = 0
    private var warmedUp = false

    /// `CURSOR_PREFS` waiting for the cursor queue: one, newest wins, one wake-up (any thread, under `prefsLock`).
    private let prefsLock = NSLock()
    private var prefsBox = CursorPrefsMailbox()

    // Both queues, under `unitLock`.
    private let unitLock = NSLock()
    private var outbox = CursorOutbox<Unit>()
    private var cache = CursorShapeCache()
    private var nextSeq: UInt32 = 1
    private var writingSessionID: UInt32 = 0

    /// Any thread: true while samples are wanted (the planner is not `off`). Read by `noteInjected`.
    private let tracking = Atomic<Bool>(false)
    /// At most one injection sample is queued at a time.
    private let injectionSamplePending = Atomic<Bool>(false)

    init(link: Link, sampler: CursorSampler? = nil, shapes: SharedShapeStore = SharedShapeStore(),
         video: VideoCursorSwitch = .shared) {
        self.shapes = shapes
        self.sampler = sampler ?? CursorSampler(store: shapes)
        self.video = video
        self.link = link
        // What the video switch reports about the desire it was given (the capture has it, or refused it).
        video.onOutcome { [weak self] outcome in
            self?.queue.async { [weak self] in self?.videoOutcome(outcome) }
        }
    }

    // MARK: Session events (any thread; the session queue calls them)

    func sessionStarted(sessionID: UInt32, supported: Bool) {
        // Read now, in the caller's order of events: the previous session's `reset()` ran before this call and the next
        // one's will run after it, whenever the block below gets its turn.
        let generation = video.generation
        prefsLock.withLock { prefsBox.clear() }
        queue.async { [self] in
            epoch += 1
            self.sessionID = sessionID
            self.supported = supported
            videoGeneration = generation
            resetSession()
        }
    }

    /// The session is over (end, takeover, sleep, shutdown): the cursor goes back into the video and everything is
    /// forgotten. Safe to call more than once.
    func sessionEnded() {
        video.reset()  // the wish is back at once, whatever the cursor queue is doing
        prefsLock.withLock { prefsBox.clear() }
        queue.async { [self] in
            epoch += 1
            let wasOn = planner.phase != .off
            sessionID = 0
            supported = false
            resetSession()
            if wasOn { logger.log(.info, "cursor_prefs", sessionID: 0, generation: 0, fields: "enabled=0 reason=session_end") }
        }
    }

    /// `CURSOR_PREFS` of the active session. Bounded: one message waits, the newest, and one wake-up is queued however
    /// many arrive (a repeating tablet cannot grow the cursor queue).
    func prefs(sessionID: UInt32, enabled: Bool) {
        guard let token = prefsLock.withLock({ prefsBox.post(session: sessionID, enabled: enabled) }) else { return }
        queue.async { [self] in
            // A wake-up of an earlier session boundary gets nothing: the message waits for its own session's wake-up.
            guard let message = prefsLock.withLock({ prefsBox.take(token: token) }) else { return }
            guard message.session == self.sessionID, message.session != 0 else { return }
            guard supported else {
                logger.log(.info, "cursor_prefs", sessionID: message.session, generation: 0,
                           fields: "enabled=\(message.enabled ? 1 : 0) ignored=no_capability")
                return
            }
            logger.log(.info, "cursor_prefs", sessionID: message.session, generation: 0,
                       fields: "enabled=\(message.enabled ? 1 : 0)")
            execute(planner.prefs(enabled: message.enabled))
        }
    }

    /// An input message was just injected: sample the cursor now (and once more a moment later). Cheap when the flow is
    /// off (one atomic read); never blocks the caller.
    func noteInjected() {
        guard tracking.load(ordering: .relaxed) else { return }
        guard !injectionSamplePending.exchange(true, ordering: .relaxed) else { return }
        queue.async { [self] in
            injectionSamplePending.store(false, ordering: .relaxed)
            takeSample()
            queue.asyncAfter(deadline: .now() + Self.followUpDelay) { [self] in takeSample() }
        }
    }

    // MARK: Cursor queue

    private func resetSession() {
        planner.reset()
        stopTimer()
        tracking.store(false, ordering: .relaxed)
        unitLock.withLock {
            outbox.reset()
            cache.removeAll()
            nextSeq = 1
        }
        shapes.removeAll()
        sampler.resetSession()
        stats = CursorStats()
    }

    private func execute(_ commands: [CursorStreamPlanner.Command]) {
        for command in commands {
            switch command {
            case .startTracking:
                tracking.store(true, ordering: .relaxed)
                if !warmedUp {  // the first calls connect to WindowServer: before the first state, not in it
                    sampler.warmUp()
                    warmedUp = true
                }
                stats.restart(nowUs: HostClock.nowUs(), replaced: unitLock.withLock { outbox.replaced })
                startTimer()
                takeSample()  // the first sample: the tablet gets its shape and state before the video changes
            case .stopTracking:
                tracking.store(false, ordering: .relaxed)
                stopTimer()
                unitLock.withLock {
                    outbox.discardPending()
                    cache.removeAll()  // the tablet may drop its images when it turns the flow off
                }
            case .setVideoCursor(let shows):
                // Returns at once; the answer comes as an outcome. The desire carries this session's generation, so
                // the switch ignores it if the session is over by then (it cannot undo the session end's reset).
                video.request(shows: shows, generation: videoGeneration)
            }
        }
    }

    /// The video switch's report about the desire of this session (stale when it is about another one):
    /// - the capture has what was asked: the planner goes on;
    /// - a refusal: the video keeps (or does not get back) its cursor. A refused hide stops the flow (no second cursor;
    ///   the tablet times out and falls back) and the cursor is asked back into the video, which also puts it back in
    ///   a capture that came up hidden meanwhile; a refused show stops the flow too, and the switch keeps retrying.
    private func videoOutcome(_ outcome: VideoCursorReconciler.Outcome) {
        guard outcome.generation == videoGeneration, sessionID != 0 else { return }
        logger.log(outcome.ok ? .info : .warning, "cursor_video", sessionID: sessionID, generation: 0,
                   fields: "shows=\(outcome.shows ? 1 : 0) ok=\(outcome.ok ? 1 : 0)")
        if outcome.ok {
            if planner.expectedVideoShows == outcome.shows { execute(planner.videoCursorResult(ok: true)) }
            return
        }
        if planner.expectedVideoShows == outcome.shows {
            execute(planner.videoCursorResult(ok: false))
        } else if !outcome.shows {
            execute(planner.videoCursorLost())  // a hide nobody here was waiting for (a capture brought in line)
        }
        if !outcome.shows { video.request(shows: true, generation: videoGeneration) }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .nanoseconds(0))
        t.setEventHandler { [weak self] in self?.takeSample() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        retryScheduled = false
    }

    /// One reading, the planner's verdict, and what follows from it.
    private func takeSample() {
        guard planner.isTracking else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        let snapshot = sampler.sample()
        let costUs = (DispatchTime.now().uptimeNanoseconds &- start) / 1_000
        stats.recordSample(costUs: costUs, ok: snapshot != nil)
        if let snapshot {
            let nowUs = HostClock.nowUs()
            let observation = planner.observe(snapshot, nowUs: nowUs)
            if let send = observation.send { submit(Unit(snapshot: send, hostTimeUs: nowUs)) }
            execute(observation.commands)
            if let retry = observation.retryAtUs { scheduleRetry(atUs: retry, nowUs: nowUs) }
        }
        reportStats()
    }

    /// A changed sample was held back by the 8 ms interval: look again when it has passed (the next poll is at most
    /// one period away, this just removes the wait after a burst of injections).
    private func scheduleRetry(atUs: UInt64, nowUs: UInt64) {
        guard !retryScheduled else { return }
        retryScheduled = true
        let delayUs = atUs > nowUs ? atUs - nowUs : 0
        queue.asyncAfter(deadline: .now() + .microseconds(Int(min(delayUs, 20_000)))) { [self] in
            retryScheduled = false
            takeSample()
        }
    }

    private func reportStats() {
        let (replaced, shapesBuilt, shapeFailures) = (unitLock.withLock { outbox.replaced }, sampler.shapesBuilt,
                                                      sampler.shapeFailures)
        // Built and failed shapes are counted by the sampler for the whole run: report them as window deltas.
        while builtReported < shapesBuilt { stats.recordShapeBuilt(); builtReported += 1 }
        while failuresReported < shapeFailures { stats.recordShapeFailure(); failuresReported += 1 }
        let checks = sampler.shapeChecks
        while checksReported < checks { stats.recordShapeCheck(); checksReported += 1 }
        if let fields = stats.takeReport(nowUs: HostClock.nowUs(), replaced: replaced) {
            logger.log(.info, "cursor_stats", sessionID: sessionID, generation: 0, fields: fields)
        }
    }

    private var builtReported = 0
    private var failuresReported = 0
    private var checksReported = 0

    // MARK: Outbox (both queues)

    private func submit(_ unit: Unit) {
        let sid = sessionID
        let kick = unitLock.withLock { () -> Bool in
            writingSessionID = sid
            return outbox.submit(unit)
        }
        if kick { link.onSessionQueue { [self] in drain() } }
    }

    /// Session queue: writes the waiting unit when nothing is being written.
    private func drain() {
        var items: (unit: Unit, sid: UInt32, generation: Int, messages: [Message], shapeBytes: Int)?
        unitLock.withLock {
            guard let unit = outbox.take() else { return }
            let shapeID = unit.snapshot.shapeID
            var messages: [Message] = []
            var shapeBytes = 0
            var sent = shapeID
            if !cache.use(shapeID) {
                if let shape = shapes.shape(shapeID) {
                    messages.append(.cursorShape(shape))
                    shapeBytes = shape.data.count
                } else {
                    cache.forget(shapeID)  // pushed out of the store: the built-in arrow, never claimed as sent
                    sent = 0
                }
            }
            let state = CursorState(seq: nextSeq, x: unit.snapshot.x, y: unit.snapshot.y,
                                    visible: unit.snapshot.visible, shapeID: sent, hostTimeUs: unit.hostTimeUs)
            nextSeq &+= 1
            messages.append(.cursorState(state))
            items = (unit, writingSessionID, outbox.generation, messages, shapeBytes)
        }
        guard let items else { return }
        let generation = items.generation
        let accepted = link.send(items.sid, items.messages) { [self] in
            unitLock.withLock { outbox.completed(generation: generation) }
            drain()  // already on the session queue
        }
        guard accepted else {
            // Not the active session any more: nothing will complete this unit.
            unitLock.withLock { outbox.completed(generation: generation) }
            return
        }
        queue.async { [self] in
            stats.recordState()
            if items.shapeBytes > 0 { stats.recordShapeSent(bytes: items.shapeBytes) }
        }
    }
}
