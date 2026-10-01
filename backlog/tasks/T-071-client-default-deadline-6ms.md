---
id: T-071
title: Tablet — sunum son anı varsayılanı 6 ms (HarmonyOS'un 13,3 ms değeri yerine)
status: review
phase: 5
owner: android-client-dev
depends_on: [T-068]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-071-client-default-deadline-6ms.md
---

## Amaç

Cihaz A/B (2026-10-01 11:40, kullanıcı kalemle çizdi, panel 120 Hz, aynı oturum, SurfaceFlinger `--latency` ~55 sn her biri):

| | 8,3 ms aralık | 16,7 ms (tekrar) | planlanan hazır→slot p50 |
|---|---|---|---|
| A: bildirilen son an (`presentationDeadline` 13,33 ms → P'ye kırpılmış) | %91,8 | %6,3 | 14,9 ms |
| B: `--ei deadline_us 6000` | **%99,7** | **%0,2** | **12,6 ms** |

İz simülasyonu (NOTES ~11:30) de 6 ms ile ~7 ms gecikme kazancı öngörüyordu; T-061 öncü taraması gerçek mandal süresinin ~6 ms olduğunu göstermişti.

## Kabul kriterleri

- [ ] Varsayılan son an **6,0 ms** (en çok P − 1 ms), `VsyncClock.DEFAULT_DEADLINE_NS` gibi bir sabit; HarmonyOS değeri yalnızca loglanır. `--ei deadline_us N` geçersiz kılması aynen kalır (N = 0..P); `--ei deadline_us -1` = cihazın bildirdiği değeri kullan (karşılaştırma için).
- [ ] `ev=display_timing`: hem cihaz değeri hem etkin değer.
- [ ] Testler güncellenir; `./scripts/check.sh` geçiyor.

## Kapsam dışı

- 60 Hz SF doğrulaması orkestratörde (kullanıcı boştayken).

## Plan

`VsyncClock.deadlineOverrideNs` varsayılanı sentinel `DEADLINE_DEFAULT` (-2) olur; etkin son an = min(6 ms, P-1 ms). `DEADLINE_DISPLAY` (-1) cihaz değerini kullanır, N>=0 açık değer (P'ye kırpılır). MainActivity: `deadline_us` yoksa varsayılan, -1 cihaz değeri. Log ve testler güncellenir.

## Handoff

- **Commit:** SHA_PLACEHOLDER
- **Dokunulan dosyalar:** video/FramePacer.kt (VsyncClock), MainActivity.kt, PresentationSchedulingTest.kt, NewestFrameShownTest.kt, bu kart
- **Varsayımlar:** Varsayılan = min(6 ms, P-1 ms); `deadline_us` ekstrası yoksa varsayılan, `-1` cihaz değeri, N>=0 açık değer. `ev=display_timing` artık `presentation_deadline_ns` (cihaz), `effective_deadline_ns` ve `deadline_override` (-2 varsayılan, -1 cihaz, >=0 us*1000 ns) loglar; eski `deadline_override_us` alanı kaldırıldı.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Ekstrasız başlatmada log `effective_deadline_ns=6000000` (120 Hz) göstermeli; `--ei deadline_us -1` ile 13,33 ms (P'ye kırpılı) görülmeli; SF `--latency` 120 Hz'de ~%99,7 / 8,3 ms. 60 Hz doğrulaması kapsam dışı.
- **Açık sorular:** yok
