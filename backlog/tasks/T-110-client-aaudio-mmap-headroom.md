---
id: T-110
title: Tablet — Düşük gecikme (AAudio MMAP) seste oyun modunda sürekli cızırtı; çıkış payı ölçümü ve uyarlamalı çıkış arabelleği
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-108]
decisions: [0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/cpp/mbaudio.cpp
  - client-android/app/src/test/
  - backlog/tasks/T-110-client-aaudio-mmap-headroom.md
---

## Amaç

Kullanıcı bulgusu (2026-10-02 ~00:29, T-108 kurulduktan sonra):
- Oyun modunda, Düşük gecikme seste, kalabalık uğultulu sahnede **sürekli cızırtı**. Kullanıcı bunu kısa tık değil, sürekli olarak tarif etti.
- Uyumlu modda (AudioTrack) cızırtı yok.

Orkestratör analizi:
- O anlarda jitter-tampon boşalması yalnızca 3 tane (tek tek kesintiler). Sürekli cızırtıyı açıklamaz.
- Host sesi düzenli gönderiyor (`packets=100/s`, `dropped=0`).
- AAudio MMAP exclusive çıkış arabelleği `buf=480` kare (10 ms = 2 burst).
- `xruns=0` her zaman: bu HAL'de `AAudioStream_getXRunCount` MMAP taşmalarını muhtemelen bildirmiyor. Bu yüzden mevcut "xrun olunca bir burst büyüt" kuralı hiç tetiklenmiyor.
- Hipotez:
  - Oyun modunda (120 fps çözme, jitter 0) yazıcı iş parçacığı zaman zaman 5 ms'lik süreyi kaçırıyor.
  - MMAP halkası boşalınca donanım eski veriyi yeniden çalıyor; sürekli seste bu cızırtı olarak duyuluyor.
  - AudioTrack'in arabelleği daha büyük olduğu için orada duyulmuyor.

Deney (kullanıcıyla, **yapılmadı**, 2026-10-02 sabah yapılacak):
- `am start -S -n dev.matebridge.client/.MainActivity --ei audio_buf_bursts 4` (`buf=960`, 20 ms) ile aynı sahne.
- Cızırtı kaybolursa hipotez doğrulanır.

## Kabul kriterleri

- [ ] **Ölçüm.** Her yazımda çıkış payı ölçülür: `AAudioStream_getFramesWritten − getFramesRead`, ya da timestamp'ten okuma konumu. Saniyelik `ev=stats` satırına şunlar eklenir:
  - `out_headroom_min_frames`
  - `out_headroom_p5_frames`
  - `write_gap_ms_max` (iki yazım arası en uzun süre)
  - `underflow_est` (payın ≤ 0 göründüğü yazım sayısı)

  Ölçüm yolu ayırmaz, kilitlemez, loglamaz (mbaudio.cpp kuralları).
- [ ] **Uyarlamalı çıkış arabelleği.** Pay bir burst'ün altına inerse ya da `underflow_est > 0` ise çıkış arabelleği bir burst büyür (`setBufferSizeInFrames`).
  - Üst sınır kapasite ya da 6 burst.
  - Bir kez büyüyen değer o çıkış yolu için T-108'deki `SafetyMemory` deposuna benzer biçimde saklanır ve sonraki bağlantı oradan başlar.
  - Küçülme yok ya da çok yavaş.
  - `--ei audio_buf_bursts` verilmişse başlangıç odur.
- [ ] Mevcut xrun kuralı korunur (bildiren cihazlar için).
- [ ] A/V hesabı yeni arabellek boyunu hesaba katar (`audio_ms` doğru kalır).
- [ ] Testler:
  - pay hesabının saf mantığı (sahte sayaçlarla);
  - büyüme kuralı ve sınırı;
  - saklama/geri okuma.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi kullanıcıyla: oyun modunda uğultulu sahne, önce deney, sonra bu sürüm.

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff
