/// When the host captures and streams system audio (decision 0011, PROTOCOL.md 0x30 host rules). Pure: no I/O,
/// no clock. The caller turns the actions into capture start/stop, AUDIO_CONFIG sends, timers and log lines, in order.
///
/// - Audio runs only while all hold: an ACCEPTED (encrypted) session, the client's HELLO has `AUDIO_PCM`, its last
///   `AUDIO_PREFS.enabled` is 1, and `MATEBRIDGE_AUDIO=off` is not set.
/// - `AUDIO_CONFIG(STARTED)` with a fresh `stream_id` goes out once the capture actually runs.
/// - `enabled = 0` stops at once and sends `AUDIO_CONFIG(STOPPED)` (the connection is open). Session end (BYE,
///   control connection lost, superseded, shutdown) stops at once and sends nothing: there is no one to tell.
/// - A capture failure (permission denied, no device, Core Audio error) is logged once per session as
///   `audio_unavailable`; no audio is sent and the session goes on. Re-enabling (`enabled` 0 then 1) retries.
/// - An interruption (default output changed, device gone, format changed, wake from sleep) sends STOPPED for the
///   running stream and rebuilds the capture as a new stream. A rebuild that fails is retried
///   `rebuildRetries` times, `rebuildRetryDelayUs` apart (devices are often briefly unavailable right after a wake)
///   before the failure counts.
/// - A transient start failure (`AudioCaptureFailure.isTransient`: tap or aggregate creation, seen right after the
///   previous capture was torn down) is retried first, `transientRetryDelaysUs` apart (growing), each as a new stream,
///   logged `audio_retry`. Only when those run out does the failure follow the rules above. A session end or a disable
///   while a retry waits cancels it (the timer's token no longer matches).
public struct AudioStreamPolicy: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Build tap + aggregate + IOProc for stream `streamID` (the capture's token).
        case startCapture(streamID: UInt16)
        /// Tear the capture of `streamID` down now.
        case stopCapture(streamID: UInt16)
        /// Send on the control connection of session `sessionID`.
        case send(sessionID: UInt32, AudioConfig)
        /// Call `retryDue(token:)` after `delayUs`.
        case scheduleRetry(token: UInt32, delayUs: UInt64)
        case log(LogLevel, ev: String, fields: String)
    }

    public static let sampleRate: UInt32 = 48_000
    public static let channels: UInt8 = 2
    public static let framesPerPacket: UInt16 = 480
    /// Extra attempts after a failed rebuild (decision: 2 tries, 1 s apart).
    public static let rebuildRetries = 2
    public static let rebuildRetryDelayUs: UInt64 = 1_000_000
    /// Delays before each retry of a transient start failure (T-119): 4 attempts, about 1.85 s in all.
    public static let transientRetryDelaysUs: [UInt64] = [100_000, 250_000, 500_000, 1_000_000]

    private struct Session: Equatable, Sendable {
        var id: UInt32
        var clientSupportsAudio: Bool
        var enabled = false
        var failed = false
        var unavailableLogged = false
    }

    private enum Capture: Equatable, Sendable {
        case idle
        case starting(UInt16)
        case running(UInt16)
        /// A rebuild failed; the next attempt is due when `retryDue(token)` comes.
        case waitingRetry(token: UInt32)
    }

    public let disabled: Bool
    private var session: Session?
    private var capture: Capture = .idle
    private var lastStreamID: UInt16 = 0
    private var disabledLogged = false
    /// Rebuild attempts left after an interruption; 0 outside a rebuild.
    private var retriesLeft = 0
    /// Transient start failures retried since the last start, interruption or stop.
    private var transientRetries = 0
    private var retryToken: UInt32 = 0

    /// - Parameter disabled: `MATEBRIDGE_AUDIO=off`: never capture.
    public init(disabled: Bool) {
        self.disabled = disabled
    }

    /// Stream currently running (STARTED sent), if any.
    public var runningStreamID: UInt16? {
        if case .running(let id) = capture { return id }
        return nil
    }

    public var sessionID: UInt32? { session?.id }

    public static func startedConfig(streamID: UInt16) -> AudioConfig {
        AudioConfig(streamID: streamID, state: .started, format: .pcmS16LE, sampleRate: sampleRate,
                    channels: channels, framesPerPacket: framesPerPacket)
    }

    // MARK: Events

    /// A session became ACCEPTED (and encrypted). A previous one, if still known, ends first.
    public mutating func sessionStarted(sessionID: UInt32, clientSupportsAudio: Bool) -> [Action] {
        var actions = sessionEnded()
        session = Session(id: sessionID, clientSupportsAudio: clientSupportsAudio)
        actions.append(.log(.info, ev: "audio_session", fields: "audio_pcm=\(clientSupportsAudio ? 1 : 0)"))
        return actions
    }

    /// `AUDIO_PREFS` from the active session.
    public mutating func prefs(sessionID: UInt32, enabled: Bool) -> [Action] {
        guard var s = session, s.id == sessionID else { return [] }
        if enabled, !s.enabled { s.failed = false }  // an explicit re-enable retries a failed capture
        s.enabled = enabled
        session = s
        var actions: [Action] = []
        if enabled, disabled, !disabledLogged {
            disabledLogged = true
            actions.append(.log(.info, ev: "audio_unavailable", fields: "reason=disabled_by_env"))
        }
        return actions + reconcile(stopReason: "prefs")
    }

    /// The session ended for any reason: stop now, tell no one.
    public mutating func sessionEnded() -> [Action] {
        guard session != nil else { return [] }
        session = nil
        return stop(sendStopped: false, reason: "session_end")
    }

    /// The capture of `streamID` runs (IOProc started).
    public mutating func captureStarted(streamID: UInt16) -> [Action] {
        guard capture == .starting(streamID), let s = session else { return [] }
        capture = .running(streamID)
        retriesLeft = 0
        transientRetries = 0
        return [.send(sessionID: s.id, Self.startedConfig(streamID: streamID)),
                .log(.info, ev: "audio_started", fields: "stream_id=\(streamID)")]
    }

    /// The capture of `streamID` could not start or broke down. `reason` is a short token, `status` the OSStatus.
    public mutating func captureFailed(streamID: UInt16, reason: String, status: Int32) -> [Action] {
        guard capture == .starting(streamID) || capture == .running(streamID), var s = session else { return [] }
        let wasRunning = capture == .running(streamID)
        capture = .idle
        var actions: [Action] = [.stopCapture(streamID: streamID)]
        if wasRunning { actions.append(.send(sessionID: s.id, .stopped(streamID: streamID))) }
        if !wasRunning, AudioCaptureFailure.isTransient(reason),
           transientRetries < Self.transientRetryDelaysUs.count {
            // Core Audio is likely still removing the previous capture: try again shortly, as a new stream.
            let delayUs = Self.transientRetryDelaysUs[transientRetries]
            transientRetries += 1
            retryToken &+= 1
            capture = .waitingRetry(token: retryToken)
            return actions + [
                .scheduleRetry(token: retryToken, delayUs: delayUs),
                .log(.info, ev: "audio_retry",
                     fields: "reason=\(reason) attempt=\(transientRetries) delay_ms=\(delayUs / 1000) status=\(status) "
                         + "stream_id=\(streamID)"),
            ]
        }
        if !wasRunning, retriesLeft > 0 {
            // A rebuild after an interruption failed: try again shortly before giving up.
            retriesLeft -= 1
            retryToken &+= 1
            capture = .waitingRetry(token: retryToken)
            return actions + [
                .scheduleRetry(token: retryToken, delayUs: Self.rebuildRetryDelayUs),
                .log(.info, ev: "audio_rebuild_retry",
                     fields: "reason=\(reason) status=\(status) stream_id=\(streamID) left=\(retriesLeft)"),
            ]
        }
        retriesLeft = 0
        transientRetries = 0
        s.failed = true
        if !s.unavailableLogged {
            s.unavailableLogged = true
            actions.append(.log(.warning, ev: "audio_unavailable",
                                fields: "reason=\(reason) status=\(status) stream_id=\(streamID)"))
        }
        session = s
        return actions
    }

    /// The capture of `streamID` has to be rebuilt (device change, device gone, format change, wake): STOPPED for
    /// the running stream, then a new stream.
    public mutating func captureInterrupted(streamID: UInt16, reason: String) -> [Action] {
        guard capture == .starting(streamID) || capture == .running(streamID) else { return [] }
        let wasRunning = capture == .running(streamID)
        capture = .idle
        retriesLeft = Self.rebuildRetries
        transientRetries = 0
        var actions: [Action] = [.stopCapture(streamID: streamID)]
        if wasRunning, let s = session { actions.append(.send(sessionID: s.id, .stopped(streamID: streamID))) }
        actions.append(.log(.info, ev: "audio_rebuild", fields: "reason=\(reason) stream_id=\(streamID)"))
        return actions + reconcile(stopReason: reason)
    }

    /// The retry timer of `token` fired.
    public mutating func retryDue(token: UInt32) -> [Action] {
        guard capture == .waitingRetry(token: token) else { return [] }
        capture = .idle
        return reconcile(stopReason: "retry")
    }

    // MARK: Internals

    private var wanted: Bool {
        guard let s = session else { return false }
        return !disabled && s.clientSupportsAudio && s.enabled && !s.failed
    }

    private mutating func reconcile(stopReason: String) -> [Action] {
        if wanted {
            guard capture == .idle else { return [] }
            let id = nextStreamID()
            capture = .starting(id)
            return [.startCapture(streamID: id)]
        }
        return stop(sendStopped: true, reason: stopReason)
    }

    private mutating func stop(sendStopped: Bool, reason: String) -> [Action] {
        retriesLeft = 0
        transientRetries = 0
        switch capture {
        case .idle:
            return []
        case .waitingRetry:
            capture = .idle  // nothing runs; the pending timer finds no match
            return []
        case .starting(let id):
            capture = .idle  // STARTED was never sent: nothing to take back
            return [.stopCapture(streamID: id)]
        case .running(let id):
            capture = .idle
            var actions: [Action] = [.stopCapture(streamID: id)]
            if sendStopped, let s = session { actions.append(.send(sessionID: s.id, .stopped(streamID: id))) }
            actions.append(.log(.info, ev: "audio_stopped", fields: "stream_id=\(id) reason=\(reason)"))
            return actions
        }
    }

    /// 1, 2, ... and never 0 (PROTOCOL.md 0x31: starts at 1).
    private mutating func nextStreamID() -> UInt16 {
        lastStreamID &+= 1
        if lastStreamID == 0 { lastStreamID = 1 }
        return lastStreamID
    }
}
