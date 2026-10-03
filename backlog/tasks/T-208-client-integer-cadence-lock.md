---
id: T-208
title: Phase-lock 60 fps content on a 120 Hz panel (integer cadence lock)
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-168, T-183]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/AdaptivePacer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt   # only if the lock needs the content interval passed in
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - tools/pacing/sim.py
  - tools/pacing/README.md
  - docs/LOGGING.md
  - backlog/tasks/T-208-client-integer-cadence-lock.md
---

## Amaç

Cihaz ölçümü 2026-10-04 (docs/NOTES.md "oyun takılması"): Ori and the Will of the Wisps, USB, Oyun 60 (`2800x1840 fps=60`). Kullanıcı oyunda dokunma/trackpad kullandığı için Huawei AGP paneli 120 Hz'e çıkarıyor (`hz=120` pencerelerin %84'ü). Host içeriği düzenli üretiyor (yakalama aralığı %97,8 tam 16,7 ms; host encode ~7 ms, yazma < 0,5 ms; tablet varış boşlukları %0,1 > 12 ms). Ama tablette karelerin **%25'i yanlış sürede gösteriliyor**: 120 Hz'de 60 fps içerik her kare 2 vsync kalmalıyken %14 1 vsync, %10 3 vsync (`skip_pct` ortanca %10, p90 %18,5). Bütün kareler `path=unlocked`. Kullanıcı bunu "akıcılığın kısa süre kaybolduğu takılma" olarak görüyor; tüm modlarda.

Kök neden: `AdaptivePacer`'ın faz kilidi (T-060) yalnız içerik aralığı ≈ bir panel periyodu (±%15) iken kuruluyor. İçerik aralığı = 2 periyot (60/120) olunca kilit yok, her kare bağımsız olarak en erken uygun slota gidiyor; ±4 ms SurfaceFlinger/çözme salınımı 1-3 vsync tutmaya dönüşüyor. 1 karelik tampon denemesi (`--ez dev true --ei jitter 1`, `FramePacer`) %10 → %8,3 iyileştirdi ama +7 ms gecikme ekledi ve tutmaları sabitlemedi, çünkü panel hızında sıralıyor.

## Bağlam

- `AdaptivePacer.kt` sınıf belgesi ve `scheduleLocked` (kilit, `k` = yakalama aralığı / periyot, `lockSlot`, `REPHASE`, T-065 boşluk kuralı, T-115 ısınma).
- Hedef: içerik aralığı bir **tam sayı** `n` panel periyoduna yakınken (en az `n` ∈ {1, 2}; içerik 120 fps + panel 60 Hz durumu host DISPLAY_RATE ile zaten 60'a iniyor) kilit kurulsun; kilitliyken kare `n` vsync aralıklarla aynı fazda gösterilsin. Geç gelen kare kilidi kaydırmasın (bugünkü kilit kuralları gibi: ya slotuna sığar ya en yeni kazanır).
- Gecikme: kilit fazı, varış penceresi [ideal, ideal + p99 jitter] ilk uygun slota düşecek şekilde seçilir (T-060 ile aynı ilke); sabit ek tampon yok.
- Panel 60↔120 değiştiğinde (dokunma başlar/biter) `n` ve faz yeniden kurulmalı; geçişte en fazla bir kare atlama/çift.
- `tools/pacing/sim.py` trace replay: kartın kendi ölçümü buradan da doğrulanır. Ölçümün ham verisi (pace_trace + host latency.csv) depoya konmaz; yalnızca zamanlama sütunlarından küçük bir alıntı (`trace7` gibi) eklenebilir.

## Kapsam dışı

- Panelin 120 Hz'e çıkmasını engellemek (AGP, uygulama yolu yok — NOTES 2026-10-02).
- Host tarafı, protokol, `FramePacer` (jitter tamponu).

## Kabul kriterleri

- [ ] [JVM] Sentetik akış: 60 fps içerik (± 4 ms varış titremesi), 120 Hz ızgara → kilit kurulur (`path=locked`), tutma dağılımı ≥ %99 tam 2 vsync; aynı akış 60 Hz ızgarada bugünkü davranış (n=1) değişmez.
- [ ] [JVM] Panel 120 → 60 → 120 geçişi: kilit yeniden kurulur, geçiş başına en fazla bir kare tekrar/atlama.
- [ ] [JVM] 120 fps içerik / 120 Hz (bugünkü çizim yolu) değişmez: mevcut T-060/T-065/T-115 testleri yeşil.
- [ ] [JVM] Trace replay (alıntı ya da sentetik): ortalama ek gecikme (hazır → slot) bugünküne göre ≤ +2 ms.
- [ ] [device] Ori (ya da benzeri) Oyun 60, dokunma ile panel 120 Hz, 2–3 dk, `--ez pace_trace true --ez stats_1s true`: tutma = 2 vsync oranı ≥ %98, `skip_pct` ortanca ≤ %2, kullanıcı "takılma yok".
- [ ] [device] Akıcı (120 fps) çizim: `skip_pct` ve hazır→slot p50 öncekiyle aynı (± 1 ms).

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
