import Foundation
import MateBridgeCore

/// Whether the video shows the Mac's cursor (decision 0036): a reconciler (`VideoCursorReconciler`) with one applier
/// loop. The only state is the desire, `(shows, generation)`, latest wins, set synchronously under a lock; the loop
/// compares it with what the CURRENT capture shows (`ScreenCapture.showsCursorNow`) and, while they differ, runs one
/// `SCStream.updateConfiguration` toward the desire. Nothing queues, so nothing can grow or run out of order:
///
/// - a capture that attaches (a restart, a display wake, a replacement) is just a different capture to compare, so it
///   is brought in line with the same desire, and a capture that starts later starts with it (`showsCursor`);
/// - a session end (`reset()`) puts the desire back to "cursor in the video" under a new generation; a request of the
///   old generation is ignored, so a hide on its way from an ended session cannot hide the next session's cursor;
/// - a refused change is retried with a bounded backoff (0.25 s doubling to 8 s), cancelled and restarted by any new
///   desire, any attach or reset; a refusal is reported once per desire (`onOutcome`), and the desire is not changed by
///   it: whoever asked decides what it means (`CursorService` stops the cursor flow and asks for the cursor back).
///
/// `CursorService` is the only writer, `ScreenCapture` the only reader of `showsCursor`.
final class VideoCursorSwitch: @unchecked Sendable {
    static let shared = VideoCursorSwitch()

    private let lock = NSLock()
    private var reconciler = VideoCursorReconciler()
    private weak var capture: ScreenCapture?
    /// The one applier loop; nil when idle. `loopID` changes when a loop is replaced (a stale one exits).
    private var loop: Task<Void, Never>?
    private var loopID = 0
    private var backingOff = false
    private var outcomeHandler: (@Sendable (VideoCursorReconciler.Outcome) -> Void)?
    private let logger = SessionLogger(component: "cursor")

    /// What a capture that starts now must do: true = cursor in the video.
    var showsCursor: Bool { lock.withLock { reconciler.desiredShows } }

    /// The live session generation: read synchronously when a session starts, passed to `request`.
    var generation: Int { lock.withLock { reconciler.generation } }

    /// Outcomes (any thread): the capture has what a request asked (`ok`), or ScreenCaptureKit refused it (once per
    /// desire; the switch keeps trying).
    func onOutcome(_ handler: (@Sendable (VideoCursorReconciler.Outcome) -> Void)?) {
        lock.withLock { outcomeHandler = handler }
    }

    /// A capture is running: it is compared with the desire from now on.
    func attach(_ capture: ScreenCapture) {
        lock.withLock {
            self.capture = capture
            reconciler.captureChanged()
            kickLocked()
        }
    }

    func detach(_ capture: ScreenCapture) {
        lock.withLock { if self.capture === capture { self.capture = nil } }
    }

    /// The session of `generation` wants the cursor in (`true`) or out of (`false`) the video. Returns at once; the
    /// result is an `Outcome`. A request of an ended session is ignored.
    func request(shows: Bool, generation: Int) {
        lock.withLock {
            guard reconciler.request(shows: shows, generation: generation) else { return }
            kickLocked()
        }
    }

    /// A session ended: the cursor goes back into the video (the desire is back at once: a capture that starts now gets
    /// it), under a new generation.
    func reset() {
        lock.withLock {
            reconciler.reset()
            kickLocked()
        }
    }

    // MARK: Applier loop

    /// Lock held. Makes the loop look again: starts it, or cuts a backoff short; one in the middle of a change looks
    /// again by itself when that change is done.
    private func kickLocked() {
        if loop == nil {
            startLoopLocked()
        } else if backingOff {
            loop?.cancel()
            startLoopLocked()
        }
    }

    private func startLoopLocked() {
        loopID += 1
        backingOff = false
        let id = loopID
        loop = Task { [self] in await run(id) }
    }

    private func run(_ id: Int) async {
        while true {
            let (step, capture, notify) = lock.withLock { () -> (VideoCursorReconciler.Step?, ScreenCapture?, (@Sendable (VideoCursorReconciler.Outcome) -> Void)?) in
                guard loopID == id else { return (nil, nil, nil) }  // replaced
                let capture = self.capture
                let step = reconciler.plan(actualShows: capture?.showsCursorNow)
                if case .done = step { loop = nil }  // idle: decided together with the check, so no kick is missed
                return (step, capture, outcomeHandler)
            }
            guard let step else { return }
            switch step {
            case .done(let outcome):
                if let outcome { notify?(outcome) }
                return
            case .apply(let shows):
                guard let capture else { return }  // unreachable: `apply` needs a capture
                await apply(shows, to: capture, loop: id)
            }
        }
    }

    private func apply(_ shows: Bool, to capture: ScreenCapture, loop id: Int) async {
        do {
            try await capture.setShowsCursor(shows)
            lock.withLock { reconciler.succeeded() }
        } catch {
            let (result, notify) = lock.withLock { () -> ((outcome: VideoCursorReconciler.Outcome?, delayUs: UInt64), (@Sendable (VideoCursorReconciler.Outcome) -> Void)?) in
                guard loopID == id else { return ((nil, 0), nil) }
                let current = self.capture === capture
                let result = reconciler.failed(attempted: shows, onCurrentCapture: current)
                if result.delayUs > 0 { backingOff = true }
                return (result, outcomeHandler)
            }
            let ns = error as NSError
            logger.log(.warning, "cursor_video_failed", sessionID: 0, generation: 0,
                       fields: "shows=\(shows ? 1 : 0) retry_ms=\(result.delayUs / 1_000) error=\(ns.domain)_\(ns.code)")
            if let outcome = result.outcome { notify?(outcome) }
            if result.delayUs > 0 {
                try? await Task.sleep(nanoseconds: result.delayUs * 1_000)  // cut short (cancelled) by a kick
                lock.withLock { if loopID == id { backingOff = false } }
            }
        }
    }
}
