import Foundation
import MateBridgeCore

/// T-323: the Host side of the "input injected -> first changed frame" measurement. `InputController` notes every
/// posted press edge, `ScreenCapture` notes every `complete` frame with a non-empty dirty rect, and either side
/// writes the `video ev=inject_to_frame` line when 10 s are over and there are samples. Diagnostics only; the Core
/// (`InjectToFrameMeter`) does the matching.
final class InjectToFrameProbe: @unchecked Sendable {
    static let shared = InjectToFrameProbe()

    private let meter = InjectToFrameMeter()
    private let logger = SessionLogger(component: "video")
    private let lock = NSLock()
    private var sessionID: UInt32 = 0
    private var configID: UInt16 = 0

    func setSession(sessionID: UInt32, configID: UInt16) {
        lock.withLock {
            self.sessionID = sessionID
            self.configID = configID
        }
    }

    /// A press edge was posted (call right after the CGEvent post returned).
    func noteInjection() {
        let now = HostClock.nowUs()
        meter.noteInjection(atUs: now)
    }

    /// A `complete` frame arrived; `dirty` is false when SCK reported an empty dirty rect list.
    func noteFrame(dirty: Bool, arrivalUs: UInt64) {
        if dirty { meter.noteDirtyFrame(atUs: arrivalUs) }
        report(nowUs: arrivalUs)
    }

    func report(nowUs: UInt64 = HostClock.nowUs()) {
        guard let fields = meter.takeReport(nowUs: nowUs) else { return }
        let ids = lock.withLock { (sessionID, configID) }
        logger.log(.info, "inject_to_frame", sessionID: ids.0, generation: ids.1, fields: fields)
    }
}
