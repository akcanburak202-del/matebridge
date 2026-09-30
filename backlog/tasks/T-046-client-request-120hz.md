---
id: T-046
title: Tablet — video yüzeyi için akış fps'inde yenileme iste (setFrameRate) ve gerçek panel hızını ölç
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-045]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-046-client-request-120hz.md
---

## Amaç

NOTES 2026-10-01 "120 fps ölçümü": tablet paneli durağan ekranda 120 Hz, ama video yüzeyi güncellenirken HarmonyOS 60 Hz'e iniyor (host 120 fps gönderse bile vsync 16,67 ms). Uçtan uca 120 fps için panelin video sırasında 120 Hz'te kalması gerekiyor. Denenmemiş yol: video yüzeyi için açık kare hızı isteği.

## Kabul kriterleri

- [ ] `STREAM_CONFIG.fps` değiştiğinde video yüzeyi için `Surface.setFrameRate(fps, FRAME_RATE_COMPATIBILITY_FIXED_SOURCE, CHANGE_FRAME_RATE_ALWAYS)` (API 31) çağrılır; ek olarak pencere için `preferredDisplayModeId` = fps'e en yakın 2800×1840 modu (mevcut T-016 kodu varsa onu kullan). GL yolu da aynı isteği yapar.
- [ ] `MB/decoder` istatistik satırına **gerçek panel hızı**: `Display.getRefreshRate()` ve (varsa) `Choreographer` ile ölçülen vsync aralığı (`vsync_ms_p50`). Böylece orkestratör `dumpsys` olmadan da görür.
- [ ] 60 fps akışta davranış değişmez (istek 60 ile yapılır; panel 60 ya da 120'de kalabilir).
- [ ] Birim testi olan saf kısımlar (mod seçimi) test edilir. `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Host tarafı (T-045 düğmeleri var; kodlayıcı T-047). Deneyi orkestratör yürütür: host `MATEBRIDGE_FPS=120`, `dumpsys SurfaceFlinger --latency`.
- HarmonyOS'a özel gizli API/anahtar araştırması: yalnızca belgelenmiş Android API'leri; sonuç olumsuzsa Handoff'ta seçenekleri listele.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
