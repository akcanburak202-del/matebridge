---
id: T-068
title: Tablet — sunum son anı (presentationDeadline) için deney düğmesi ve geç kare kenar payı ölçümü
status: review
phase: 5
owner: android-client-dev
depends_on: [T-065]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/StatsFormat.kt
  - client-android/app/src/test/
  - backlog/tasks/T-068-client-deadline-knob.md
---

## Amaç

HarmonyOS `Display.getPresentationDeadlineNanos()` = **13,33 ms** (60 ve 120 Hz). `VsyncClock.Grid.deadlineNs` bu değeri (en çok P) kullanıyor: `earliest = ilk vsync ≥ now + deadline`, kilit konumu (`ideal`), geç kare kararı (`slot < earliest` → `lateDrop`) ve `dispatchLeadNs`. T-061 taramasında gerçek bırakma öncüsünün ~6 ms'de en iyi sonucu verdiği görüldü; yani 13,3 ms son an büyük olasılıkla fazla temkinli ve 60 Hz'te gösterilebilecek kareler "geç" sayılıp atılıyor (cihaz: `late_drops` 2–35/sn, 33 ms boşluk %1–28, T-067 notu). Bu kart davranışı **değiştirmez**; ölçüm için düğme ve sayaç ekler.

## Kabul kriterleri

- [ ] `--ei deadline_us N` (0..P): `VsyncClock`'a geçersiz kılma (`deadlineOverrideNs`, `leadOverrideNs` gibi); verilmezse bugünkü davranış. `ev=display_timing` satırında `deadline_override_us`.
- [ ] `ev=present` satırına geç kararların kenar payı: geç sayılan karelerde `slot - (now)` dağılımı (ör. `late_margin_p50_us`, `late_margin_min_us`) — yani bu kare slotundan kaç µs önce hazırdı. Alan ekleme `StatsFormat` + testi.
- [ ] Testler (VsyncClock geçersiz kılma, StatsFormat alanı). `./scripts/check.sh` geçiyor.

## Plan

`VsyncClock.deadlineOverrideNs` (leadOverrideNs gibi), `setDisplayTiming` icinde uygulanir (Grid.deadlineNs tek kaynak). Gec kararda `Decision.ownSlotNs`; renderer `ownSlot - readyNs` kenar payini `PresentCounters`'a verir (pencere basina p50/min). `ev=present` sonuna alan eklenir.

## Handoff

- **Commit:** bkz. `git log task/T-068-client-deadline-knob`
- **Dokunulan dosyalar:** MainActivity.kt, video/FramePacer.kt, video/AdaptivePacer.kt, video/SlotReleaser.kt, video/VideoRenderer.kt, stream/StatsFormat.kt, PresentationSchedulingTest.kt
- **Varsayimlar:** Ekstra verilmezse davranis ayni. Gecersiz kilma 0..periyot araligina kisilir. Kenar payi `ownSlot - readyNs` (us), negatif olabilir; yalniz `lateDrop` kararlarinda olculur. Hem `vsync` hem `glVsync`'e uygulanir.
- **Test edilmeyenler / cihazda dogrulanacaklar:** `adb shell am start -n <paket>/.MainActivity --ei deadline_us 6000` (diger ekstralarla birlikte). `ev=display_timing` icinde `deadline_override_us=6000`; `ev=present` satirinda `late_margin_p50_us`/`late_margin_min_us` (gec karar yoksa `-`). 4000/6000/8000/13333 taramasi: late_drops ve 33 ms bosluk.
- **Acik sorular:** Ekstrasiz `deadline_override_us` tamsayi bolmesiyle `0` yazar (lead_override_us ile ayni kalip); gercek deadline `presentation_deadline_ns` alaninda.
