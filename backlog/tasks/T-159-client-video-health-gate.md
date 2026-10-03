---
id: T-159
title: Gate input on decoder health and show a video-fault overlay
status: in-progress
phase: 6
owner: android-client-dev
depends_on: [T-158]
decisions: [0019]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoHealth.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/DecoderFault.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/res/values/strings.xml
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/VideoHealthTest.kt
  - backlog/tasks/T-159-client-video-health-gate.md
---

## Amaç

Today a decoder that gives up, or that runs but silently produces no output, leaves a frozen or black image while pen and keys still reach the Mac. The user then draws or types blind. This card makes video health an explicit client state: input capture is live only while the video is HEALTHY, a fault turns input off with the normal releases, a visible overlay explains it, and recovery runs a bounded, ordered ladder. A frozen or black image must never keep input live.

Source: external architecture review 2026-10-03 (H02, SE4, X3, D3, F2); verification: docs/reviews/2026-10-03/verify-B-client-video.md (P1, additional issues 1, 2, 5).

Decision 0019 must be accepted by the user before work starts.

## Bağlam

- **Evidence (HEAD a30c769; `C/` = `client-android/app/src/main/kotlin/dev/matebridge/client/`):**
  - Give-up: `C/video/VideoRenderer.kt:341-355` (`decodeAttempts`): after `RestartPolicy` (3 restarts per 10 s, `RestartPolicy.kt:4`) it logs `ev=give_up`, sets `att.active=false`, calls `onGiveUp`, and the decoder thread exits. `attached` stays `true` (`:197-198`; only `detachSurface` clears it).
  - `C/MainActivity.kt:1154`: `onGiveUp = { why -> MbLog.e("decoder_give_up", …) }`. Nothing else happens.
  - The gate `syncInputActive` (`MainActivity.kt:643-649`) has no video term: `started && !isDestroyed && panel GONE && !viewport.isEmpty`. The panel hides on `streaming = state is Connected && state.framesReceived > 0 && renderer != null` (`:1884`), and `framesReceived` counts frames received on the video TCP socket (`SessionController.kt:842`), not decoded frames.
  - The device-proven failure is quieter than give-up: T-028 (`backlog/tasks/T-028-black-screen-on-display-reuse.md`) showed `codec_start`, no `output_format`, `recv=59 dec=0`. No exception, so no give-up. Health must also cover "fed but no output" and "decoder thread not running while attached".
  - **Keyframe loop while dead (B add. 1):** after give-up `onVideoFrame` still feeds the queue (`MainActivity.kt:501-508` checks only `attached`). Under motion `FrameQueue` overflows, then the 500 ms ticker (`MainActivity.kt:1365-1379`, `takeKeyframeRetry` at `:1373`) sends `KEYFRAME_REQUEST(STARTUP)`, and the host resends CODEC_CONFIG plus a forced IDR (T-030). Result: ~2 IDR/s at 2800×1840 for as long as the image is frozen.
  - **Input re-opens before the new generation's first frame (B add. 2):** `C/session/SessionMachine.kt:175` resets `frames` only on `Event.Start`. An automatic reconnect keeps the old count, and on ACCEPTED `:317` emits `Connected(hostName, frames)` with `frames > 0`, so the panel hides and input opens as soon as the viewport is valid. The migration path (`promote`, `:492`) behaves the same way. Resetting `frames` in `SessionMachine` alone would not help: every `Tick` overwrites it with the controller's `videoFrames` (`SessionMachine.kt:353`), which is reset only on `Event.Start` (`SessionController.kt:358`). This card therefore closes input through `VideoHealth` generations instead (a reconnect re-attaches the surface and a migration's new STREAM_CONFIG runs `reconfigure`; both start a STARTING generation) and leaves the frame counter alone.
  - **No user-visible state (B add. 5):** after a video failure the status panel stays GONE; the only trace is `dec=0` in the optional stats overlay.
- **Decision 0019 summary (draft in docs/decisions/0019-video-health-input-gate.md, written by the orchestrator):** HEALTHY = surface attached, the current decoder generation has produced at least one output, and no fault is set. Faults: give-up; no output while ≥ 3 non-config inputs have been queued since the last output and the oldest of them was queued ≥ 1500 ms ago; decoder thread not running 2 s after attach; previous generation stuck (reported by T-161). A static screen (no frames arriving) is never a fault: host idle refresh is opt-in (`HEVCEncoder.swift:29-30`), so a blind "no frame for N s" watchdog is wrong. On a fault: capture off (existing `RELEASE_ALL(USER)`, no wire change), feeding and keyframe retries stop, overlay shown; recovery: codec restart at 1 s → at 3 s → session reconnect → "Yeniden dene" button. A generation (one `attachSurface`/`reconfigure` call) is STARTING with input closed until its first decoded output; a codec restart after `decode_error` inside the same attachment is not a new generation.
- **Plan hints:**
  - `VideoHealth` is pure Kotlin, UI-thread owned, with an injected clock. Renderer callbacks post to it.
  - Hook points: give-up `VideoRenderer.kt:347-351`; first output and last output time in `drainOutput` (`:527-581`, output dequeued at `:541-544`); inputs queued at `:472`; the gate at `MainActivity.kt:643-649`; `onGiveUp` at `:1154`; `streaming` at `:1884`.
  - The existing 500 ms ticker (`MainActivity.kt:1365-1379`) evaluates the no-output and not-running timers, so no new thread is needed.
  - Base timing on decoder output (`dequeueOutputBuffer`), not on `onFrameRendered`; panels that throttle presentation must not cause false faults.
  - FAULT → `capture.setActive(false)` runs the existing release sequence and `RELEASE_ALL(USER)`; never drop an up event. Re-check that leaving FAULT does not re-open input before the first decoded output.
  - **Generation:** one `attachSurface`/`reconfigure` call (new config or new surface). STARTING closes input (`inputAllowed = false`, with the normal releases). A codec restart after `decode_error` inside the same attachment (`VideoRenderer.kt:353`) is NOT a new generation: input stays open and only the FAULT rules apply. So every mode change and surface re-attach briefly closes input; that is intended (decision 0019).
  - **Reconnect and migration** need no `SessionMachine.kt` change: a reconnect goes through `releaseRenderer()` → `detachSurface()` and re-attaches on the next `installConfig`, and a migration's new STREAM_CONFIG runs `r.reconfigure(config)` (`MainActivity.kt:1177`, always restarts the codec). Both are new generations. Between a migration promote and the new session's STREAM_CONFIG the previous generation still counts; no new frames arrive in that window, and the following `reconfigure` closes input until the first output. The panel may still hide on the old `framesReceived` count; input safety comes from `VideoHealth`, not from the panel.
  - **No-output rule anchor:** count only non-config inputs queued since the last output, and time from the oldest of them, not from the last output. A static screen held for seconds, followed by the user starting to draw, must not fault while the first output of that burst is pending.
  - **Generic fault input:** `VideoHealth` takes `fault(cause)` with causes `give_up|no_output|not_running|stuck` (`stuck` is unused until T-161). The renderer reports through a single callback (`onHealthEvent`), wired once in `MainActivity`, so T-161 only calls it.
  - **Fault injection:** a debug `--es decoder_fault create|configure|dequeue|silent` extra wraps the production `DecoderCodec` (T-158) in a fault-injecting decorator (`video/DecoderFault.kt`). The T-158 fake lives in the test tree and cannot be used by the app. The daily APK is a debug build (verify-H additional issue 3), so the extra itself is the gate until T-185 adds the developer switch; make it one-shot per launch. The fault is armed at launch but fires only after the stream has been HEALTHY for `--ei decoder_fault_after_s N` seconds (default 10): `dequeue`/`silent` hit the running codec, and `create`/`configure` hit the next codec creation (the next restart, e.g. a mode change). Otherwise the first generation never becomes HEALTHY, input never opens, and T-164 cannot test a fault with Shift held and the pen down. Log `ev=decoder_fault mode= armed_s=` once, when the fault fires.
  - Logs: `ev=video_health state= cause=` per docs/LOGGING.md format. LOGGING.md is not in `files:`; list the new lines under *Açık sorular* for the orchestrator.
- **Risks:** false positives on a legitimately idle screen (covered by the ≥3-inputs rule); recovery loops that hammer the host (the ladder is bounded, and FAULT stops keyframe retries).
- **Serialize with:** T-153 (same file `MainActivity.kt`; chain T-146 → T-151 → T-153 → T-159 → T-160 …). `VideoRenderer.kt` follows T-158 (depends_on). This card no longer edits `SessionMachine.kt` (QA-2), so it is not in the T-150 → T-156 → T-160 chain on that file.
- **Review:** input-state change, so the orchestrator runs `./scripts/codex-review.sh`.
- No wire change; `RELEASE_ALL.reason=USER` is reused. `docs/PROTOCOL.md` is not affected.
- Device acceptance runs in T-164.

## Kapsam dışı

- Generation tokens on video delivery (T-160) and bounded decoder teardown / per-generation state (T-161). T-161 later feeds a "stuck" fault into `VideoHealth` through the `fault(cause)` input added here.
- The session frame counter (`SessionMachine.kt` / `SessionController.kt` `videoFrames`); input safety on reconnect and migration comes from `VideoHealth` generations.
- Host changes; a new `RELEASE_ALL` reason (would be a protocol change).
- Latency metrics; MainActivity refactors beyond extracting `VideoHealth`.

## Kabul kriterleri

- [ ] [JVM] `VideoHealthTest` transitions: STARTING → HEALTHY on the first decoded output; HEALTHY → FAULT on give-up, on no output while ≥ 3 non-config inputs have been queued since the last output and the oldest of them was queued ≥ 1500 ms ago, and on the decoder thread not running 2 s after attach; a static screen (no inputs) stays HEALTHY indefinitely; a new generation is STARTING until its first output.
- [ ] [JVM] Idle 10 s after the last output, then 3 inputs within 30 ms and the first output 20 ms later → stays HEALTHY. 3 inputs and no output with the oldest queued ≥ 1500 ms ago → FAULT(no_output).
- [ ] [JVM] Generation = one `attachSurface`/`reconfigure` call (new config or new surface). STARTING closes input (`inputAllowed = false`, with the normal releases). A codec restart after `decode_error` inside the same attachment is NOT a new generation: input stays open and only the FAULT rules apply. A test pins both cases.
- [ ] [JVM] `VideoHealth` takes a generic `fault(cause)` input with causes `give_up|no_output|not_running|stuck` (`stuck` is unused until T-161), wired from a single renderer callback (`onHealthEvent`), so T-161 only calls it.
- [ ] [JVM] Recovery steps are bounded and ordered with a fake clock: codec restart at 1 s, at 3 s, then session reconnect, then the manual "Yeniden dene" state; no step repeats without bound.
- [ ] [JVM] In FAULT, keyframe retries stop and the renderer stops feeding its queue (fake clock), so the ~2 IDR/s loop does not happen.
- [ ] `syncInputActive` includes `videoHealth.inputAllowed`. Entering FAULT calls `capture.setActive(false)`, which sends the existing releases and `RELEASE_ALL(USER)`.
- [ ] [JVM] After an automatic reconnect (detach → attach) or a USB↔Wi-Fi migration (new STREAM_CONFIG → `reconfigure`), input stays closed until the first decoded output of the new generation, even though the session frame counter is not reset. No `SessionMachine.kt` change.
- [ ] On FAULT an overlay with a short Turkish explanation and a "Yeniden dene" button is shown (`strings.xml`); it hides when HEALTHY again.
- [ ] `ev=video_health state= cause=` is logged on every transition; no key characters or text are logged.
- [ ] Debug extra `--es decoder_fault create|configure|dequeue|silent` (with `--ei decoder_fault_after_s N`, default 10) forces each fault through the `DecoderCodec` seam after the stream has been HEALTHY for N s (`dequeue`/`silent` on the running codec, `create`/`configure` on the next codec creation), and logs `ev=decoder_fault mode= armed_s=` once when it fires; without the extra, behaviour is unchanged.
- [ ] [device] Covered by T-164 (fault → `input_active on=0`, no stuck Shift or pen on the Mac, recovery time).
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. `video/VideoHealth.kt` (new, pure Kotlin):
   - `HealthEvent` (one sealed type; every event carries the renderer generation): `Generation`, `Detached`,
     `Running`, `Exited`, `FirstOutput`, `Fault(cause)`. `FaultCause` = `give_up|no_output|not_running|stuck`.
   - `DecodeProgress`: small synchronized counter the decoder threads update per frame (no UI post per frame):
     non-config inputs queued since the last output and the time of the oldest of them, per generation; `onOutput`
     says whether it was the generation's first output.
   - `VideoHealth` (UI thread, injected clock): states `IDLE` (no surface) / `STARTING` / `HEALTHY` / `FAULT`;
     `inputAllowed` = HEALTHY; `feedAllowed`/`keyframeRetriesAllowed` = not FAULT. `onEvent` ignores events of other
     generations. `tick(progress)` (the 500 ms ticker) evaluates no_output (≥ 3 pending, oldest ≥ 1500 ms) and
     not_running (no `Running`, or `Exited`, 2 s after the generation began), in STARTING and HEALTHY. FAULT is left
     only by a new generation (outputs of the faulted generation are ignored), so input never re-opens before a first
     decoded output. A codec restart after `decode_error` sends no event, so it is not a new generation.
   - Recovery ladder (episode starts at the first fault, ends after 10 s continuously HEALTHY): codec restart at +1 s,
     codec restart at +3 s, session reconnect at +6 s, manual ("Yeniden dene") at +15 s; the step timer runs only while
     not HEALTHY and a surface is attached; steps only advance, so no step repeats within an episode. `retry()` (button)
     restarts the codec at once and continues the ladder from step 2.
   - `ev=video_health state= cause= gen=` on every state change (via a callback; no text logged).
2. `video/VideoRenderer.kt`: generation counter; `onHealthEvent` constructor parameter (default no-op) called on
   attach/reconfigure (`Generation`, synchronously on the UI thread), detach, decoder thread start/exit, first output,
   give-up (`Fault(give_up)`); `DecodeProgress` updates at `queueInputBuffer` and output dequeue; `stopFeeding()` (per
   generation; also on give-up) makes `onFrame` drop frames and `takeKeyframeRetry()` return false; `restartCodec()`
   (recovery step: new generation on the same surface, keeps the stored CODEC_CONFIG, STARTUP request).
3. `video/DecoderFault.kt` (new): debug `--es decoder_fault create|configure|dequeue|silent` decorator around the
   production `DecoderCodec.Factory`. Armed at launch, fires once after `--ei decoder_fault_after_s N` (default 10) s
   HEALTHY (`ev=decoder_fault mode= armed_s=`). `dequeue`/`silent` hit every codec of the current generation,
   `create`/`configure` every codec of the next generation; the generation after that runs clean (so give-up/no_output
   FAULT is reached and the ladder's restart recovers). `silent` drains the real codec without rendering.
4. `MainActivity.kt` (localized): `VideoHealth` field; `syncInputActive` adds `videoHealth.inputAllowed`; the renderer's
   `onHealthEvent` → `runOnUiThread { videoHealth.onEvent }`; transitions → `syncInputActive()` (FAULT/STARTING close
   capture → existing releases + `RELEASE_ALL(USER)`), `stopFeeding()`, overlay; the ticker calls `tick`, runs the
   recovery action, gates `takeKeyframeRetry` and drives `DecoderFault`; `onGiveUp` unchanged (log only). Overlay built
   in code (no layout file in `files:`), text + "Yeniden dene" button from `strings.xml`.
5. Tests: `VideoHealthTest.kt` (state machine, rules, ladder, generations incl. reconnect/migration, DecodeProgress,
   DecoderFault, renderer integration with the T-158 fake: give-up → Fault event + feeding stopped, decode_error restart
   = no new generation, first output). The T-158 fake gets an output-producing mode (test dir, per orchestrator);
   `DecoderLifecycleTest` assertion on `attached` after give-up stays (attached is still true; health handles it).

Risks: per-frame cost (one uncontended lock per input and output); stale events of a retired generation (filtered by
generation); the overlay must not take input while capture is on (shown only when input is off).

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
