import Foundation

/// Whether the video shows the Mac's cursor (decision 0036): one process-wide wish, applied to whatever capture runs.
///
/// The wish outlives a capture: a capture that starts later (a settings change, a new display) starts with it, and a
/// capture that is already running gets it through `ScreenCapture.setShowsCursor` (`SCStream.updateConfiguration`,
/// the stream is not rebuilt). Default and fallback: the cursor is in the video, as before decision 0036.
///
/// Changes are applied one after the other, in the order asked, and a request that a newer one overtook is skipped
/// (`reset()` at a session end must win over a hide still waiting). Where it is wired in, `ScreenCapture` is the only
/// user of the wish and `CursorService` the only writer.
final class VideoCursorSwitch: @unchecked Sendable {
    static let shared = VideoCursorSwitch()

    private let lock = NSLock()
    private var wantsCursor = true
    private weak var capture: ScreenCapture?
    /// The newest request; an older one that has not started applying yet is skipped.
    private var latestEpoch = 0
    private var tail: Task<Void, Never>?
    private let logger = SessionLogger(component: "cursor")

    /// What a capture that starts now must do: true = cursor in the video.
    var showsCursor: Bool { lock.withLock { wantsCursor } }

    /// A capture is running. If the wish changed while it started, it is brought in line.
    func attach(_ capture: ScreenCapture) {
        let (want, differs) = lock.withLock { () -> (Bool, Bool) in
            self.capture = capture
            return (wantsCursor, capture.showsCursorNow != wantsCursor)
        }
        if differs { Task { _ = await set(shows: want) } }
    }

    func detach(_ capture: ScreenCapture) {
        lock.withLock { if self.capture === capture { self.capture = nil } }
    }

    /// Asks for the cursor in (`true`) or out of (`false`) the video and waits for the running capture to say it is
    /// done. True also when no capture runs (the next one starts with the wish) or when a newer request overtook this
    /// one. False when ScreenCaptureKit refused: the wish then goes back to what the capture still has.
    func set(shows: Bool) async -> Bool {
        let (epoch, previous) = lock.withLock { () -> (Int, Task<Void, Never>?) in
            latestEpoch += 1
            return (latestEpoch, tail)
        }
        let work = Task<Bool, Never> { [self] in
            _ = await previous?.value
            return await apply(shows, epoch: epoch)
        }
        lock.withLock { tail = Task { _ = await work.value } }
        return await work.value
    }

    /// A session ended: the cursor goes back into the video. The wish is back at once (a capture that starts now gets
    /// it); a running capture follows as soon as it can.
    func reset() {
        let capture = lock.withLock { () -> ScreenCapture? in
            latestEpoch += 1  // everything waiting is overtaken
            wantsCursor = true
            return self.capture
        }
        // Always, even if the capture shows the cursor right now: a hide may be on its way (it finishes first, the
        // restore follows it).
        guard capture != nil else { return }
        Task { _ = await set(shows: true) }
    }

    private func apply(_ shows: Bool, epoch: Int) async -> Bool {
        let (overtaken, running) = lock.withLock { () -> (Bool, ScreenCapture?) in
            guard epoch == latestEpoch else { return (true, nil) }
            wantsCursor = shows
            return (false, capture)
        }
        guard !overtaken, let capture = running else { return true }  // none running: the next one starts with the wish
        guard capture.showsCursorNow != shows else { return true }
        do {
            try await capture.setShowsCursor(shows)
            return true
        } catch {
            // The capture keeps what it has; the wish follows it.
            let actual = capture.showsCursorNow
            lock.withLock { if epoch == latestEpoch { wantsCursor = actual } }
            logger.log(.warning, "cursor_video_failed", sessionID: 0, generation: 0,
                       fields: "shows=\(shows ? 1 : 0) error=\((error as NSError).domain)_\((error as NSError).code)")
            return false
        }
    }
}
