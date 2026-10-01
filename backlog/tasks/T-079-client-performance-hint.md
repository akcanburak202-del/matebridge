---
id: T-079
title: Tablet — PerformanceHintManager deneyi (ağ, çözücü giriş/çıkış iş parçacıkları için kare süresi hedefi)
status: done
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

- [x] `--ez perf_hint true|false` (varsayılan **kapalı**, ölçümden sonra karar), açılışta `ev=perf_hint supported=0|1 session=0|1 target_us=…` logu.
- [x] İş parçacığı kimlikleri (`Process.myTid()`) ilgili iş parçacıklarından toplanır; oturum akış başında kurulur, panel hızı değişince `updateTargetWorkDuration`, akış bitince kapanır (sızıntı yok). Gerçek iş süresi: ağ iş parçacığında kayıt alma+çözme+kuyruğa koyma, giriş iş parçacığında kuyruk→`queueInputBuffer`, çıkış iş parçacığında çıktı alma→bırakma; ya da tek bir uçtan uca süre — gerekçelendir.
- [x] İz sütunları değişmez; karşılaştırma iz ile yapılır.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **`video/PerfHint.kt` (saf Kotlin, JVM testli):** koordinatör. Roller `NET` (video bağlantı okuyucu), `IN` (`mb-decoder`), `OUT` (`mb-decoder-out`); her iş parçacığı kendi `Process.myTid()` değerini `register(role, tid)` ile bildirir, çıkarken `unregister(role, tid)` (eski tid ise yok sayılır). API 31'de `setThreads` yok → küme değişince oturum kapatılıp yeniden kurulur; üç rol de kayıtlı ve hedef > 0 iken oturum var, biri eksilince kapanır (akış bitti = sızıntı yok). `setTargetNs` → oturum varsa `updateTargetWorkDuration`. Arka uç arayüzü (`Backend`/`Session`) enjekte edilir; Android arka ucu `video/AndroidPerfHint.kt` (`SDK_INT >= 31`, `getSystemService` null → desteklenmiyor; `createHintSession` null/istisna → `session=0`).
2. **Gerçek iş süresi = tek uçtan uca süre, kare başına bir rapor:** ağ okuması dönüşü (`recv`, iz ile aynı damga) → `queueInputBuffer` dönüşü (giriş iş parçacığı). Gerekçe: ADPF bir oturum için döngü başına tek süre bekler; üç iş parçacığından ayrı ayrı küçük süreler raporlamak örnek sayısını üçe katlar ve "bol pay var" sinyali verir (ters etki: saat düşer). Ölçülen yavaş adımların hepsi (şifre çözme, uyanma, `queueInputBuffer`) bu yolda; donanım çözme süresi (~8,7 ms, CPU işi değil) dışarıda. Çıkış iş parçacığı grupta (aynı uclamp desteği) ama süresi raporlanmaz. Eşleme: ağ iş parçacığı `onRecv(seq, ns)` → 64'lük ön ayrılmış halka; giriş iş parçacığı `onInput(seq, ns)` eşleşen kaydı tüketip raporlar (config kareleri hariç). Raporlanan süre = izdeki `input_ns − recv_ns`, yani iz ile doğrudan karşılaştırılabilir.
3. **Hedef:** panel periyodu (`1e9 / hz`, T-059 debouncer'ın bildirdiği hız; akış başında `vsync.periodNs`); `--ei perf_hint_target_us N` sabit hedef (deney için; verilirse panel değişimi yok sayılır).
4. **Bağlantı:** `MainActivity` `--ez perf_hint true` ile koordinatörü kurar (varsayılan kapalı), açılışta `MB/render ev=perf_hint enabled=0|1 supported=0|1 session=0 target_us=… rate_us=…`; oturum kurulunca/kapanınca `ev=perf_hint supported=1 session=1|0 target_us=… threads=n cause=… reports=…`. `SessionController` yapıcıya `perfHint` parametresi (video okuyucu kaydı + `onRecv`), `VideoRenderer.perfHint` (giriş/çıkış kaydı + `onInput`). İz sütunları değişmez.
5. Testler: rol kümesi/oturum yaşam döngüsü, hedef güncelleme, eski tid, arka uç yok/null/istisna, seq eşleme ve raporlama. `./scripts/check.sh`.

## Handoff

- **Commit:** `5e01bcb` (uygulama); plan `5817535`; dal `task/T-079-client-perf-hint`.
- **Dokunulan dosyalar:** `video/PerfHint.kt` (yeni, saf Kotlin koordinatör), `video/AndroidPerfHint.kt` (yeni, `PerformanceHintManager` arka ucu), `video/VideoRenderer.kt` (giriş/çıkış iş parçacığı kaydı + kare başına `onInput`), `session/SessionController.kt` (yapıcıda `perfHint` parametresi; video okuyucu kaydı + `onRecv`), `MainActivity.kt` (bayrak, açılış logu, hedef besleme, `onDestroy`'da kapatma), `test/.../video/PerfHintTest.kt` (yeni, 15 test), bu kart.
- **Kullanım:**
  - Kapalı (varsayılan, karşılaştırma tabanı): `adb shell am start -n dev.matebridge.client/.MainActivity --ez pace_trace true`
  - Açık: `adb shell am start -n dev.matebridge.client/.MainActivity --ez pace_trace true --ez perf_hint true`
  - Açık + sabit hedef (ör. 2 ms; panel değişimi yok sayılır): `... --ez perf_hint true --ei perf_hint_target_us 2000`
- **Loglar (`adb logcat -s 'MB/render:*'`):**
  - Açılışta her zaman: `ev=perf_hint enabled=0|1 supported=0|1 session=0 target_us=… rate_us=… fixed_target=0|1` (`supported` bayrak kapalıyken de ölçülür; `rate_us` = `getPreferredUpdateRateNanos`).
  - Oturum kurulunca: `ev=perf_hint supported=1 session=1 target_us=… threads=3 cause=threads|target`; kurulamazsa `session=0` (+ istisna olduysa `ev=perf_hint_error op=create err=…`).
  - Kapanınca: `ev=perf_hint supported=1 session=0 target_us=… threads=n cause=thread_gone|threads|close reports=N`.
  - Panel hızı değişince: `ev=perf_hint_target target_us=…`.
- **Gerçek iş süresi kararı:** tek uçtan uca süre, kare başına bir rapor = ağ okuması dönüşü (`recv`, izdeki damga) → `queueInputBuffer` dönüşü; raporlanan değer izdeki `input_ns − recv_ns` ile aynı. Gerekçe planda (madde 2): ADPF döngü başına tek süre modeli; iş parçacığı başına küçük parçalar örnekleri üçe katlar ve hedefin çok altında görünür (saat düşürme sinyali); donanım çözme CPU işi değil. Çıkış iş parçacığı oturumda ama süresi raporlanmıyor. Config kareleri raporlanmaz.
- **Varsayımlar:**
  - API 31'de `setThreads` yok: iş parçacığı kümesi değişince (video yeniden bağlanma, codec yeniden başlatma) oturum kapatılıp yeniden kurulur; üç rolden biri eksikse oturum yok. Eski iş parçacığının geç `unregister`'ı yok sayılır (tid eşleşmesi).
  - Hedef = panel periyodu: akış başında `vsync.periodNs` (yoksa akış fps aralığı), sonra T-059 debouncer'ın bildirdiği hz (`1e9/hz`). 144 Hz'de ~6944 us, 60 Hz'de ~16666 us.
  - Rapor giriş iş parçacığında `queueInputBuffer`'dan sonra yapılır (o karenin yolunu geciktirmez); kilit altında, istisnalar loglanır, ≤0 veya >1 s değerler atılır.
  - İz sütunları ve `--ez pace_trace` davranışı değişmedi; `recvNs` artık iz kapalı ama `perf_hint` açıkken de alınır.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  1. Açılış logu: HarmonyOS 4.3'te `supported=1` mi (servis var mı), `rate_us` değeri.
  2. Akış başlayınca `ev=perf_hint ... session=1 threads=3`; `session=0` ise `createHintSession` reddediyor (deney burada biter; kartın beklediği "temiz atlama").
  3. Karşılaştırma (aynı koşul: 60 fps, USB, ~90 sn, `pace_trace true`), `perf_hint` kapalı vs açık: `decrypted_ns − recv_ns`, `input_ns − queued_ns` (T-077 ayrıştırması: `taken−queued`, `input−copied`), `open_init_ns − open_start_ns` p50/p95. Etki görülmezse `--ei perf_hint_target_us 2000` (ya da 1000) ile tekrar: panel periyodu hedefi, ~1–3 ms'lik gerçek süreye göre çok geniş olabilir (ADPF "pay var" görüp desteği düşük tutar).
  4. Panel hızı değişimi (ör. 144→60 Hz) `ev=perf_hint_target` üretir; yüzey arka plana/ön plana gidince `session=0 cause=thread_gone` ardından yeniden `session=1` (sızıntı yok); uygulama kapatılınca `cause=close` ya da `thread_gone`.
  5. Akış normal: görüntü donmuyor, kalem/klavye çalışıyor; güç/ısı gözle (oturum açık uzun koşu).
- **Açık sorular:** Panel periyodu hedefi pratikte destek vermeyebilir (gerçek iş hedefin çok altında); ölçüm sonucuna göre varsayılan hedef ya da kapatma kararı orkestratörde. Çıkış iş parçacığı süresinin de rapora katılması gerekirse (pts eşlemesiyle) ayrı adım.
