---
id: T-282
title: Ölçüm — tablet ve Mac kaynak profili (boşta / video / oyun), hedefli iyileştirme kartları
status: done
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

- Taşıma: Wi-Fi (adb da Wi-Fi üzerinden, 192.168.1.105:5555). APK debug (debuggable) → ART ölçümü release'ten kötümser olabilir; raporda belirtilir.
- Senaryo başına ~100 sn, kullanıcı "hazır" deyince başlar:
  1. 0–60 sn temiz pencere: tablette `/proc/<pid>/task/*/{stat,status}` önce/sonra farkı (iş parçacığı CPU %, gönüllü/gönülsüz bağlam değişimi/s, minor fault/s), `top -H -d 1` 30 örnek, sistem süreçleri (surfaceflinger, codec, adbd, audioserver); `dumpsys meminfo` önce/sonra, logcat GC ve `MB/` satırları. Mac'te `ps` CPU zamanı farkı (MateBridgeApp, VTEncoderXPC, WindowServer, coreaudiod, replayd) ve pencereye düşen host.log.
  2. 60–90 sn: tablette `simpleperf record --app -g -f 500`, Mac'te `sample MateBridgeApp 10` (ikisi de ölçülen süreci bozar, bu yüzden temiz pencereden sonra).
- Betikler scratch'te (`dev_perf.sh`, `mac_perf.sh`, `an.py`); ölçüm bitince hiçbir şey çalışır kalmaz.
- Rapor `docs/research/2026-10-07-perf-profile.md`; eşik üstü adaylara kart.

## Handoff

- Rapor: `docs/research/2026-10-07-perf-profile.md`. Ölçüm 2026-10-06 22:12–22:37, Wi-Fi, 4 senaryo × (60 sn temiz + 30 sn simpleperf/sample). Örnekleyicilerin hepsi durduruldu.
- Kartlar: T-284 (ses örnekleyici, %20–30), T-285 (video alma ayırmaları, oyunda %10–15), T-286 (çözücü yoklaması, ≥500 uyanma/s, yüksek risk), T-287 (sessizlikte AAudio duraklatma, %2 + 200 uyanma/s).
- Değmez: ana iş parçacığı durum metni/vsync, log/istatistik, pacer sıralaması, QuickAck, Mac tarafı.
- Ölçülmedi: debuggable olmayan günlük APK (run-as bedeli). T-284/T-285 sonrası yeniden ölçülecek.
- (a) "boşta" aslında 10 fps: Claude Code'un Terminal'deki dönen simgesi. Gerçek 0 fps değerleri T-141/T-142'de.

## Open questions
