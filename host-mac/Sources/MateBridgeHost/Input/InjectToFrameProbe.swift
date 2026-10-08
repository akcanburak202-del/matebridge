import Foundation
import MateBridgeCore

/// T-323: the Host side of the "input injected -> first changed frame" measurement. `InputController` notes every
/// posted press edge, `ScreenCapture` notes every `complete` frame with a non-empty dirty rect, and a 2 s timer (plus
/// the session end) writes the `video ev=inject_to_frame` line when 10 s are over and there are samples. Diagnostics
/// only; the Core (`InjectToFrameMeter`) does the matching.
///
/// One meter serves one session at a time: it is reset when a session starts and ended, and `generation` changes at
/// every end, so a capture callback that outlives its session (`ScreenCapture` remembers the generation it started
/// under) cannot feed the next one.
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

    /// The token a `ScreenCapture` takes when it starts.
    var generation: UInt64 { lock.withLock { currentGeneration } }

    func beginSession(sessionID: UInt32, configID: UInt16) {
        meter.reset()
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.report() }
        let old: DispatchSourceTimer? = lock.withLock {
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
        report(force: true)
        let old: DispatchSourceTimer? = lock.withLock {
            currentGeneration &+= 1
            let previous = timer
            timer = nil
            return previous
        }
        old?.cancel()
        meter.reset()
    }

    /// A press edge was posted (call right after the CGEvent post returned).
    func noteInjection() {
        meter.noteInjection(atUs: HostClock.nowUs())
    }

    /// A `complete` frame arrived; `dirty` is false when SCK reported an empty dirty rect list. `captureUs` is the
    /// frame's capture timestamp (0 when unknown). Ignored when `generation` is not the current one.
    func noteFrame(generation: UInt64, dirty: Bool, arrivalUs: UInt64, captureUs: UInt64) {
        guard dirty, self.generation == generation else { return }
        meter.noteDirtyFrame(atUs: arrivalUs, captureUs: captureUs)
    }

    func report(nowUs: UInt64 = HostClock.nowUs(), force: Bool = false) {
        guard let fields = meter.takeReport(nowUs: nowUs, force: force) else { return }
        let ids = lock.withLock { (sessionID, configID) }
        logger.log(.info, "inject_to_frame", sessionID: ids.0, generation: ids.1, fields: fields)
    }
}
