---
id: T-282
title: Ölçüm — tablet ve Mac kaynak profili (boşta / video / oyun), hedefli iyileştirme kartları
status: todo
phase: 6
owner: orchestrator
depends_on: []
decisions: []
files:
  - docs/research/
  - docs/NOTES.md
  - backlog/tasks/T-282-perf-profile.md
---

## Amaç

Kullanıcı (2026-10-06): sadeleştirmeler Mac ve tabletin yükünü azaltır mı? Tahmin yerine ölçüm. Kod değişikliği yok; çıktı, ölçülmüş kazancıyla hedefli iyileştirme kartları.

İlk gözlem (2026-10-06 ~21:58, Günlük SDR, ekran ~10 fps, ses yok):
- Tablet `dev.matebridge.client` tek çekirdeğin %24'ü (14 user + 10 kernel), 160 s'de 54k minor fault (~340/s). `mb-audio` sessizken de aktif (AAudio MMAP her 5 ms'de sessizlik yazıyor). `MediaCodec_loop`, `CodecLooper` ve `mb-decoder` görünür. Ana iş parçacığı her vsync'te uyanıyor (NOTES ~1064).
- Mac `MateBridgeApp` %4, 80 MB; `VTEncoderXPCService` %0,4.

## Kabul

1. Senaryolar, her biri ~2 dk. Kullanıcıya bir kez sorulur, kullanım ~10 dk:
   - (a) boşta, durağan masaüstü, ses yok;
   - (b) YouTube 1080p60 video (sesli);
   - (c) Oyun 60 (tercihen RE4 ya da Astris SDR);
   - (d) yazı yazma/kaydırma.
   Wi-Fi ve USB'den biri; hangisi seçildiyse not edilir.
2. Tablet, her senaryoda:
   - `dumpsys cpuinfo` farkı;
   - `top -H -d 1` ile iş parçacığı payları (en az 30 örnek);
   - `simpleperf record --app dev.matebridge.client -g` (APK debuggable ise; değilse not et), en sıcak 15 fonksiyon;
   - sayfa hatası ve GC (`dumpsys meminfo`, logcat `GC`);
   - uyanma kaynakları (iş parçacığı başına bağlam değişimi `/proc/<pid>/task/*/status`).
3. Mac, her senaryoda:
   - `sample MateBridgeApp 10` en sıcak yollar;
   - `ps` CPU/RSS;
   - VTEncoderXPC ve WindowServer payı (karşılaştırma için).
4. Rapor: `docs/research/2026-10-07-perf-profile.md`. Senaryo × iş parçacığı tablosu, sıcak noktalar ve her aday için tahmini kazanç (CPU %, uyanma/s), risk ve bedel. Aday örnekleri (ölçüm doğrulamalı):
   - uzun sessizlikte AAudio akışını duraklatmak (bedel: ilk ses gecikmesi);
   - vsync geri çağırmasını yalnız gerektiğinde istemek;
   - kare başına ayırmaları azaltmak;
   - log/istatistik maliyeti.
5. Kazancı ölçülebilir (≥%2 tek çekirdek ya da ≥100 uyanma/s) adaylar için ayrı kart açılır. Altındakiler raporda "değmez" diye kalır.
6. Örnekleyiciler yalnız ölçüm sırasında çalışır, sonra durdurulur (kullanıcı tercihi). Mac'te pencere açılmaz.

## Plan

## Handoff

## Open questions
