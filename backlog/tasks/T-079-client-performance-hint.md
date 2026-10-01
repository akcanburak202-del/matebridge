---
id: T-079
title: Tablet — PerformanceHintManager deneyi (ağ, çözücü giriş/çıkış iş parçacıkları için kare süresi hedefi)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-077]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-079-client-performance-hint.md
---

## Amaç

NOTES 2026-10-01 ~14:30: CPU tarafı küçük adımlar uygulama içinde ölçüm döngüsüne göre ~10 kat yavaş (`Cipher.init` 0,34 ms vs 0,033 ms), `queueInputBuffer` p50 0,58 / p95 ~2 ms. İş parçacıkları büyük olasılıkla küçük/düşük frekanslı çekirdekte. API 31 `PerformanceHintManager` (HarmonyOS 4.3 = API 31) ile ağ okuma, çözücü giriş ve çıkış iş parçacıkları için bir ipucu oturumu: hedef = panel periyodu (ya da akış aralığı), kare başına `reportActualWorkDuration`. Cihazda desteklenmeyebilir (`getSystemService` null / `createHintSession` null) — o zaman temiz şekilde atlanır.

## Kabul kriterleri

- [ ] `--ez perf_hint true|false` (varsayılan **kapalı**, ölçümden sonra karar), açılışta `ev=perf_hint supported=0|1 session=0|1 target_us=…` logu.
- [ ] İş parçacığı kimlikleri (`Process.myTid()`) ilgili iş parçacıklarından toplanır; oturum akış başında kurulur, panel hızı değişince `updateTargetWorkDuration`, akış bitince kapanır (sızıntı yok). Gerçek iş süresi: ağ iş parçacığında kayıt alma+çözme+kuyruğa koyma, giriş iş parçacığında kuyruk→`queueInputBuffer`, çıkış iş parçacığında çıktı alma→bırakma; ya da tek bir uçtan uca süre — gerekçelendir.
- [ ] İz sütunları değişmez; karşılaştırma iz ile yapılır.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
