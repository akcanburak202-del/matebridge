---
id: T-069
title: Tablet — kare başına sunum izi (pace trace) dosyaya, deney anahtarıyla
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-068]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/
  - backlog/tasks/T-069-client-pace-trace.md
---

## Amaç

Sayaçlar (`late_drops`, `rephase`, `late_margin_*`) faz kilidinin cihazda nasıl bozulduğunu göstermeye yetmiyor. 2026-10-01 11:07–11:15 taraması (kullanıcı aktif, panel 120 Hz, akış 120): 20 sn pencerelerde `late_drops` ~1500–2200, `rephase` 36–70, geç karelerin `late_margin_p50` **+25…+60 ms** (kare kendi kilit slotundan çok önce hazır → kilit slotu gerçek varışın periyotlarca ilerisine kaymış, her ~30 karede `REPHASE_FRAMES` ile düzeliyor). Görüntüyü T-065 releaser'ı kurtarıyor. Kök nedeni bulmak için kare başına ham veri gerekli.

## Kabul kriterleri

- [ ] `--ez pace_trace true` ile (varsayılan kapalı) her çözülmüş kare için bir satır, bellekte sınırlı halka (ör. son 20 000 kare), uygulama durunca/`ev=stats` her 10 sn'de `cacheDir/pace_trace.csv`'ye yazılır (dosya boyutu sınırlı, üzerine yazılır). İçerik yok, yalnız zamanlar.
- [ ] Sütunlar (ns, `System.nanoTime` tabanı; capture µs): `seq, capture_us, ready_ns, now_vsync_last_ns, period_ns, epoch, deadline_ns, dev_ns, d_ns, jitter_ns, earliest_ns, slot_ns, lock_slot_ns, k, acquire_ns, bad_run, path(locked|acquire|sparse|unlocked), late_drop, collided, released_slot_ns, release_ns, render_ns, action(release|replace|move|discard)`. Gerekirse sütun adlarını uyarla ama karta yaz.
- [ ] İz yazımı sunum yolunu yavaşlatmaz (ön-ayrılmış dizi, tahsis yok; dosya yazımı ayrı iş parçacığında).
- [ ] Test: halka taşması ve CSV başlığı. `./scripts/check.sh` geçiyor.
- [ ] Handoff'ta çekme komutu: `adb exec-out run-as dev.matebridge.client cat cache/pace_trace.csv > …`.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
