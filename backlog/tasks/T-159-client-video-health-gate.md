---
id: T-159
title: Gate input on decoder health and show a video-fault overlay
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-158]
decisions: [0019]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoHealth.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/DecoderFault.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt
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
  - **Input re-opens before the new generation's first frame (B add. 2):** `C/session/SessionMachine.kt:175` resets `frames` only on `Event.Start`. An automatic reconnect keeps the old count, and on ACCEPTED `:317` emits `Connected(hostName, frames)` with `frames > 0`, so the panel hides and input opens as soon as the viewport is valid. The migration path (`promote`, `:492`) behaves the same way.
  - **No user-visible state (B add. 5):** after a video failure the status panel stays GONE; the only trace is `dec=0` in the optional stats overlay.
- **Decision 0019 summary (draft in docs/decisions/0019-video-health-input-gate.md, written by the orchestrator):** HEALTHY = surface attached, the current decoder generation has produced at least one output, and no fault is set. Faults: give-up; no decoded output for 1500 ms while at least 3 non-config frames were queued to the codec; decoder thread not running 2 s after attach. A static screen (no frames arriving) is never a fault: host idle refresh is opt-in (`HEVCEncoder.swift:29-30`), so a blind "no frame for N s" watchdog is wrong. On a fault: capture off (existing `RELEASE_ALL(USER)`, no wire change), feeding and keyframe retries stop, overlay shown; recovery: codec restart at 1 s → at 3 s → session reconnect → "Yeniden dene" button. A new session or config generation opens input only after its first decoded output.
- **Plan hints:**
  - `VideoHealth` is pure Kotlin, UI-thread owned, with an injected clock. Renderer callbacks post to it.
  - Hook points: give-up `VideoRenderer.kt:347-351`; first output and last output time in `drainOutput` (`:527-581`, output dequeued at `:541-544`); inputs queued at `:472`; the gate at `MainActivity.kt:643-649`; `onGiveUp` at `:1154`; `streaming` at `:1884`.
  - The existing 500 ms ticker (`MainActivity.kt:1365-1379`) evaluates the no-output and not-running timers, so no new thread is needed.
  - Base timing on decoder output (`dequeueOutputBuffer`), not on `onFrameRendered`; panels that throttle presentation must not cause false faults.
  - FAULT → `capture.setActive(false)` runs the existing release sequence and `RELEASE_ALL(USER)`; never drop an up event. Re-check that leaving FAULT does not re-open input before the first decoded output.
  - `SessionMachine.kt` changes only to reset the frame counter on automatic reconnect and migration (not on `Event.Start` alone).
  - **Fault injection:** a debug `--es decoder_fault create|configure|dequeue|silent` extra wraps the production `DecoderCodec` (T-158) in a fault-injecting decorator (`video/DecoderFault.kt`). The T-158 fake lives in the test tree and cannot be used by the app. The daily APK is a debug build (verify-H additional issue 3), so the extra itself is the gate until T-185 adds the developer switch; make it one-shot per launch and log `ev=decoder_fault mode=` once.
  - Logs: `ev=video_health state= cause=` per docs/LOGGING.md format. LOGGING.md is not in `files:`; list the new lines under *Açık sorular* for the orchestrator.
- **Risks:** false positives on a legitimately idle screen (covered by the ≥3-inputs rule); recovery loops that hammer the host (the ladder is bounded, and FAULT stops keyframe retries).
- **Serialize with:** T-153 (same file `MainActivity.kt`; chain T-146 → T-151 → T-153 → T-159 → T-160 …) and T-156 (same file `SessionMachine.kt`; chain T-150 → T-156 → T-159 → T-160). `VideoRenderer.kt` follows T-158 (depends_on).
- **Review:** input-state change, so the orchestrator runs `./scripts/codex-review.sh`.
- No wire change; `RELEASE_ALL.reason=USER` is reused. `docs/PROTOCOL.md` is not affected.
- Device acceptance runs in T-164.

## Kapsam dışı

- Generation tokens on video delivery (T-160) and bounded decoder teardown / per-generation state (T-161). T-161 later feeds a "stuck" fault into `VideoHealth`.
- Host changes; a new `RELEASE_ALL` reason (would be a protocol change).
- Latency metrics; MainActivity refactors beyond extracting `VideoHealth`.

## Kabul kriterleri

- [ ] [JVM] `VideoHealthTest` transitions: STARTING → HEALTHY on the first decoded output; HEALTHY → FAULT on give-up, on no output for 1500 ms while ≥ 3 non-config inputs are queued, and on the decoder thread not running 2 s after attach; a static screen (no inputs) stays HEALTHY indefinitely; a new generation is STARTING until its first output.
- [ ] [JVM] Recovery steps are bounded and ordered with a fake clock: codec restart at 1 s, at 3 s, then session reconnect, then the manual "Yeniden dene" state; no step repeats without bound.
- [ ] [JVM] In FAULT, keyframe retries stop and the renderer stops feeding its queue (fake clock), so the ~2 IDR/s loop does not happen.
- [ ] `syncInputActive` includes `videoHealth.inputAllowed`. Entering FAULT calls `capture.setActive(false)`, which sends the existing releases and `RELEASE_ALL(USER)`.
- [ ] [JVM] After an automatic reconnect or a USB↔Wi-Fi migration, input stays closed until the first decoded output of the new generation (`SessionMachine.kt` frame counter reset on those paths).
- [ ] On FAULT an overlay with a short Turkish explanation and a "Yeniden dene" button is shown (`strings.xml`); it hides when HEALTHY again.
- [ ] `ev=video_health state= cause=` is logged on every transition; no key characters or text are logged.
- [ ] Debug extra `--es decoder_fault create|configure|dequeue|silent` forces each fault through the `DecoderCodec` seam; without the extra, behaviour is unchanged.
- [ ] [device] Covered by T-164 (fault → `input_active on=0`, no stuck Shift or pen on the Mac, recovery time).
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
