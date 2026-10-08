import Foundation
import MateBridgeCore

/// T-323: the Host side of the "input injected -> first changed frame" measurement. `InputController` notes every
/// posted press edge, `ScreenCapture` notes every `complete` frame with a non-empty dirty rect, and a 2 s timer (plus
/// the session end) writes the `video ev=inject_to_frame` line when 10 s are over and there are samples. Diagnostics
/// only; the Core (`InjectToFrameMeter`) does the matching.
///
/// One meter serves one session at a time: it is reset when a session starts and ended, and `generation` changes at
/// every end, so a capture callback that outlives its session (a `VideoPipeline` takes the generation when it is
/// created and hands it to its `ScreenCapture`) cannot feed the next one. Session transitions, frame validation +
/// meter update and report extraction all run under one lock, so none of them straddles a transition and a report
/// always carries the ids of the samples it holds.
final class InjectToFrameProbe: @unchecked Sendable {
    static let shared = InjectToFrameProbe()

    private let meter = InjectToFrameMeter()
    private let logger = SessionLogger(component: "video")
    private let lock = NSLock()
    private var sessionID: UInt32 = 0
    private var configID: UInt16 = 0
    private var currentGeneration: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "matebridge.inject-to-frame", qos: .utility)

    /// The token a pipeline takes when it is created (and keeps for its capture's whole life).
    var generation: UInt64 { lock.withLock { currentGeneration } }

    func beginSession(sessionID: UInt32, configID: UInt16) {
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.report() }
        let old: DispatchSourceTimer? = lock.withLock {
            meter.reset()
            self.sessionID = sessionID
            self.configID = configID
            let previous = timer
            timer = t
            return previous
        }
        old?.cancel()
        t.resume()
    }

    /// Reports what is left under the ending session's ids, then forgets it and invalidates its capture callbacks.
    func endSession() {
        let (fields, ids, old): (String?, (UInt32, UInt16), DispatchSourceTimer?) = lock.withLock {
            let f = meter.takeReport(nowUs: HostClock.nowUs(), force: true)
            let ids = (sessionID, configID)
            currentGeneration &+= 1
            meter.reset()
            let previous = timer
            timer = nil
            return (f, ids, previous)
        }
        old?.cancel()
        if let f = fields { logger.log(.info, "inject_to_frame", sessionID: ids.0, generation: ids.1, fields: f) }
    }

    /// A press edge was posted (call right after the CGEvent post returned).
    func noteInjection() {
        let now = HostClock.nowUs()
        lock.withLock { meter.noteInjection(atUs: now) }
    }

    /// A `complete` frame arrived; `dirty` is false when SCK reported an empty dirty rect list. `captureUs` is the
    /// frame's capture timestamp (0 when unknown). Ignored when `generation` is not the current one.
    func noteFrame(generation: UInt64, dirty: Bool, arrivalUs: UInt64, captureUs: UInt64) {
        guard dirty else { return }
        lock.withLock {
            guard currentGeneration == generation else { return }
            meter.noteDirtyFrame(atUs: arrivalUs, captureUs: captureUs)
        }
    }

    func report(nowUs: UInt64 = HostClock.nowUs()) {
        let r: (String, UInt32, UInt16)? = lock.withLock {
            meter.takeReport(nowUs: nowUs).map { ($0, sessionID, configID) }
        }
        if let r { logger.log(.info, "inject_to_frame", sessionID: r.1, generation: r.2, fields: r.0) }
    }
}
