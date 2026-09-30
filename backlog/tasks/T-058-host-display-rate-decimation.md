---
id: T-058
title: Mac — DISPLAY_RATE ile kodlamadan önce seyreltme (60/120), yeniden başlatmasız; BoundedFrameQueue kurtarma düzeltmesi
status: todo
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

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
