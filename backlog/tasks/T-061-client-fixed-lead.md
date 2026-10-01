---
id: T-061
title: Tablet — varsayılan bırakma öncüsü tüm panel hızlarında mutlak 6,0 ms (P − 1 ms ile sınırlı)
status: done
phase: 5
owner: android-client-dev
depends_on: [T-057, T-060]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/FramePacer.kt
  - client-android/app/src/test/
  - backlog/tasks/T-061-client-fixed-lead.md
---

## Amaç

Cihaz taraması (60 Hz boşta, akış 60'a seyreltilmiş, `phase_lock=1`, `slot_dups`/`late_drops` ≈ 0), SurfaceFlinger'da 33 ms boşluk oranı:

| Öncü | 33 ms boşluk |
|---|---|
| P/2 = 8,33 ms | %12,7–18 |
| 3 ms | %11,7 |
| **6 ms** | **%2,4 / 3,2 / 4,6** |
| 12 ms | %4,4 |
| 14,5 ms | %3,7 |

120 Hz'te 6 ms öncü: %0,2–1,1 tekrar. En iyi öncü her iki hızda mutlak ~6 ms → panel periyodunun kesri değil, sabit bir mandallama süresi.

## Kabul kriterleri

- [x] Varsayılan öncü `VsyncClock.DEFAULT_LEAD_NS = 6,0 ms`, en çok `P − 1 ms`; tüm panel hızlarında (`FAST_PANEL_LEAD_FRACTION` kalktı).
- [x] `--ei lead_us` geçersiz kılma aynen kalır (en çok P).
- [x] Testler güncellendi; `./scripts/check.sh` geçiyor.

## Plan

`VsyncClock.leadNs()`: override yoksa `min(6 ms, P − 1 ms)`.

## Handoff

- **Commit:** bu commit (SHA orkestratöre raporlandı)
- **Dokunulan dosyalar:** `video/FramePacer.kt`, `PresentationSchedulingTest.kt`, bu kart.
- **Cihazda doğrulanacak:** 60 Hz boşta ve 120 Hz'te 33 ms / 16,7 ms oranları yukarıdaki 6 ms sonuçlarıyla uyumlu olmalı; `lead_ms=6.00` `ev=present` satırında.
- **Açık sorular:** yok.

## Orkestratör notu (merge, 2026-10-01)

- Cihazda: `lead_ms=6.00`, 60 Hz %3–4,3 boşluk, 120 Hz %2,3 tekrar (NOTES).
