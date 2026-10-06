import Foundation
import MateBridgeCore

/// Whether the video shows the Mac's cursor (decision 0036): one process-wide wish (`VideoCursorWish`), applied to
/// whatever capture runs.
///
/// The wish outlives a capture: a capture that starts later (a settings change, a new display, a display wake) starts
/// with it (`showsCursor`), and a capture that is already running gets it through `ScreenCapture.setShowsCursor`
/// (`SCStream.updateConfiguration`, the stream is not rebuilt). Default and fallback: the cursor is in the video, as
/// before decision 0036; a failed change never leaves the wish on "hidden", and a failed *show* is retried with a
/// bounded backoff (0.25 s doubling to 8 s) until it works or something newer asks otherwise.
///
/// Requests are applied one after the other. A hide carries the generation of the session that asked (`generation`
/// is read when the session starts): `reset()` at a session end starts a new one, so a hide still on its way from the
/// ended session is refused and can never hide the cursor of the next session. `CursorService` is the only writer,
/// `ScreenCapture` the only reader.
final class VideoCursorSwitch: @unchecked Sendable {
    static let shared = VideoCursorSwitch()

    private let lock = NSLock()
    private var wish = VideoCursorWish()
    private weak var capture: ScreenCapture?
    private var tail: Task<Void, Never>?
    private let logger = SessionLogger(component: "cursor")

    /// What a capture that starts now must do: true = cursor in the video.
    var showsCursor: Bool { lock.withLock { wish.wantsCursor } }

    /// The live session generation: read when a session starts, passed to `set`.
    var generation: Int { lock.withLock { wish.generation } }

    /// A capture is running. If the wish differs from what it was started with (it changed while it started), the
    /// wish wins and the capture is brought in line.
    func attach(_ capture: ScreenCapture) {
        let ticket = lock.withLock { () -> VideoCursorWish.Ticket? in
            self.capture = capture
            let want = wish.wantsCursor
            return capture.showsCursorNow != want ? wish.request(shows: want, generation: nil) : nil
        }
        if let ticket { Task { _ = await run(ticket, attempt: 0) } }
    }

    func detach(_ capture: ScreenCapture) {
        lock.withLock { if self.capture === capture { self.capture = nil } }
    }

    /// Asks, for the session of `generation`, for the cursor in (`true`) or out of (`false`) the video and waits for
    /// the running capture to say it is done. True also when no capture runs (the next one starts with the wish), when
    /// a newer request overtook this one, or when the session is over. False when ScreenCaptureKit refused (a refused
    /// show is retried by itself).
    func set(shows: Bool, generation: Int) async -> Bool {
        guard let ticket = lock.withLock({ wish.request(shows: shows, generation: generation) }) else { return true }
        return await run(ticket, attempt: 0)
    }

    /// A session ended: the cursor goes back into the video. The wish is back at once (a capture that starts now gets
    /// it), everything on its way from the session is void, and a running capture follows as soon as it can.
    func reset() {
        let (ticket, running) = lock.withLock { (wish.reset(), capture != nil) }
        // Even if the capture shows the cursor right now: a hide may be mid-flight (it finishes first, then this).
        if running { Task { _ = await run(ticket, attempt: 0) } }
    }

    private func run(_ ticket: VideoCursorWish.Ticket, attempt: Int) async -> Bool {
        let previous = lock.withLock { tail }
        let work = Task<Bool, Never> { [self] in
            _ = await previous?.value
            return await apply(ticket, attempt: attempt)
        }
        lock.withLock { tail = Task { _ = await work.value } }
        return await work.value
    }

    private func apply(_ ticket: VideoCursorWish.Ticket, attempt: Int) async -> Bool {
        let (current, running) = lock.withLock { () -> (Bool, ScreenCapture?) in
            guard wish.begin(ticket) else { return (false, nil) }  // overtaken, or its session is over
            return (true, capture)
        }
        guard current, let capture = running else { return true }  // none running: the next one starts with the wish
        guard capture.showsCursorNow != ticket.shows else { return true }
        do {
            try await capture.setShowsCursor(ticket.shows)
            return true
        } catch {
            let retry = lock.withLock { wish.failed(ticket) }
            let delayUs = VideoCursorWish.retryDelayUs(attempt: attempt)
            logger.log(.warning, "cursor_video_failed", sessionID: 0, generation: 0,
                       fields: "shows=\(ticket.shows ? 1 : 0) attempt=\(attempt) "
                           + "retry_ms=\(retry ? delayUs / 1_000 : 0) "
                           + "error=\((error as NSError).domain)_\((error as NSError).code)")
            if retry { scheduleRetry(after: ticket, attempt: attempt, delayUs: delayUs) }
            return false
        }
    }

    private func scheduleRetry(after failed: VideoCursorWish.Ticket, attempt: Int, delayUs: UInt64) {
        Task { [self] in
            try? await Task.sleep(nanoseconds: delayUs * 1_000)
            guard let ticket = lock.withLock({ wish.retry(after: failed) }) else { return }  // something newer happened
            _ = await run(ticket, attempt: attempt + 1)
        }
    }
}
