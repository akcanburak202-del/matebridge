---
id: T-286
title: İstemci — çözücü döngülerinde sabit 4/5 ms yoklama yerine olaya bağlı uyanma (10 fps'te ~950 uyanma/s)
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-282]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VsyncIdle.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameQueue.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/InputBufferSlot.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - backlog/tasks/T-286-decoder-loop-wakeups.md
---

## Amaç

T-282 ölçümü (`docs/research/2026-10-07-perf-profile.md` §Sıcak noktalar 3): giriş döngüsü `INPUT_WAIT_NS` = 4 ms, çıkış döngüsü `OUTPUT_WAIT_US` = 5 ms bekliyor. `IdleWait` yalnız 300 ms karesiz kalınca 20 ms'e çıkıyor. 10 fps akışta (ör. Mac'te bir animasyon):
- `mb-decoder` ~265, `mb-decoder-out` ~246, `MediaCodec_loop` ~453 uyanma/s;
- bu üçü ve `CodecLooper` toplam ~%12 tek çekirdek.

60 fps'te aynı iş parçacıkları %34. **Gecikme yolu: risk yüksek.** Protokol değişmez.

## Kabul

1. Önce okuma ve not: her iki döngünün neden zaman aşımıyla beklediği (T-077 giriş yuvası önceden alma, T-141 boşta uyku, çıkış biçim değişimi ve hata yakalama, `VideoHealth`). Plan bunu yazar, sonra uygular.
2. Giriş döngüsü kare yokken `FrameQueue`'da **kare gelene ya da durdurulana kadar** bekler, boş yere dönmez. Kare gelince uyanma gecikmesi bugünküyle aynı ya da daha iyi. Kuyruğa koyan taraf uyandırır.
3. Çıkış döngüsü bekleyen giriş yoksa (kuyruğa verilmiş ve çıkışı alınmamış kare sayısı 0) kısa yoklamayı bırakır. Çıkış beklenirken bugünkü süre korunabilir; zaman aşımı dışında başka bir uyarı yolu yoksa bu açıkça yazılır.
4. Durdurma, oturum değişimi, codec yeniden kurma ve `VideoHealth` takılma algısı aynı çalışır: testler, uyanmayan iş parçacığı kalmadığını gösterir. "Kayıp uyanma" yarışı için test (VsyncIdle'daki gibi).
5. Cihaz A/B (orkestratör, tek seferde): 10 fps arka plan ve Oyun 60. Hedef: 10 fps'te üç iş parçacığında toplam uyanma ≥500/s azalır. `latency_ms` p50/p95 ve `decode_ms` kötüleşmez (±1 ms). Kötüleşirse kart geri alınır, sonuç yazılır.

## Plan

## Handoff

## Open questions
