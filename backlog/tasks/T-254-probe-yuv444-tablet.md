---
id: T-254
title: Probe (tablet) — 4:4:4 packing gates: raw YUV sampling on the GPU, ImageReader→GL→SurfaceView presentation, dual decode at 60 fps
status: ready
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0033]
files:
  - probes/yuv444-probe/android/
  - backlog/tasks/T-254-probe-yuv444-tablet.md
---

## Amaç

`docs/research/2026-10-05-yuv444-packing.md` §7 P0 probunun tablet yarısı. Kullanıcı (2026-10-05): 4:4:4 yalnız **60 fps** (Günlük 60) için; 120 gerekmez. Karar kuralı ölçümden önce yazılı: T2 ya da T3 olumsuz → dur, 0033 kalır.

## Bağlam

- Ayrı Android projesi `probes/yuv444-probe/android` (paket `dev.matebridge.yuv444probe`; `probes/decoder-concurrency-probe/android` düzeni, elle derlenir). Swift tarafı ve README ayrı kartta (T-255); bu kart yalnız `android/` altına yazar, çalıştırma bloğunu kendi Handoff'una koyar.
- **T2 ham örnekleme (kapı 1):** GLES `GL_EXT_YUV_target` ve Vulkan `VK_KHR_sampler_ycbcr_conversion` + `RGB_IDENTITY` model desteği var mı (uzantı listeleri logla). Bilinen desenli bir klipte (Y/U/V düzlemleri bilinen değerler; klip yoksa T-248 klipleri + yazılım referansı: `ImageReader` YUV_420_888 CPU okuma) GPU'dan ham Y/Cb/Cr okuması bit-tam mı.
- **T3 sunum (kapı 2):** çözücü → `ImageReader` (PRIVATE, GPU örneklenebilir) → GL (ya da Vulkan) basit birleştirme geçişi (iki görüntüden, ikinci yoksa yalnız ana) → `SurfaceView`. 60 fps tempolu besleme; panel 60 ve 120 Hz'te (dokunarak 120'ye çıkıyor). Ölç: çıkış→latch süresi, kare kaçırma, `dumpsys SurfaceFlinger --latency` aralıkları, katmanın HWC/GPU birleşimi, geçiş GPU süresi; bugünkü doğrudan `SurfaceView` çıkışıyla kıyas (aynı klip).
- **T1 çift çözme (60 fps):** iki `MediaCodec` aynı anda (ana + yardımcı; şimdilik iki mevcut T-248/T-249 klibi yeterli, gerçek v2 klipler T-255'ten gelince aynı prob onları da çalar: dosya adı ile). Çift gecikmesi (ana kuyruğa → yardımcı çıktısı) p50/p95/p99/maks, kaçırma; 2800×1840 ve 1848×1214.
- **T4:** 5 dk güç/ısı (T3 açık): `thermal` durumu, pil akımı varsa.
- Sonuç satırları `Y444PROBE` etiketiyle logcat'e + `files/` altına. MateBridge kapalıyken çalışır (orkestratör çalıştırır). adb/tablet yok; Mac'te pencere açma.

## Kabul kriterleri

- [ ] `assembleDebug testDebugUnitTest` geçer; saf mantık (istatistik, ad çözümleme) JVM testli.
- [ ] Handoff: kopyala-yapıştır çalıştırma bloğu (T2, T3 panel 60/120, T1, T4), beklenen çıktı ve kapı yorumları.

## Plan

## Handoff

## Open questions
