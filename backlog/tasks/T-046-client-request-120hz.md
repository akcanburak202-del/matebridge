---
id: T-046
title: Tablet — video yüzeyi için akış fps'inde yenileme iste (setFrameRate) ve gerçek panel hızını ölç
status: review
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

1. Saf `FrameRatePolicy` (stream/): mod hedefi ve yüzey hızı STREAM_CONFIG.fps'ten türer (`hz` extra -1 = akışı izle, 0 = dokunma, N = sabit; `frate` T-018 geçersiz kılma korunur). Test.
2. `MainActivity`: her STREAM_CONFIG'te (fps değişince yeniden) `preferredDisplayModeId` (mevcut DisplayModePicker) + `Surface.setFrameRate(fps, FIXED_SOURCE, CHANGE_FRAME_RATE_ALWAYS)` (API 31+, altında 2 argümanlı); surface ve GL yolu aynı istek.
3. Stats: Choreographer kare aralığından `vsync_ms_p50` + `display_hz` (MB/render stats satırı ve overlay).

## Handoff

- **Commit:** `git log task/T-046-client-request-120hz` (SHA orkestratöre raporlandı)
- **Dokunulan dosyalar:** `stream/FrameRatePolicy.kt` (yeni), `MainActivity.kt`, `test/.../video/PacingTest.kt` (FrameRatePolicyTest), bu kart.
- **Varsayımlar:** `hz` extra varsayılanı sabit 120 yerine "akış fps'ini izle" (-1) oldu; 60 fps akışta istek 60 (mod 60 seçilir, panel 60'a inebilir; kabul kriteri izin veriyor). Yüzey yolu artık DEFAULT yerine FIXED_SOURCE kullanıyor (eskiden yalnızca GL/`frate`). `setFrameRate` `videoView.holder.surface` üzerinde; GL yolunda bu GL SurfaceView'ıdır (sunum yüzeyi), decoder yüzeyi değil. fps değişiminde mod yeniden seçilir. `vsync_ms_p50` = Choreographer ana-thread callback aralığı medyanı; `display_hz` = Display.getRefreshRate().
- **Test edilmeyenler / cihazda doğrulanacaklar:** Host `MATEBRIDGE_FPS=120` ile bağlan; logcat `MB/render`: `set_frame_rate rate=120.0 strategy_always=true`, `display_mode requested_hz=120 picked_hz=120`, `stats ... display_hz=... vsync_ms_p50=...` (hedef ~8.33; önceki ölçüm 16.67); yanında `dumpsys SurfaceFlinger --latency`. 60 fps akışta davranış değişmemeli. `--es render surface` ve `gl` ikisi de. Olumsuzsa seçenekler: (a) GL yolunda EGL yüzeyine de setFrameRate, (b) `LayoutParams.preferredRefreshRate` eklemek, (c) küçük sürekli yeniden çizimle paneli 120'de tutmak, (d) HarmonyOS'a özel API (kapsam dışı, belgesiz).
- **Açık sorular:** Yok.
