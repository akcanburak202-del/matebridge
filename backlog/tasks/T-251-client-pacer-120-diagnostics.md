---
id: T-251
title: Client — 120 Hz pacer diagnostics: log feedback level, dev knobs for D cap and feedback
status: ready
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0014, 0021]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-251-client-pacer-120-diagnostics.md
---

## Amaç

NOTES 2026-10-05 ~17:20: gerçek 120-on-120 (panel 120 Hz, akış 120 fps, n=1) atlama ölçümü hiç yapılmadı. Çözme gecikmesi ~13 ms, p99 ~18–20 ms (T-249). Cihaz oturumunda yeniden APK kurmadan hipotezleri A/B edebilmek için tanı alanları ve geliştirici düğmeleri gerekiyor. Varsayılan davranış DEĞİŞMEZ.

## Bağlam

- `video/AdaptivePacer.kt`: D tavanları (~205–207: n=1 → 1 periyot, n=2 → 1,5 periyot; `MAX_D_HALF_PERIODS`), gecikme sınırları (~233, ~275), `onSkipWindow` histerezisi (~424–433: %1–3 arasında seviye ne iner ne çıkar), `recadence()` (~450). `FramePacer.kt`: lead 6 ms, deadline 6 ms (mevcut `--ei deadline_us`, `--ei lead_us` düğmeleri `--ez dev true` ile).
- İstenen:
  1. `ev=present` (ya da pacer'ın mevcut log satırı) içine geri besleme `level` ve D'nin bileşenleri (jitter p99, slack, cap) eklensin; `pace_trace` CSV'sine de `level`.
  2. Geliştirici düğmeleri (DevKnobs, `--ez dev true` gerektirsin; yoksa yok sayılır, mevcut desen): `--ei pace_dcap_half N` (n=1 ve n=2 tavanlarını N yarım periyot yapar; gecikme sınırları da tutarlı ölçeklensin), `--ez pace_feedback false` (geri besleme seviyesini 0'da sabitler).
  3. `ev=stats` satırında hangi pacer düğmelerinin etkin olduğu bir kez loglansın (oturum başında).
- Gizlilik/log kuralları: `docs/LOGGING.md`.

## Kabul kriterleri

- [ ] Düğmeler yokken davranış ve testler aynı (varsayılan değişmez).
- [ ] Yeni alanlar logda; birim testleri düğme ayrıştırma + tavan ölçekleme için.
- [ ] `./scripts/check.sh` geçer.
- [ ] Handoff: cihaz oturumu için hazır komut satırları (Günlük 120 ve Oyun 120; varsayılan / `deadline_us 4000` / `pace_dcap_half 3` / `pace_feedback false`) ve hangi alanın neyi doğruladığı.

## Plan

## Handoff

## Open questions
