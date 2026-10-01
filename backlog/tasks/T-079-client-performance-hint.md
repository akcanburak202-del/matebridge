---
id: T-079
title: Tablet — PerformanceHintManager deneyi (ağ, çözücü giriş/çıkış iş parçacıkları için kare süresi hedefi)
status: in_progress
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

1. **`video/PerfHint.kt` (saf Kotlin, JVM testli):** koordinatör. Roller `NET` (video bağlantı okuyucu), `IN` (`mb-decoder`), `OUT` (`mb-decoder-out`); her iş parçacığı kendi `Process.myTid()` değerini `register(role, tid)` ile bildirir, çıkarken `unregister(role, tid)` (eski tid ise yok sayılır). API 31'de `setThreads` yok → küme değişince oturum kapatılıp yeniden kurulur; üç rol de kayıtlı ve hedef > 0 iken oturum var, biri eksilince kapanır (akış bitti = sızıntı yok). `setTargetNs` → oturum varsa `updateTargetWorkDuration`. Arka uç arayüzü (`Backend`/`Session`) enjekte edilir; Android arka ucu `video/AndroidPerfHint.kt` (`SDK_INT >= 31`, `getSystemService` null → desteklenmiyor; `createHintSession` null/istisna → `session=0`).
2. **Gerçek iş süresi = tek uçtan uca süre, kare başına bir rapor:** ağ okuması dönüşü (`recv`, iz ile aynı damga) → `queueInputBuffer` dönüşü (giriş iş parçacığı). Gerekçe: ADPF bir oturum için döngü başına tek süre bekler; üç iş parçacığından ayrı ayrı küçük süreler raporlamak örnek sayısını üçe katlar ve "bol pay var" sinyali verir (ters etki: saat düşer). Ölçülen yavaş adımların hepsi (şifre çözme, uyanma, `queueInputBuffer`) bu yolda; donanım çözme süresi (~8,7 ms, CPU işi değil) dışarıda. Çıkış iş parçacığı grupta (aynı uclamp desteği) ama süresi raporlanmaz. Eşleme: ağ iş parçacığı `onRecv(seq, ns)` → 64'lük ön ayrılmış halka; giriş iş parçacığı `onInput(seq, ns)` eşleşen kaydı tüketip raporlar (config kareleri hariç). Raporlanan süre = izdeki `input_ns − recv_ns`, yani iz ile doğrudan karşılaştırılabilir.
3. **Hedef:** panel periyodu (`1e9 / hz`, T-059 debouncer'ın bildirdiği hız; akış başında `vsync.periodNs`); `--ei perf_hint_target_us N` sabit hedef (deney için; verilirse panel değişimi yok sayılır).
4. **Bağlantı:** `MainActivity` `--ez perf_hint true` ile koordinatörü kurar (varsayılan kapalı), açılışta `MB/render ev=perf_hint enabled=0|1 supported=0|1 session=0 target_us=… rate_us=…`; oturum kurulunca/kapanınca `ev=perf_hint supported=1 session=1|0 target_us=… threads=n cause=… reports=…`. `SessionController` yapıcıya `perfHint` parametresi (video okuyucu kaydı + `onRecv`), `VideoRenderer.perfHint` (giriş/çıkış kaydı + `onInput`). İz sütunları değişmez.
5. Testler: rol kümesi/oturum yaşam döngüsü, hedef güncelleme, eski tid, arka uç yok/null/istisna, seq eşleme ve raporlama. `./scripts/check.sh`.

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
