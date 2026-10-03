---
id: T-160
title: Drop video frames from stale connections and uninstalled configs
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-159, T-150]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/VideoDeliveryGate.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/VideoDeliveryGateTest.kt
  - backlog/tasks/T-160-client-video-delivery-gate.md
---

## Amaç

The client's video reader delivers a frame whenever its `configId` matches the last applied config. It does not check which connection or session the frame came from, and it does not check whether the renderer has actually installed that config. Because the host's first config of every session is always `1`, the check gives no protection across sessions, and inside a session new-config frames can reach the old codec (the T-028 ordering, never carded). After this card no wrong-generation frame reaches the decoder queue, and once `abort()` returns, that connection delivers nothing more.

Source: external architecture review 2026-10-03 (M01, X4, SE3, D3); verification: docs/reviews/2026-10-03/verify-B-client-video.md (P2, additional issue 4).

## Bağlam

- **R-tagged finding (M01).** Per review p11 the work starts with a deterministic failing scenario committed red before the fix (first acceptance item).
- **Evidence (HEAD a30c769; `C/` = `client-android/app/src/main/kotlin/dev/matebridge/client/`):**
  - `C/session/SessionController.kt:843`: `if (hello.configId == currentConfigId) listener.onVideoFrame(msg)`. There is no `video === this` / generation check, unlike the control reader's audio pre-filter `if (control !== this) return` (`:749`).
  - `VideoConn.abort()` (`:803-806`) only sets `closedPosted` and closes the socket. The inner `while (true) { decoder.next() … }` loop (`:837-845`) keeps delivering every complete record already buffered (up to 64 KiB per read), and a delivery already inside `onVideoFrame` completes. Frames can therefore be delivered after `CloseVideo`/`OpenVideo` returned on the engine thread.
  - The host's first config is the constant `StreamCoordinator.configID = 1` (`host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:14`); it only increments within a session. On the client `currentConfigId` (`SessionController.kt:195`) is written only in `ApplyConfig` (`:466-468`) and is never reset on CloseVideo/CloseControl/lose. A leftover frame of session N (config 1) passes the check in session N+1 (config 1).
  - **T-028 in-session ordering (B add. 4):** `ApplyConfig` sets `currentConfigId` on the engine thread, then `onStreamConfig` posts `installConfig` to the UI (`MainActivity.kt:499`). In the same dispatch, `CloseVideo` + `OpenVideo` start the new reader. New-config frames that arrive before the UI runs `r.reconfigure(config)` (`MainActivity.kt:1177`) enter the shared `FrameQueue` and are consumed by the old codec; `reconfigure` then wipes them (`VideoRenderer.kt:243-253`). T-030 healed it on the host side; the client half was deferred in T-028 *Açık sorular* and T-030 *Kapsam dışı* and never carded.
  - Mitigations that exist (keep them): on a normal reconnect `releaseRenderer()` → `detachSurface()` makes `onVideoFrame` drop frames (`MainActivity.kt:501-508`, `:1188`); after `reconfigure` the queue's keyframe gate drops stray P-frames. Realistic exposure is T-096 migration, where the UI stays `Connected` and the renderer stays attached.
  - The renderer is the same `VideoRenderer` object for the app's lifetime, with one shared `FrameQueue`, so the generation boundary must be enforced at delivery, not by swapping objects.
- **Plan hints:**
  - `VideoDeliveryGate` (pure) holds `(videoGen, installedConfigId)` under a small lock. `VideoConn` calls `gate.deliver(gen, configId) { listener.onVideoFrame(msg) }` inside the lock; `abort()` closes the gate for that gen under the same lock. That gives the barrier.
  - Holding the lock across `onVideoFrame` must never block: `FrameQueue.offer` takes only its own short lock and the `vsyncIdle` post is non-blocking. Document this in the gate.
  - `installedConfigId` is set by the UI after `r.reconfigure(config)` (`MainActivity.kt:1177`). Until then, frames of the new config are dropped instead of entering the old codec. The renderer can expose an "installed config" token so the gate does not depend on MainActivity ordering.
  - Reset `currentConfigId` to -1 on CloseVideo/CloseControl.
  - Mirror the audio pre-filter style (`SessionController.kt:749`).
  - Check interaction with T-159: dropping frames before install must not trip the "no output while fed" fault (dropped frames are never queued to the codec).
- **Serialize with:** `VideoRenderer.kt` and `MainActivity.kt` after T-159 (depends_on); `SessionController.kt` after T-150 (depends_on; chain T-150 → T-156 → T-159 → T-160 → T-197). T-161 follows on `VideoRenderer.kt`.
- No wire change; this implements the intent of PROTOCOL §3 steps 5 and 7. `docs/PROTOCOL.md` is not affected.

## Kapsam dışı

- Host changes.
- Changing when the client opens the video connection (gate on delivery instead).
- Decoder teardown and per-generation decoder state (T-161).

## Kabul kriterleri

- [ ] [JVM, first commit, red at HEAD] The barrier scenario below, written against a gate extracted with today's configId-only rule, delivers a stale frame. Commit it failing (or as an `@Ignore`d test with the failing output quoted in the commit message) before the fix; Handoff names the commit.
- [ ] [JVM, deterministic, X4] A reader blocked at a barrier just before delivery; then `abort()` and a new gen/config are activated; then the reader is released → zero frames delivered. The same holds for a reader that still has buffered complete records after `abort()`.
- [ ] [JVM] A frame whose configId ≠ the renderer-installed configId is dropped. Installing config K after K-frames were dropped results in exactly one STARTUP request (the one `reconfigure` already sends) and no FRAMES_DROPPED storm.
- [ ] [JVM] Same configId 1 in consecutive sessions: frames from session N's connection are dropped once session N+1 is current.
- [ ] `currentConfigId` is reset to -1 on CloseVideo/CloseControl.
- [ ] [device] 10× USB↔Wi-Fi migration plus 10× mode change while content moves: each switch recovers on its first keyframe, no `decode_error` in the client log, and `kf_request` lines per switch ≤ 2.
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
