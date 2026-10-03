---
id: T-160
title: Drop video frames from stale connections and uninstalled configs
status: done
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
  - Holding the lock across `onVideoFrame` must never block: `FrameQueue.offer` takes only its own short lock and the `vsyncIdle` post is non-blocking. Also, `offer` may return a request that `VideoRenderer.onFrame` passes to `onKeyframeRequest` → `controller.trySend` → `SendQueue.send` (`Codec.encode`, and `onOverflow` on the first overflow; `SendQueue.kt:82-89`): confirm that this path takes no lock the engine thread holds while calling `abort()`, or move the request out of the locked section. Document this in the gate.
  - `installedConfigId` is set by the UI after `r.reconfigure(config)` (`MainActivity.kt:1177`). Until then, frames of the new config are dropped instead of entering the old codec. The renderer can expose an "installed config" token so the gate does not depend on MainActivity ordering.
  - Reset `currentConfigId` to -1 on CloseControl and session loss (`closeAll`/`lose`), **not** on CloseVideo: `onConfig` emits ApplyConfig → CloseVideo → OpenVideo (`SessionMachine.kt:347-349`), so a reset on CloseVideo would wipe the config just applied (`SessionController.kt:466-467`) and no frame of the new reader would ever match; a video-only reconnect (`SessionMachine.kt:371`, same config) would break the same way. Generation safety comes from the gate's `videoGen`.
  - Mirror the audio pre-filter style (`SessionController.kt:749`).
  - Check interaction with T-159: dropping frames before install must not trip the "no output while fed" fault (dropped frames are never queued to the codec).
- **Serialize with:** `VideoRenderer.kt` and `MainActivity.kt` after T-159 (depends_on); `SessionController.kt` after T-150 (depends_on; chain T-150 → T-156 → T-160 → T-197; T-159 no longer touches the session files). T-161 follows on `VideoRenderer.kt`.
- No wire change; this implements the intent of PROTOCOL §3 steps 5 and 7. `docs/PROTOCOL.md` is not affected.

## Kapsam dışı

- Host changes.
- Changing when the client opens the video connection (gate on delivery instead).
- Decoder teardown and per-generation decoder state (T-161).

## Kabul kriterleri

- [x] [JVM, first commit, red at HEAD] The barrier scenario below, written against a gate extracted with today's configId-only rule, delivers a stale frame. Commit it failing (or as an `@Ignore`d test with the failing output quoted in the commit message) before the fix; Handoff names the commit.
- [x] [JVM, deterministic, X4] A reader blocked at a barrier just before delivery; then `abort()` and a new gen/config are activated; then the reader is released → zero frames delivered. The same holds for a reader that still has buffered complete records after `abort()`.
- [x] [JVM] A frame whose configId ≠ the renderer-installed configId is dropped. Installing config K after K-frames were dropped results in exactly one STARTUP request (the one `reconfigure` already sends) and no FRAMES_DROPPED storm.
- [x] [JVM] Same configId 1 in consecutive sessions: frames from session N's connection are dropped once session N+1 is current.
- [x] `currentConfigId` is reset to -1 on CloseControl and session loss (`closeAll`/`lose`), **not** on CloseVideo (`onConfig` emits ApplyConfig → CloseVideo → OpenVideo, `SessionMachine.kt:347-349`). Generation safety comes from the gate's `videoGen`. [JVM] The action sequence of a STREAM_CONFIG leaves the new reader deliverable, and so does a video-only reconnect with the same config.
- [ ] [device] 10× USB↔Wi-Fi migration plus 10× mode change while content moves: each switch recovers on its first keyframe, no `decode_error` in the client log, and `kf_request` lines per switch ≤ 2.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **Kırmızı commit.** `session/VideoDeliveryGate.kt` bugünkü kuralla çıkarılır (yalnızca `configId == son ApplyConfig`;
   `onAction`/`close`/`install` etkisiz). `VideoDeliveryGateTest.kt` tüm senaryoları yazar; bugünkü kuralda başarısız
   olanlar `@Ignore` ile, başarısız çıktı commit mesajında alıntılanır. `check.sh` geçer.
2. **Kapı (saf).** Tek küçük kilit altında `openGen` (açık video bağlantısı), `appliedConfigId` + uygulanan config
   nesnesi (motor, `ApplyConfig`) ve `installed` (renderer'ın kurduğu config nesnesi, UI). Kimlik `===` ile: her
   STREAM_CONFIG ayrı çözülmüş bir nesne olduğundan art arda oturumların aynı `config_id=1`'i karışmaz.
   - `onAction(a)` (motor, `exec`'in başında tek satır): `ApplyConfig` → uygula; `CloseControl` ve `PromoteCandidate`
     (yeni oturum) → `appliedConfigId=-1`, uygulanan=null; `OpenVideo` → `openGen=a.gen`; `CloseVideo` → kapalı.
     `CloseVideo`'da config sıfırlanmaz (STREAM_CONFIG = ApplyConfig → CloseVideo → OpenVideo; yalnız-video yeniden
     bağlanma aynı config ile).
   - `close(gen)` (`VideoConn.abort()`): kilit altında, yalnızca `openGen == gen` ise kapatır. Kilit, süren bir teslimin
     bitmesini bekler: `abort()` döndükten sonra o bağlantı hiçbir şey teslim etmez (tampondaki kayıtlar dahil).
   - `install(config)` (UI): renderer `reconfigure` içinde kuyruk sıfırlandıktan sonra çağırır (yeni kurucu parametresi
     `onConfigInstalled`), MainActivity sıralamasına bağlı değil.
   - `deliver(gen, configId) { … }`: `gen == openGen && configId == appliedConfigId && applied === installed` ise blok
     kilit altında çalışır. Kurulumdan önce gelen yeni config kareleri eski codec'e girmez, düşer (kuyruğa hiç girmez:
     FRAMES_DROPPED / T-159 "beslenip çıktı yok" etkilenmez; host STARTUP'ta CODEC_CONFIG'i yeniden yollar, T-030).
3. **Kilit analizi (kapıda belgelenir).** Teslim yolu: `onVideoFrame` → `FrameQueue.offer` (kendi kısa kilidi) →
   `onKeyframeRequest` → `trySend` → `SendQueue` kilidi (bekleme yok; `take()`'in `wait()`'i kilidi bırakır) → taşmada
   `ControlConn.abort` (socket close, wipe) + mailbox post; `vsyncIdle` + `ui.post` bloklamaz. Motor `close`'u hiçbir
   kilit tutmadan çağırır; UI `install`'u kilitsiz çağırır. Döngü yok.
4. **SessionController.** `currentConfigId` alanı kapıya taşınır; `exec` başında `videoGate.onAction(a)`;
   `VideoConn.abort()` → `videoGate.close(gen)`; okuyucu `videoGate.deliver(gen, hello.configId) { listener.onVideoFrame }`;
   `fun videoConfigInstalled(config)`. Değişiklik küçük ve yerel (T-156 paralel).
5. **VideoRenderer / MainActivity.** `onConfigInstalled: (StreamConfig) -> Unit = {}`; MainActivity onu
   `controller.videoConfigInstalled(it)`'a bağlar (tek satır).
6. Testler: bariyer (kilit içinde süren teslim `close`'u bekletir; bariyerde bekleyen okuyucu bırakılınca 0 kare;
   tampondaki kayıtlar 0 kare), kurulmamış config düşer + gerçek `VideoRenderer` (FakeDecoder) ile tam bir STARTUP,
   FRAMES_DROPPED yok; ardışık oturumda `config_id=1`; gerçek `SessionMachine` eylem dizileri (STREAM_CONFIG,
   yalnız-video yeniden bağlanma, oturum kaybı, migration) ile teslim edilebilirlik.

Riskler: kilit altında teslim → kilit yalnızca bu kapıya ait, motor/UI onu başka kilit tutarken almaz. Göç
(T-096/T-205) sırasında UI `Connected` kalır; yeni oturumun config'i kurulana kadar kareler düşer (≤ bir UI turu).

## Handoff

- **Commit:** `ae388ae` (Codex P2 düzeltmesi; öncesinde `main` birleştirildi) ve `6586453` (asıl düzeltme; dal
  `task/T-160-client-video-delivery-gate`). Kırmızı adım: `0b615d3` — kapı bugünkü
  configId-only kuralla çıkarıldı, 9 senaryo `@Ignore` ile, başarısız çıktı commit mesajında alıntılı (bariyer
  senaryosu `aReaderReleasedAfterAbortAndAVideoReconnectDeliversNothing`: `expected:<0> but was:<1>`). Plan: `c506fe5`.
- **Dokunulan dosyalar:**
  - `session/VideoDeliveryGate.kt` (yeni, saf): `onAction(Action)` (motor), `close(gen)` (abort bariyeri),
    `install(StreamConfig)` (UI), `deliver(gen, configId) { … }` (okuyucu, blok kilit altında); kilit sırası analizi
    sınıf yorumunda.
  - `session/SessionController.kt`: `currentConfigId` alanı kapıya taşındı; `exec` başında `videoGate.onAction(a)`;
    `VideoConn.abort()` → `videoGate.close(gen)`; okuyucu `videoGate.deliver(...)`; `fun videoConfigInstalled(config)`;
    bağlantı başına tek `ev=video_gate_open` satırı.
  - `video/VideoRenderer.kt`: kurucu parametresi `onConfigInstalled: (StreamConfig) -> Unit = {}`; `reconfigure` onu
    kuyruk sıfırlandıktan ve yeni kuşak başladıktan sonra, **STARTUP isteğinden önce** çağırır (Codex P2: istekten sonra
    kurulsaydı, UI iş parçacığı istekten hemen sonra bekletildiğinde host'un CODEC_CONFIG + keyframe cevabı kapıda
    düşer, toparlanma ikinci isteğe kalırdı). Eski config/oturum kareleri yine geçemez (configId/uygulanan nesne).
  - `MainActivity.kt`: tek satır, `onConfigInstalled = { c -> controller.videoConfigInstalled(c) }`.
  - `test/.../session/VideoDeliveryGateTest.kt` (12 test; `theHostsStartupAnswerArrivingBeforeReconfigureReturnsIsDelivered`
    host cevabını STARTUP isteği ile `reconfigure()` dönüşü arasında bir okuyucu iş parçacığından teslim eder; P2
    düzeltmesinden önce `expected:<[true, true, false]> but was:<[false, false, false]>` ile kırmızıydı).
- **Varsayımlar:**
  - "Kurulu config" kimliği nesne kimliğidir (`===`): `onStreamConfig`'in taşıdığı `StreamConfig` nesnesi UI'dan aynen
    geri gelir; her STREAM_CONFIG ayrı çözülür, bu yüzden ardışık oturumların `config_id=1`'i karışmaz. Eşit ama farklı
    nesne kurulmuş sayılmaz (test var).
  - `currentConfigId` CloseControl'de ve migration'ın `PromoteCandidate`'inde de sıfırlanır (yeni oturum; ardından
    `onMessage(first)` ApplyConfig'i getirir). CloseVideo'da sıfırlanmaz.
  - Kurulumdan önce düşen yeni config kareleri (CODEC_CONFIG dahil) kaybolur; `reconfigure`'ün STARTUP isteğine host
    CODEC_CONFIG + keyframe ile cevap verir (T-030). Önceden de bu kareler eski kuyruğa girip `reconfigure` ile
    siliniyordu; istek sayısı değişmez. Düşen kareler kuyruğa girmez: FRAMES_DROPPED ve T-159 "beslenip çıktı yok"
    etkilenmez.
  - Kilit altında teslim: `FrameQueue.offer` → `trySend` → `SendQueue` (beklemesiz) → taşmada `ControlConn.abort` +
    kilitsiz mailbox post; `vsyncIdle` volatile + `Handler.post`. Motor/UI kapı çağrılarını başka kilit tutmadan yapar.
- **Test edilmeyenler / cihazda doğrulanacaklar (orkestratör, tablet):**
  1. 10× USB↔Wi-Fi migration, içerik hareket ederken: her geçiş ilk keyframe'de toparlanır; istemci logunda
     `decode_error` yok; geçiş başına `kf_request` satırı ≤ 2; her geçişte bir `ev=video_gate_open vgen=… gated=N`
     (N küçük, tipik 0–birkaç kare).
  2. 10× mod değişikliği (60/120/144 ya da ölçek; yeni STREAM_CONFIG) içerik hareket ederken: aynı ölçütler; görüntü
     her seferinde geri gelir (sıfırlama video'yu durdurmamalı).
  3. Video-only yeniden bağlanma (Mac tarafında video soketi kopması, aynı config): görüntü yeniden kurulumsuz devam eder.
  4. Normal yeniden bağlanma (Wi-Fi kapat/aç ya da uygulama arka plan/ön plan): görüntü gelir, `video_health` `healthy`.
- **Açık sorular:**
  - `docs/LOGGING.md` (istemci, video/oturum bölümü) için önerilen satır:
    `- ev=video_gate_open vgen=N config_id=N gated=N` (I, video bağlantısı başına bir kez): bağlantının ilk karesi
    renderer'a teslim edildi; `gated` = ondan önce kapının düşürdüğü kare (renderer yeni config'i kurmadan gelenler).
    Hiç teslim etmeden kapanan bağlantı satır yazmaz.
  - Kapsam dışı not: düşen kare sayısı `ev=stats` satırına eklenmedi (T-161 ya da istatistik kartı isterse).
