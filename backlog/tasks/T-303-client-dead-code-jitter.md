---
id: T-303
title: Tablet — ölü ve yalnız testte kullanılan kod, sabit titreşim tamponu (FramePacer), API < 31 dalları
status: todo
phase: 7
owner: android-client-dev
depends_on: [T-300]
decisions: [0026, 0037]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
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

## Handoff

## Open questions
