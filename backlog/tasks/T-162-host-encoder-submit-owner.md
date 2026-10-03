---
id: T-162
title: Serialise HEVCEncoder submits, QP updates and teardown on one owner queue
status: done
phase: 6
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/EncoderSubmitOrderTests.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - backlog/tasks/T-162-host-encoder-submit-owner.md
---

## Amaç

`HEVCEncoder` reserves an encoder slot (and with it the PTS order and keyframe flag) under its lock, but calls `VTCompressionSessionEncodeFrame` after the lock is released, from at least six different threads. Two submitters can therefore reach VideoToolbox in the wrong PTS order during normal streaming, and a submit can reach a session that `stop()` has already invalidated. This card moves every VT submit, the mid-stream QP property update and teardown onto one serial owner queue, in reservation order. The result is monotonic PTS at the VT boundary and no submit after invalidate, proven by deterministic tests.

Source: external architecture review 2026-10-03 (M02, X5, SE7); verification: docs/reviews/2026-10-03/verify-C-host-video.md (M02-H, additional issues 1–6) and docs/reviews/2026-10-03/verify-H-hygiene.md (TESTSEAM-1, host half).

## Bağlam

- **R-tagged finding (M02).** Per review p11 the work starts with a deterministic failure scenario. The `MateBridgeHost` target has no test target (`host-mac/Package.swift:18` defines only `MateBridgeCoreTests`), so step 1 extracts the seam first.
- **Step 1 (separate commit, no behaviour change):** move the whole offer → reserve → unlock → `backend.encode` sequence (today's `perform`/`releaseSlotAndDrain`/`flushPending` dispatch, `HEVCEncoder.swift:321-324, 488-491, 612-619, 649-655`) into Core (`EncoderSubmitOrder.swift`) behind a `CompressionBackend` protocol (e.g. `encode(frame, key) -> status`, `setQP(…)`, `completeAndInvalidate()`), so the barrier test drives production code. The inversion happens in the unlock-then-send step, so moving only the reserve/stopped decision would test the harness, not the code. `HEVCEncoder` adapts VT to it. `EncoderSubmitOrder` is generic over the frame and session payload; no CoreMedia/VideoToolbox import in Core. A fake-backend test documents today's ordering and is red for the barrier scenario.
- **Evidence (HEAD a30c769; `HEVCEncoder.swift` = `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift`):**
  - `offerLocked` (`:495-516`) and `takePendingLocked` (`:624-634`) check `!stopped`, copy `session`, and call `reserveSlot` (`:536-548`) under `lock`. That bumps `inFlight`, fixes the strictly increasing PTS and consumes `forceKeyframe`. The lock is then released, and only afterwards does `send()` (`:550`) call `VTCompressionSessionEncodeFrame` (`:565`).
  - Callers of `send()` (thread map in verify-C): SCK sample handler queue (`encode()` `:314`), the coordinator `Task` and the VideoSender `Task` (`resubmitLast` via `requestKeyframe(resubmitNow:)` `:307-310, 346-369`), the idle timer (`:474-480`), the optional idle-refresh timer (`:457-472`), the global-queue flush timer (`flushPending` `:643-656`), and VT's own output-callback thread (`releaseSlotAndDrain` `:612-620`, re-entrant VT call; C add. 6).
  - `stop()` (`:659-679`) sets `stopped` and nils `session` under the lock, then calls `VTCompressionSessionCompleteFrames` / `Invalidate` (`:676-677`) outside it. It is reached from `VideoPipeline.teardown` (`VideoPipeline.swift:279-288`), from the `fail()` Task (`:291-301`) independent of the coordinator loop, and from `deinit` (`:681`).
  - Effects: submit-order inversion in steady state (C add. 1; Apple's EncodeFrame contract wants increasing PTS; likely result an encode error → `slotFailed` → forced ~400 KB IDR, and the keyframe flag may land on the later frame); one `ev=encode_failed` at teardown when a submit hits an invalidated session (no use-after-free: `s` is retained).
  - C add. 3: `inFlight` has no floor and no per-reservation token (`:600-620`); a VT error *and* a handler call for one frame would decrement twice and silently raise the cap.
  - C add. 4: the T-087 QP cap `updateQPBoost` (`:431-453`, called at `:563`) runs under `boostLock`, outside the submit order.
  - C add. 2: `CMBlockBufferGetDataPointer(…, lengthAtOffsetOut: nil, totalLengthOut: &length, …)` (`:705-711`) reads `length` bytes from a pointer valid only for `lengthAtOffset` bytes; a multi-segment block buffer would over-read. Fix: if `lengthAtOffset != totalLength`, use `CMBlockBufferCopyDataBytes`.
  - C add. 5: synchronous `CompleteFrames` on a Swift cooperative thread (`VideoPipeline.swift:282` → `HEVCEncoder.swift:676`) blocks up to ~2 encode times during teardown.
  - Severity per verify-C: Low–Medium (the window is microseconds, effects self-heal with one keyframe), but it breaks a stated invariant (`FrameGate.swift:46-48`: "submitted capture timestamps never go backwards") and is cheap to make deterministic.
- **Plan hints:**
  - Shape: under `lock`, after `reserveSlot`, `submitQueue.async { send(...) }`. Enqueueing under the lock makes FIFO order equal reservation order. `stop()`: under `lock` set `stopped`, then `submitQueue.async { CompleteFrames; Invalidate }`. `stop()` always enqueues the teardown block with `async`; if `VideoPipeline.teardown` (an `async` func, `VideoPipeline.swift:279-283`) must wait, it awaits a `withCheckedContinuation` resumed at the end of that block. Never `submitQueue.sync` there: it would block a cooperative thread (and GCD usually runs a sync block on the calling thread anyway). Everything enqueued before it runs on a live session, and nothing can be enqueued after it.
  - VT callbacks only take the lock and enqueue. Never `submitQueue.sync` from a VT callback or from `deinit` (a block on the queue may drop the last reference); detect "already on queue" with `DispatchQueue.setSpecific`.
  - `stop()` is reached from `deinit` (`HEVCEncoder.swift:681`). The owner-queue teardown block captures only the session/backend and local values, never `self`: a block that retains `self` from `deinit` is a Swift runtime trap (object retained during deinit).
  - Move `updateQPBoost` into the same submit block. Keep `encode()` non-blocking for the SCK queue.
  - Risk: one extra thread hop per frame (tens of µs); measure it with the existing `ev=latency enc` / `cap_to_sent` lines.
  - Record the "single submit owner" invariant in the encoder's class doc and in Handoff.
- **`VideoPipeline.swift`** is in `files:` only in case teardown must await the owner queue. T-165 also edits it and the manifest lets both start in parallel: if you need it, check that T-165 is not in progress, otherwise stop and write it under *Açık sorular*.
- **Serialize with:** `HEVCEncoder.swift` chain T-162 → T-170 → T-176 → T-177 → T-204 → T-187; this card is the head. If decision 0026 is accepted before this card starts, the orchestrator may run T-204 (the encoder half of the former T-186) first and this card rebases. T-177's live bitrate setter must go through this card's owner queue.
- **Review:** Codex optional (`./scripts/codex-review.sh`, medium effort).
- No wire change; `docs/PROTOCOL.md` is not affected.

## Kapsam dışı

- Changing `maxInFlight`, pacer or gate policy, encoder profiles or knobs.
- Trimming compressed-frame copies (L03-H; not carded).
- The client decoder (T-161) and display ownership (T-165).

## Kabul kriterleri

- [x] [XCTest, step 1, red at HEAD] Against the extracted step-1 logic (today's ordering) with a fake backend, the barrier test below shows an `encode` after `invalidate` and a PTS inversion. Step 1 is its own commit with no behaviour change; the failing test is committed red (or `XCTExpectFailure`/skipped with the failure quoted in the commit message) before the ordering changes. Handoff names the commit.
- [x] [XCTest] A barrier between reserve and submit plus a concurrent `stop()` → zero `encode` calls after `invalidate`. Deterministic: barrier-driven, no sleeps.
- [x] [XCTest] A 10 000-iteration stress run (capture offers, `bypassGate` resubmits, flush-timer takes, slot releases, `stop()`) → strictly increasing backend PTS, exactly one release per reservation, and `0 ≤ inFlight ≤ maxInFlight` throughout.
- [x] [XCTest] Mutation check: a deliberately broken variant (submit after unlock on the caller thread) fails the barrier test. Recorded in Handoff, not committed as production code.
- [x] The `inFlight` release is idempotent per reservation token; a double release logs at `warning` and does not change the count.
- [x] `updateQPBoost` runs in the same submit block as the frame it applies to.
- [x] `CMBlockBuffer`: when `lengthAtOffset != totalLength`, the bytes are copied with `CMBlockBufferCopyDataBytes`.
- [x] Teardown `CompleteFrames`/`Invalidate` runs on the owner queue, enqueued with `async` only, never on a Swift cooperative thread and never via `sync`. The teardown block captures only the session/backend and locals, never `self` (it is reached from `deinit`).
- [ ] [device] Mac + tablet, 10 min at 120 fps with 20 STREAM_PREFS changes and 10 video reconnects: `ev=encode_failed` count = 0; `ev=latency` `enc` and `cap_to_sent` p50 within ±0.3 ms of a baseline run on the previous build (same day, same mode); p99 not grown. Both build IDs recorded in docs/NOTES.md by the orchestrator.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **Commit 1 (plan):** this section, `status: in-progress`.
2. **Commit 2 (step 1, no behaviour change):** new Core `EncoderSubmitOrder<Backend: CompressionBackend>` owns the encoder lock state that decides submission: pacer (`FramePacer`), `last`, `forceKeyframe`, `inFlight`, reservation tokens, monotonic stamp (PTS), last slot-free/reserve times, flush scheduling and `stop`. Frames conform to `EncoderSubmitFrame` (generic stamp + `gateUs` + arrival/reserve hooks); `CompressionBackend` has `encode(frame, keyframe:, token:)` and `completeAndInvalidate()`. Step 1 keeps today's ordering exactly: reserve under the lock, unlock, then `backend.encode` on the caller thread; `stop` invalidates on the caller thread. `HEVCEncoder` keeps its public API and adapts VT via a private backend class. Test seam: `beforeSubmit` hook (nil in production). `EncoderSubmitOrderTests` documents today's order; the two barrier tests (PTS inversion, encode after invalidate) are red and committed under `XCTExpectFailure`, failure quoted in the commit message.
3. **Commit 3 (step 2, the fix):** under the lock, every reserved submit is enqueued `async` on one serial owner queue (FIFO = reservation order); `stop` sets `stopped` and enqueues `completeAndInvalidate` (+ optional completion) under the same lock, capturing only the backend and the completion. Release is idempotent per token (double release: `warning`, count unchanged). `updateQPBoost` moves into the backend's encode (owner queue; `boostLock` goes). `CMBlockBufferCopyDataBytes` when `lengthAtOffset != totalLength`. `HEVCEncoder.shutdown() async` (continuation resumed at the end of the teardown block) for `VideoPipeline.teardown`; sync `stop()` keeps waiting for the teardown (semaphore; not when already on the owner queue) for `SharpnessBench`; `deinit` only enqueues. Barrier tests lose `XCTExpectFailure`; 10 000-op stress test added; mutation check recorded in Handoff.
4. **Commit 4:** Handoff, `status: review`.

Files: only the `files:` list. `VideoPipeline.swift`: one line (`await enc?.shutdown()`); T-165 is `todo` (no branch/worktree), so it is not in progress.
Risks: one extra thread hop per frame (measure `ev=latency enc` / `cap_to_sent` on device); a late output after `frames.finish()` cannot happen because teardown awaits the owner queue.

## Handoff

- **Commit:** branch `task/T-162-host-encoder-submit-owner`.
  - `4d07331` plan.
  - `0c218d3` **step 1** (Core extraction, no behaviour change). The two barrier tests are red there under `XCTExpectFailure`, and the failures are quoted in the commit message: `[2, 1] != [1, 2]` (PTS inversion) and `events: [invalidate, encode(stamp: 1)]` (encode after invalidate).
  - `641a418` **step 2** (owner queue, idempotent release, QP in the submit block, CMBlockBuffer copy, `shutdown()`).
  - `b17e828` test hardening: off-owner-queue backend calls are counted; the barrier tests drain the owner queue before asserting.
  - `4326516` Handoff, status review.
  - Codex review fix (P2, tests only): the stress test no longer asserts progress counts, and a controlled test covers the refused-submit path. That commit and its Handoff update come last.
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift` (new), `host-mac/Tests/MateBridgeCoreTests/Video/EncoderSubmitOrderTests.swift` (new), `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift`, `host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift` (one line: `await enc?.shutdown()`; T-165 was `todo` with no branch or worktree), this card.
- **Invariant (single submit owner):** every `VTCompressionSessionEncodeFrame`, the T-087 `MaxAllowedFrameQP` update and the final `CompleteFrames`/`Invalidate` run on one serial queue (`matebridge.encoder.submit`, QoS userInteractive), owned by `EncoderSubmitOrder`.
  - Submits are enqueued `async` while the lock that reserved their slot is held, so FIFO order equals reservation order.
  - `stop` sets `stopped` and enqueues the teardown under the same lock, so the teardown runs after every reserved submit and no submit comes after it.
  - Nothing calls `sync` on that queue. Capture, timers, VideoToolbox callbacks and the coordinator only take the lock and enqueue.
  - The teardown block captures only the backend and the completion, never `self`. `HEVCEncoder.Backend` holds the encoder `weak`.
  - The invariant is written in the class docs of both `EncoderSubmitOrder` and `HEVCEncoder`.
- **Acceptance (XCTest):**
  - Barrier tests: `testBarrierKeepsReservationOrderAtBackend` and `testBarrierStopNeverEncodesAfterInvalidate`. They are driven by the `beforeSubmit` hook and semaphores; there are no sleeps.
  - Stress test: `testStressKeepsOrderAndSlotAccounting` runs 10 000 `concurrentPerform` operations: capture offers, `bypassGate` resubmits, `flushPending`, keyframe requests, completions on another queue, refused submits (every 13th), duplicate releases (every 5th completion) and `stop()`. It asserts only invariants that hold for every interleaving:
    - backend stamps are strictly increasing;
    - no encode happens after invalidate, and no backend call is made off the owner queue;
    - every reservation reached the backend and was released exactly once (reservations == releases), and every duplicate release was ignored (duplicates == duplicates sent);
    - `stats.minInFlight >= 0`, `stats.maxInFlight <= 2`, and live samples stay in range.
  - Codex P2 fix: the stress test used to assert progress counts too (`reservations > 20`, `refused > 0`, `duplicatesSent > 0`). Those could fail on a delayed runner when `stop()` ran before the backend made progress. They are gone. The counted paths now have controlled single-thread tests:
    - `testRefusedSubmitReleasesSlotOnceAndForcesKeyframe`: the barrier holds the owner queue during setup; a refused submit releases its slot exactly once, forces a keyframe, and the pending frame goes out next.
    - `testDoubleReleaseIsIgnoredAndLogged` (see below).
  - Idempotent release: `testDoubleReleaseIsIgnoredAndLogged` checks `ev=slot_double_release` at `warning`, with the count unchanged.
  - Stability after the fix: 12 tests × 60 runs in a row were green, plus 25 runs under 16 busy `yes` processes. `./scripts/check.sh` passes (ALL OK).
- **Mutation check (not committed, file reverted with `git checkout`):**
  - Mutant 1, "submit after unlock on the caller thread" (pending submits collected under the lock and run on the caller after `unlock`): both barrier tests fail, `[2, 1]`, `offQueueCalls 2 != 0` and `events: [invalidate, encode(1)]`, and the stress test fails with `stamps went backwards 2..10` and `off queue 143..188`. Three runs out of three failed.
  - Mutant 2, teardown on the caller thread: both barrier tests and the stress test fail. Two runs out of two failed.
  - Note: before the hardening commit, mutant 1 left the stop-barrier test green by scheduling, because the events were read before the queue had run the held frame. `b17e828` fixes that.
- **Varsayımlar:**
  - Sync `HEVCEncoder.stop()` is kept, and it waits for the teardown with a semaphore (`SharpnessBench` reads the outputs right after `stop()` and is not in `files:`). It does not wait when called on the owner queue. It must never be called from a VideoToolbox callback or from Swift concurrency, which use `shutdown()`.
  - `deinit` only enqueues.
  - `VideoPipeline.teardown` awaits `shutdown()` before `frames.finish()`, so the late outputs from `CompleteFrames` still reach the old queue, as before.
  - The CMTime stamp bump (`+1/1000 s`) and the T-072 slot-wait formula are unchanged; they moved into `Input.stamp(after:)` and `Input.reserved(lastSlotFreeUs:)`.
  - The idle keyframe timer now measures on HostClock µs (`lastReserveUs`) instead of `DispatchTime` ns, with the same 1 s threshold.
  - `boostLock` is gone because `qpBoost` is confined to the owner queue.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - The card's [device] criterion: 10 min at 120 fps with 20 STREAM_PREFS changes and 10 video reconnects. Check that the `ev=encode_failed` count is 0, that `ev=latency` `enc`/`cap_to_sent` p50 is within ±0.3 ms of the previous build, and that p99 has not grown (the extra thread hop per frame).
  - Teardown and reconnect: `stopKeepingDisplay` now waits for `CompleteFrames` on the owner queue (no cooperative thread is blocked). Check that STREAM_PREFS changes do not slow the restart.
  - No `ev=slot_double_release` should appear in normal use. If it appears, VideoToolbox sent both an error and a callback for one frame.
  - The multi-segment `CMBlockBuffer` copy path cannot be exercised on device (VT normally returns a contiguous buffer).
  - `sharpness-bench` (sync `stop()` path) was not run.
- **Açık sorular:**
  - New log event `ev=slot_double_release token=<n>` (component `encoder`, `W`). `docs/LOGGING.md` is not in `files:`; the orchestrator said it will add it.
  - The T-177 live bitrate setter must go through `EncoderSubmitOrder`'s owner queue. One option is a `perform(onOwnerQueue:)` helper or a backend method. This card did not add one, to stay in scope.
