---
id: T-058
title: Mac — DISPLAY_RATE ile kodlamadan önce seyreltme (60/120), yeniden başlatmasız; BoundedFrameQueue kurtarma düzeltmesi
status: review
phase: 5
owner: mac-host-dev
depends_on: [T-049]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Tests/
  - backlog/tasks/T-058-host-display-rate-decimation.md
---

## Amaç

NOTES 2026-10-01 ~02:20. Tablet paneli dokunma yokken 60 Hz; host 120 fps göndermeye devam ediyor, tablet yarısını çözüp atıyor (çözücü/ağ yükü ve 33 ms boşluklar). Protokol `proto/display-rate` dalında (`87e36db`): `0x07 DISPLAY_RATE(hz)`. Kart dalı `main`'den açılır, `proto/display-rate` merge edilir. Tablet T-059 (bildirimi gönderen) sonra; bu kart tek başına merge edilebilir olmalı (mesaj gelmezse bugünkü davranış).

## Kabul kriterleri

- [ ] Kodek + fixture `display_rate`.
- [ ] Oturumda son `hz` tutulur; hedef kodlama hızı = `min(akış fps, hz)` (hz 0 ya da büyükse akış fps). **Sanal ekran, SCK ve kodlayıcı oturumu yeniden başlatılmaz**, `STREAM_CONFIG` gönderilmez, video bağlantısı kapanmaz.
- [ ] `FrameGate` çalışırken ayarlanabilir; seyreltmede yakalamalar **eşit aralıkla** seçilir (ör. 120→60'ta her ikinci kare, zaman damgası ızgarasına göre; zamanlayıcıyla eski bekleyen kareyi boşaltmak düzensiz hareket üretir). 60→120 yükselişi hemen uygulanır. Kodlanmış P-kareleri asla atılmaz.
- [ ] `CadenceMeter` hedefi etkin hıza göre; log `ev=display_rate hz=… effective_fps=…` (yalnızca değişimde).
- [ ] **`BoundedFrameQueue.push()` düzeltmesi:** delta kare düşürülünce keyframe istenir ama sonraki bağımlı deltalar geçiyor → düşürmeden sonra keyframe gelene kadar deltalar reddedilir (`awaitingKeyframe`), mevcut testlerle tutarlı; test.
- [ ] Testler: seyreltme ızgarası (120→60 eşit aralık, 60→120 hemen), mesaj yokken değişmeyen davranış, kuyruk kurtarma. `./scripts/check.sh` geçiyor (Kotlin fixture testi `display_rate` için T-059 gelene kadar kırmızı olabilir — bu yüzden Kotlin kodek + fixture testini de bu karta dahil etme; orkestratör T-059'u birlikte merge eder).

## Kapsam dışı

- Tablet (T-057/T-059). Cihaz ölçümü orkestratörde.

## Plan

1. Core codec: `MessageType.displayRate = 0x07`, `DisplayRate { hz: u16, reserved }`, `Message.displayRate`; SessionMachine delivers it like `STREAM_PREFS` (active session only); fixture test entry `display_rate`.
2. Core policy: `DisplayRateState` (last hz, `effectiveFps(streamFps:)` = `min(streamFps, hz)`, hz 0 or >= stream fps gives stream fps, lower clamp 24; `update` reports change so the log fires only on change).
3. `FrameGate` gets a mutable target interval. `FramePacer.setTargetFps(_:)`: when target < stream fps the pacer is in decimation mode: the grid is judged on the capture timestamp (same host clock), a frame before the slot is dropped (never held, so no timer flush of an old frame), the grid advances on each pass; slot busy means the usual single pending (newest wins). Raising to the stream fps resets the grid and returns to the existing now-based mode (applied on the next frame). Bypass (keyframe resubmit) unchanged. Encoded frames are never dropped.
4. `HEVCEncoder.setTargetFps` (under its lock), `CadenceMeter.setTargetFps` + `decimated` counter in the window log; `VideoPipeline.setDisplayRate(hz)` applies to encoder and meter and remembers it for a pipeline restart.
5. `StreamCoordinator`: `.displayRate(sessionID, hz)` event (coalesced per session key), stored in the active session (reset on session start), applied to the current pipeline and to every newly created one; `ev=display_rate hz=.. effective_fps=..` logged only on change. No STREAM_CONFIG, no restart.
6. `BoundedFrameQueue.push`: dropping a delta sets `awaitingKeyframe` so deltas are refused until a keyframe/config-then-keyframe arrives.
7. Tests: codec/fixture, policy, decimation grid (120 to 60 every second frame, jittered, 60 to 120 immediate, no message = unchanged), queue recovery, cadence target.

## Handoff

- **Commit:** tip of `task/T-058-host-display-rate-decimation` (SHA in the agent's report).
- **Dokunulan dosyalar:** MateBridgeCore: `ProtocolConstants.swift`, `Message.swift`, `Messages.swift` (`DisplayRate`), `Session/SessionMachine.swift` (delivers 0x07 like STREAM_PREFS), `Input/InputStateMachine.swift` (one case added to an exhaustive switch), `Video/DisplayRatePolicy.swift` (new), `Video/FrameGate.swift`, `Video/BoundedFrameQueue.swift`, `Video/CadenceMeter.swift`. MateBridgeHost: `Video/HEVCEncoder.swift`, `Video/VideoPipeline.swift`, `Session/StreamCoordinator.swift`. Tests: `FixtureTests.swift` (display_rate), `Video/FrameGateTests.swift` (DecimationTests), `Video/VideoTests.swift`, `Video/CadenceTests.swift`. Merged `proto/display-rate` (87e36db).
- **check.sh:** Swift (host-mac 131 XCTest + swift-testing, probes) green. Gradle red as expected: only `FixtureTest.everyFixtureFileHasATestCase` (no Kotlin `display_rate` case until T-059).
- **Varsayimlar:** effective fps = `min(stream fps, hz)`; hz 0 or >= stream fps gives stream fps; hz below 24 is clamped to 24 (card silent; guards a garbled report). The decimation grid runs on capture timestamps (same host clock as `HostClock.nowUs`); decimation tolerance is min(2 ms, source interval/4) so 120 to 60 picks exactly every second capture. A frame before its slot is dropped, never held (no timer flush of an old frame). If the encoder slot is busy a grid-passing frame is held as the single pending (newest wins) and submitted on slot release. Keyframe re-submissions bypass the gate; encoded frames are never dropped. Normal mode (no message, or hz >= stream fps) is the old code path (test compares both). The coordinator stores the rate, re-applies it to every new pipeline (reconfiguration builds a new encoder), and resets it on session start/end (a grace-period pipeline returns to the stream fps). `decimated=` added to the cadence log. `ev=display_rate hz= effective_fps=` (component net) is logged only when hz or effective fps changes.
- **BoundedFrameQueue:** dropping a delta now sets `awaitingKeyframe`; later deltas are refused until a keyframe is pushed (CODEC_CONFIG does not lift it). Frames already queued when the drop happens (including the incoming delta that caused it) are kept, as the existing `testKeyframeSurvivesOverflow` requires; they depend on the dropped frame, so the client may still see one or two broken deltas before the keyframe. Purging them too would be a further change (not done).
- **Test edilmeyenler / cihazda dogrulanacaklar:** nothing ran against real capture/encoder. With T-059 on device: hz=60 on a 120 fps stream gives `enc_fps`~60, `decimated`~60/s, `cap_fps`~120 (SCK untouched), even 16.7 ms presentation gaps; touching the screen (hz 120) returns to ~120 at once with no `stream_reconfigure` and no video reconnect; `cap_late` is judged against the new target.
- **Acik sorular:** `InputStateMachine.swift` was touched only for the exhaustive switch (inside `MateBridgeCore/`). No Kotlin codec (T-059).
