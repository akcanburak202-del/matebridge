---
id: T-303
title: Tablet — ölü ve yalnız testte kullanılan kod, sabit titreşim tamponu (FramePacer), API < 31 dalları
status: done
phase: 7
owner: android-client-dev
depends_on: [T-300]
decisions: [0026, 0037]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - client-android/app/build.gradle.kts  # (orkestratör, Codex P3: minSdk satırı)
  - backlog/tasks/T-303-client-dead-code-jitter.md
---

## Amaç

T-297 parti 3 ile kullanıcı kararları (0026 §7 ve 0037). Kanıtlar:
- `docs/reviews/2026-10-08/agents/simp-c-client-video.md`: C1, C3, C4, C6, C8, C9, C11;
- `simp-d-client-session.md`: D3, D7, D8;
- `simp-e-protocol.md`: E1, E2, E3, E8;
- `simp-f-knobs.md`: jitter satırı.

## Kabul

1. **Ölü ve test-yalnız kod:**
   - C1 `codecReportsShown`; C3 `InFlightGauge` artıkları (log alanı sabit kalır);
   - C4 listesi (ölüler silinir, test yardımcıları test kaynağına taşınır);
   - C8 `schedSkipPct` eski yolu; C9 `GameJitter.choose` mod parametresi; C11 küçük kopyalar;
   - D3 listesi (testler `setPolicy`'ye geçer ve **bırakma doğrulamaları kalır**); D8 tek seferlik tercih göçleri.
2. **C6, sıcak yol:** `AdaptivePacer.percentile()` kare başına ayırma yapmaz; önceden ayrılmış dizi kullanır. Sonuç aynı.
3. **Protokol ve kayıt katmanı:**
   - E1: Kotlin `FrameDecoder` test kaynağına taşınır, kullanılmayan import silinir.
   - E2: kayıt katmanı artıkları özel ya da silinir.
   - E3: örtüşen kayıt testleri iki dosyada birleşir. Kurcalama, tekrar ve sayaç testleri ile AUTH_FAILED testi kalır.
   - E8: eski KDoc metinleri ve kopya `hex()`.
4. **Sabit titreşim tamponu (0026 §7):**
   - `--ei jitter`, `FramePacer` (`VsyncClock` **kalır**) ve `GameJitter` kaldırılır;
   - `VideoRenderer.drainOutput` içindeki `!useAdaptive`/unpaced dalları kaldırılır;
   - renderer testleri uyarlamalı yola geçer, `bufferFrames` kurucu varsayılanı kalkar;
   - C2 (`sparseEarly`/`integerLock` her zaman açık) da burada: eski kola göre karşılaştıran testler, mevcut kolun sabitlenmiş sayılarına dönüşür (`tools/pacing` tekrarı).
5. **minSdk 31 (0037):** D7 dalları kaldırılır:
   - `UnbufferedPenDispatch` PER_GESTURE yolu;
   - `routeToCapture` içindeki olay başına `wantsPerGestureRequest`/`isPenTool` kontrolü;
   - `setSurfaceFrameRate` API dalları;
   - FilesController ve ClipboardBridge sürüm kontrolleri.

   (T-301 minSdk değerini değiştirir; bu kart T-301 birleştikten sonra başlarsa dalları silebilir. Önce başlarsa minSdk değerini de burada 31 yapar, çakışmayı Handoff'ta not et.)
6. **Kapsam ve test:**
   - Girdi bırakma yolları, 0019 kuşak ve emeklilik kuralları ve FrameQueue sınırları değişmez.
   - `check.sh` geçer.
   - Silinen satır sayısı Handoff'a.
7. **Belgeler:** KNOBS.md, LOGGING.md ve 0026 orkestratörde; önerilen metni Handoff'a yaz.

## Plan

1. Ölü kod ve test-yalnız kod (C1, C3, C4, C8, C9, C11, D3, D8, E1, E2, E3, E8): kodu oku, doğrula, sil; test yardımcıları `internal` olur ya da test kaynağına taşınır.
2. C6: `AdaptivePacer.percentile()` ön ayrılmış dizi.
3. Sabit titreşim tamponu: `FramePacer`, `GameJitter`, `--ei jitter`, `drainOutput` dalları; `PacerDecision` ve `VsyncClock` kalır; C2 anahtarları kaldırılır, testler sabit sayılara döner.
4. minSdk 31 (0037): D7 dalları.
5. `check.sh`, Handoff.

## Handoff

- **Commit:** `66d74744` (dal `task/T-303-dead-code-jitter`, `main` c907fd8b üzerinde). `check.sh` ALL OK (Android 2170 test geçti).
- **Silinen satır:** toplam 64 dosya, +317 / -1083 (net -766). Üretim kaynağı (`src/main`) +134 / -577; bunun 127 satırı `FrameDecoder.kt`'in test kaynağına taşınması.
- **Yapılanlar**
  - C1 `codecReportsShown` (kurucu, alan, `latencyStageFields` parametresi). C3 `InFlightGauge` (`STALL_NS`, `lastDoneNs`, `onHeld`, `canQueue`, `reset`, zaman parametreleri), `SlotReleaser.reset`; `presentFields` `limit` parametresi gitti, `inflight_limit=0` sabit kaldı.
  - C4 `VideoStats.onShown/onRendered`, `FrameQueue.setCatchUpMaxMs`, `VideoFrameSink`, `FirstOutputBypass.schedule`. Test-yalnız olup testlerde çok kullanılanlar silinmedi, **`internal`** yapıldı ("Tests only"): `FrameQueue.isWaitingKeyframe/isCatchingUp/onDecoderError`, `VideoRenderer.isWaitingKeyframe`, `FirstOutputBypass.isArmed`, `VsyncIdleGate.isAsleep`, `GenerationHandoff.isFinished`, `RecordOpener.open/openAt`, `RecordDecoder.drain`. `AuxFrameQueue.isWaitingKeyframe` dokunulmadı.
  - C8 `schedSkipPct`, `onScheduled`, `skipPctOf` eski dalı (geri düşüş artık `meterPct`). C9 `GameJitter` tamamen gitti. C11 `mime()` x3 -> `videoMime()`, `cadenceNs()` ortak, `onShown` `intervalOf` kullanıyor (`decoderFormat`/`AuxDecoder.format` kopyası yapılmadı).
  - C6 `percentile()` ön ayrılmış `sortScratch`, sonuç aynı.
  - C2 `sparseEarly`/`integerLock` kaldırıldı. Eski kolu karşılaştıran testler silindi ya da sabit sayıya döndü (`IntegerCadenceLockTest.traceReplayThinnedTo60FpsPinned`, `SparseFrameNoHoldTest` kayma/trace sayıları).
  - Jitter: `FramePacer` silindi, `Decision` -> `PacerDecision`, `VsyncClock` yeni dosyada (`VsyncClock.kt`, git rename). `--ei jitter` ve `DevKnobs.jitter/JITTER_ADAPTIVE` gitti; `VideoRenderer.drainOutput` yalnız uyarlamalı yol; `bufferFrames` kurucu parametresi gitti.
  - D3 `AudioRamp.setSilent`, `KeyTracker.isStatsToggle`, `TouchTracker.disabled` setter/`setDisabled`, `InputCapture.setFingersDisabled`, `QuickAck.parseExtra`, `ConnectMode.autoDiscover`, `SettingsPanelState.toggle`; testler `setPolicy`/`setFingerPolicy`/`open+close` kullanıyor, bırakma doğrulamaları duruyor.
  - D8 `migrateTransportToAutoOnce`, `migrateModesOnce`, `LegacyModes`, iki bayrak anahtarı; eski mod kimlikleri `StreamMode.parse` içinde artık `DEFAULT` (`game` hâlâ geçerli kimlik).
  - E1 `FrameDecoder` test kaynağına taşındı, kullanılmayan import silindi. E2 `Records.ensureOutput` silindi, `newCipher(provider)` özel. E3 `RecordAeadPathTest`+`RecordOpenTest`+`RecordOutputSizeTest` -> `RecordLayerTest`; `RecordReceiveAllocTest` -> `RecordAllocTest` (kurcalama, tekrar, sayaç, AUTH_FAILED duruyor). E8 `SETTINGS_PANEL` ve `StreamPrefs.chroma` KDoc, `FixtureTest` kopya `hex()`.
  - D7 / 0037: `minSdk = 31` (**T-301 ile çakışma: `build.gradle.kts` satırı `minSdk = 29` -> `31`; T-301 da aynı satırı değiştiriyorsa birleştirirken tek değer 31 kalmalı**). `UnbufferedPenDispatch` yalnız SOURCE yolu (kurucu `sdkInt` parametresi gitti), `routeToCapture` olay başına kontrol gitti, `setSurfaceFrameRate`, `detectHdrCapability`, `DecoderCodec`, `FilesController`, `ClipboardBridge` sürüm kontrolleri gitti. `>= 33` dalları durdu.
- **Log değişiklikleri (LOGGING.md için):** `mode_layer` satırında `jitter=` ve `jitter_src=` yok; `ev=stats` satırında `buffer=` yok; `ev=profile` `pacer=adaptive` sabit (tools/measure/mblog.py okuyor); `inflight_limit=0` sabit; `modes_migrated` ve `transport_pref_migrated` olayları yok; `set_frame_rate` satırı `strategy_always=true` sabit; overlay "Mod 120 Hz | Uyarlı" aynı.
- **Orkestratör için belge metni:** KNOBS.md'den `jitter` satırı ve `FramePacer` anılan yerler silinmeli; 0026 §7 "sabit titreşim tamponu kaldırıldı (T-303)" olarak kapanır; LOGGING.md'de yukarıdaki alanlar silinir/sabitlenir; `client-android/AGENTS.md` içindeki "`minSdk 29`" satırı 31 olmalı (kapsam dışı).
- **Kapsam dışı / yapılmadı:** C7, C10, C12, D5, D6, D9, D10, `VideoRenderer.decoderFormat` / `AuxDecoder.format` birleştirmesi, `AuxFrameQueue.isWaitingKeyframe`.
- **Cihazda test edilmedi.** Tablette bak:
  1. Günlük 120 ve Oyun 60'ta görüntü akıcı mı, `ev=present` / `phase_lock` satırları öncekiyle aynı mı (sabit tampon yolu gitti; uyarlamalı yol zaten varsayılandı).
  2. Kalemle çizim: örnekler tek tek geliyor mu (`ev=unbuffered path=source` bir kez loglanmalı), kalem kaldırınca ya da ekrandan çıkınca takılı basış yok.
  3. Ctrl+Shift+3 (istatistik) ve Ctrl+Shift+6 (ayar paneli) çalışıyor; "parmak dokunmasını tamamen kapat" açıkken dokunma gitmiyor.
  4. Dosya paylaşımı izin ekranı açılıyor; pano paylaşımı çalışıyor (sürüm kontrolleri kalktı).
  5. Güncelleme sonrası ilk açılışta kayıtlı mod/aktarım tercihi korunuyor.
- **Varsayımlar:** `--ei jitter` artık sessizce yok sayılıyor (bilinmeyen anahtar). Test-yalnız üyeler için `internal` seçildi, çünkü test kaynağına taşımak özel alanlara erişim gerektiriyordu.

## Open questions
