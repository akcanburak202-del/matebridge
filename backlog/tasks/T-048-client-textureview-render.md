---
id: T-048
title: Tablet — TextureView ile gösterim deneyi (Huawei yenileme yöneticisi video yüzeyini 60 Hz'e indiriyor)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-046]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-048-client-textureview-render.md
---

## Amaç

T-046 cihaz denemesi (2026-10-01): `Surface.setFrameRate(120, FIXED_SOURCE, ALWAYS)` ve `preferredDisplayModeId` = 120 Hz isteği SurfaceFlinger'a ulaşıyor (`sfFps 120`), ama Huawei `AGPService` / `FrameRateManager` son kararı 60 veriyor: `JudgeFinalLcdFps ... isSurface 1 ... final lcd fps: 60`. Aynı günlükte `com.huawei.appmarket` kaydırılırken `sceneinfo(120,…)` ile 120 Hz alıyor. Hipotez: yönetici, ayrı bir video yüzeyi (SurfaceView) gösteren uygulamayı "video sahnesi" sayıp 60'a indiriyor; görüntü uygulamanın kendi penceresinde (TextureView) çizilirse `isSurface` 0 olur ve 120 Hz verilebilir.

## Kabul kriterleri

- [ ] Üçüncü gösterim yolu `render=texture`: MediaCodec çıkışı `TextureView`'in `SurfaceTexture`'ından yaratılan `Surface`'e; TextureView tam ekran, mevcut görünüm alanı/letterbox hesabıyla aynı yerleşim. Seçim bugünkü gibi başlatma ekstrası (`--es render texture`) ve kalıcı ayar anahtarı (`render` = surface|gl|texture); varsayılan değişmez (surface).
- [ ] Texture yolunda da T-046'daki kare hızı isteği (`setFrameRate` pencere/yüzey için uygulanabildiği kadar, `preferredDisplayModeId`) yapılır.
- [ ] İstatistikler (`display_hz`, `vsync_ms_p50`, `fps`, `drop`) üç yolda da aynı.
- [ ] Girdi yolu etkilenmez (dokunma/kalem koordinatları aynı görünüm alanı).
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Deneyi orkestratör yürütür: host `MATEBRIDGE_FPS=120`, `logcat` AGPService satırları, `dumpsys SurfaceFlinger --latency`.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
