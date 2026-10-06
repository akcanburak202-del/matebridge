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
/// One serial model: EVERY change (a request, a reset, the correction of a capture that started with another setting,
/// a retry) is a ticket taken from the wish and put on one FIFO queue in the same critical section, and one drain loop
/// applies the queue in order, one `updateConfiguration` at a time. So the order of the changes is the order of the
/// events, a reset can never run alongside a hide, and whatever finishes last is the newest. A hide carries the
/// generation of the session that asked (read synchronously when that session started, `generation`): `reset()` at a
/// session end starts a new one, so a hide still on its way from the ended session is refused.
///
/// A correction the host makes by itself (a capture attached while the wish is "hidden" and was started otherwise) has
/// no caller to tell if it fails: `onCorrectionFailed` does, with the generation, so the cursor flow stops instead of
/// drawing a second cursor.
final class VideoCursorSwitch: @unchecked Sendable {
    static let shared = VideoCursorSwitch()

    private struct Operation {
        var ticket: VideoCursorWish.Ticket
        var attempt: Int
        /// A failed hide of this operation is reported to `onCorrectionFailed`.
        var reportsFailure: Bool
        var done: (@Sendable (Bool) -> Void)?
    }

    private let lock = NSLock()
    private var wish = VideoCursorWish()
    private weak var capture: ScreenCapture?
    private var queue: [Operation] = []
    private var draining = false
    private var correctionFailed: (@Sendable (_ generation: Int) -> Void)?
    private let logger = SessionLogger(component: "cursor")

    /// What a capture that starts now must do: true = cursor in the video.
    var showsCursor: Bool { lock.withLock { wish.wantsCursor } }

    /// The live session generation: read synchronously when a session starts, passed to `set`.
    var generation: Int { lock.withLock { wish.generation } }

    /// Called (any thread) with the generation of a hide that the host itself asked for and ScreenCaptureKit refused.
    func onCorrectionFailed(_ handler: (@Sendable (_ generation: Int) -> Void)?) {
        lock.withLock { correctionFailed = handler }
    }

    /// A capture is running. If the wish differs from what it was started with (it changed while it started), the
    /// wish wins and the capture is brought in line (queued like any other change).
    func attach(_ capture: ScreenCapture) {
        lock.withLock {
            self.capture = capture
            let want = wish.wantsCursor
            guard capture.showsCursorNow != want, let ticket = wish.request(shows: want, generation: nil) else { return }
            enqueueLocked(Operation(ticket: ticket, attempt: 0, reportsFailure: true, done: nil))
        }
    }

    func detach(_ capture: ScreenCapture) {
        lock.withLock { if self.capture === capture { self.capture = nil } }
    }

    /// Asks, for the session of `generation`, for the cursor in (`true`) or out of (`false`) the video and waits for
    /// the running capture to say it is done. True also when no capture runs (the next one starts with the wish), when
    /// a newer request overtook this one, or when the session is over. False when ScreenCaptureKit refused (a refused
    /// show is retried by itself).
    func set(shows: Bool, generation: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let accepted = lock.withLock { () -> Bool in
                guard let ticket = wish.request(shows: shows, generation: generation) else { return false }
                enqueueLocked(Operation(ticket: ticket, attempt: 0, reportsFailure: false,
                                        done: { continuation.resume(returning: $0) }))
                return true
            }
            if !accepted { continuation.resume(returning: true) }  // the session is over
        }
    }

    /// A session ended: the cursor goes back into the video. The wish is back at once (a capture that starts now gets
    /// it), everything on its way from the session is void (the new generation), and a running capture follows in turn
    /// after whatever is being applied.
    func reset() {
        lock.withLock {
            let ticket = wish.reset()
            if capture != nil { enqueueLocked(Operation(ticket: ticket, attempt: 0, reportsFailure: false, done: nil)) }
        }
    }

    // MARK: Serial application

    /// Lock held. Appends and makes sure the drain loop runs.
    private func enqueueLocked(_ operation: Operation) {
        queue.append(operation)
        guard !draining else { return }
        draining = true
        Task { [self] in await drain() }
    }

    private func next() -> Operation? {
        lock.withLock {
            guard !queue.isEmpty else {
                draining = false
                return nil
            }
            return queue.removeFirst()
        }
    }

    private func drain() async {
        while let operation = next() {
            let ok = await apply(operation)
            operation.done?(ok)
        }
    }

    private func apply(_ operation: Operation) async -> Bool {
        let ticket = operation.ticket
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
            let (retry, report) = lock.withLock { (wish.failed(ticket), correctionFailed) }
            let delayUs = VideoCursorWish.retryDelayUs(attempt: operation.attempt)
            logger.log(.warning, "cursor_video_failed", sessionID: 0, generation: 0,
                       fields: "shows=\(ticket.shows ? 1 : 0) attempt=\(operation.attempt) "
                           + "retry_ms=\(retry ? delayUs / 1_000 : 0) "
                           + "error=\((error as NSError).domain)_\((error as NSError).code)")
            if retry { scheduleRetry(after: ticket, attempt: operation.attempt, delayUs: delayUs) }
            if operation.reportsFailure, !ticket.shows { report?(ticket.generation) }
            return false
        }
    }

    private func scheduleRetry(after failed: VideoCursorWish.Ticket, attempt: Int, delayUs: UInt64) {
        Task { [self] in
            try? await Task.sleep(nanoseconds: delayUs * 1_000)
            lock.withLock {
                guard let ticket = wish.retry(after: failed) else { return }  // something newer happened
                enqueueLocked(Operation(ticket: ticket, attempt: attempt + 1, reportsFailure: false, done: nil))
            }
        }
    }
}
