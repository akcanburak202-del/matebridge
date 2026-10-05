---
id: T-256
title: Probe (tablet) — 4:4:4 GL merge path latency with depth-1 presentation vs today's direct path
status: ready
phase: 6
owner: android-client-dev
depends_on: [T-254]
decisions: [0033]
files:
  - probes/yuv444-probe/android/
  - backlog/tasks/T-256-probe-yuv444-gl-latency.md
---

## Amaç

T-254 (NOTES 2026-10-05 ~20:55): GL birleştirme yolu akıcı (HWC, kaçırma yok) ama varış→ekran 55–61 ms, varış→latch 41–48 ms; `draw_call_ms` ~13 ms (eglSwapBuffers bloklanıyor) → üretici BufferQueue'da ~2 kare önde. Büyük olasılıkla probun sunum düzeninden. Bu kart gecikmeyi ürüne yakın sunumla ölçer ve **aynı ölçütle** bugünkü doğrudan yolla (çözücü → SurfaceView) kıyaslar. Hedef (karar kuralı, ölçümden önce): GL yolu varış→ekran p50 ve p95'te doğrudan yola göre **≤ +5 ms** → 4:4:4 uygulamasına geçilebilir; > +10 ms → dur, 0033 kalır; arası → kullanıcıyla konuşulur.

## Bağlam

- Mevcut prob: `probes/yuv444-probe/android` (T-254; `t3`, `direct`, native EGL/GLES kütüphanesi). Ürünün sunum düzeni referans: istemci `video/FramePacer.kt`, `AdaptivePacer.kt`, `SlotReleaser.kt` (`releaseOutputBuffer(ts)`, lead 6 ms, vsync hizalı slotlar) — okunabilir, değiştirilmez.
- **Ölçüt (iki yol için aynı):** "varış" = ana karenin çözücüye verildiği an (probun bugünkü tanımı); "ekran" = gerçek sunum zamanı: GL yolunda `EGL_ANDROID_get_frame_timestamps` (DISPLAY_PRESENT / LATCH), doğrudan yolda `MediaCodec.OnFrameRenderedListener` + mümkünse `Choreographer`/`dumpsys SurfaceFlinger --latency` ile çapraz kontrol. İkisi için p50/p95/p99, kaçırma, sunum aralığı.
- **GL yolu sunum varyantları** (`--es present <mod>`):
  1. `queue` — bugünkü (taban, karşılaştırma için).
  2. `depth1` — bir önceki swap'ın latch'i (frame timestamps ya da fence) gelmeden yeni swap yapılmaz; yeni yardımcı/ana kare gelirse beklerken en yenisi kullanılır.
  3. `pts` — `eglPresentationTimeANDROID` ile ürünün slot mantığına benzer hedef: bir sonraki vsync − lead (vsync: `Choreographer` ya da `EGL_ANDROID_get_frame_timestamps` COMPOSITE_DEADLINE/INTERVAL).
  4. İsteğe bağlı: `swapint0` (eglSwapInterval 0) etkisi.
- Doğrudan yolun da ürün gibi `releaseOutputBuffer(ts)` ile hedefli bırakma varyantı olsun (`--es direct_mode immediate|pts`), böylece kıyas adil.
- T-254'teki hata: `dumpsys SurfaceFlinger --list` seçimi `Background for SurfaceView` katmanını aldı → BLAST `SurfaceView[...]` katmanını seçen yardımcı komutu Handoff bloğunda düzelt.
- Klip: `main_2800x1840_60` / `aux_2800x1840_60` (T-255) ve 1848 karşılığı; 60 fps tempolu; panel 60 ve (dokunma olmadan Huawei izin vermezse not et) 120.
- Sonuç satırı `Y444PROBE lat mode=... path=gl|direct ...`; Handoff'ta kopyala-yapıştır çalıştırma bloğu (orkestratör çalıştırır, MateBridge kapalı, ~10 dk). adb/tablet yok; Mac'te pencere açma.

## Kabul kriterleri

- [ ] `assembleDebug testDebugUnitTest` geçer (saf mantık JVM testli: sunum kararı, istatistik).
- [ ] Handoff: çalıştırma bloğu, beklenen çıktı, karar kuralı yorumu.

## Plan

## Handoff

## Open questions
