---
id: T-220
title: One presentation metric across pacers; infer 60 fps cadence in Oyun 120
status: in_progress
phase: 6
owner: android-client-dev
depends_on: [T-208, T-211]
decisions: [0014]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoStats.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/AdaptivePacer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameInterval.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt   # only if the interval provider needs measured arrivals
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - tools/pacing/sim.py
  - docs/LOGGING.md
  - backlog/tasks/T-220-client-presentation-metric-and-game120-cadence.md
---

## Amaç

gpt-6-astra değerlendirmesi: (1) `skip_pct` uyarlamalı zamanlayıcıda zamanlayıcı kararlarından, aksi hâlde `PresentMeter`'dan hesaplanıyor; T-208/T-211 A/B'sindeki "%10 → %0" birebir karşılaştırma değil. Ayrıca kadans 2'de kaçırılan slot dalı 3 vsync'lik aralık üretebilir ama karşılaştırma "1,5 × kadans'tan büyük" olduğu için atlama sayılmaz (`VideoStats.kt` ~:269, `AdaptivePacer.kt` ~:361). (2) `FrameInterval.resolve` içerik kadansını ölçülen varıştan genel olarak çıkarmıyor: Oyun 120'de (120 fps config) 120 Hz panelde 60 fps gelen oyun içeriği yine 1 periyot sayılır, 2:1 kilit kurulmaz.

## Bağlam

- Tek, zamanlayıcıdan bağımsız bir sunum ölçütü: bırakılan her karenin gerçek tutma süresi (vsync cinsinden), içerik kadansına göre doğru/kısa/uzun; iki zamanlayıcıda da aynı hesap. `skip_pct` bu ölçüte bağlanır; eski alan adı korunur ya da yeni ad + takma ad.
- İçerik kadansı: config fps'i yerine (ya da yanında) ölçülen yakalama aralığından tam sayı katı (1 veya 2) çıkarımı, histerezisle.
- `sim.py --holds` aynı ölçütü kullanır.

## Kabul kriterleri

- [ ] [JVM] Aynı sentetik akış iki zamanlayıcıda (tampon 0 ve uyarlamalı) aynı ölçütle raporlanır; 3 vsync tutma kadans 2'de "uzun" sayılır.
- [ ] [JVM] Oyun 120 config + 120 Hz panel + 60 fps içerik → 2:1 kilit kurulur; 120 fps içerik → 1:1, değişmez.
- [ ] [device] Ori Oyun 60 ve Oyun 120, dokunmayla 120 Hz: aynı ölçütle tampon 0 ve uyarlamalı karşılaştırması NOTES'a.

## Plan

1. **Tek sunum ölçütü (`HoldMeter`, `VideoStats.kt` içinde, saf Kotlin):**
   - Çözülen her karenin yakalama damgası (`onOutput`) bir "akış koşusu"na yazılır: ardışık yakalama aralıkları koşunun ilk aralığından ±1 ms içindeyse koşu sürer.
   - Ekrana bırakılan her kare (`onReleased`), bırakıldığı anda düşeceği vsync ile bildirilir. Bu vsync iki zamanlayıcıda aynı formülle hesaplanır: istenen slot (`renderNs + lead`), ama `release + deadline` sonrasındaki ilk vsync'ten önce olamaz. Tampon 0'da istenen slot yoktur, o yüzden en erken vsync kullanılır.
   - Aynı vsync'e düşen iki bırakmada yeni kare eskisinin yerine geçer; eski kare hiç gösterilmemiş sayılır.
   - Ardışık iki gösterilen kare (A, B) yalnızca şu koşullarda yargılanır: kaynak A'dan B'ye kesintisizse (B'nin koşusu A'yı kapsıyorsa), panel periyodu değişmediyse ve koşu aralığı `n·P ± 1 ms` ise (`n ∈ 1..3`).
   - Tutma `h = round((slotB − slotA)/P)`. `h < n` kısa, `h = n` doğru, `h > n` uzun sayılır. Arada düşen kare uzun tutma olarak görünür.
2. **`skip_pct`** = uzun tutmaların yargılanan aralıklara oranı (`Snapshot.skipPct`, iki zamanlayıcıda aynı). Yeni alanlar: `holdJudged/holdShort/holdLong`, ayrıca tanı amaçlı `schedSkipPct` (zamanlayıcının kendi kararı).
   - Sunum hiç bildirilmemişse (testler/eski çağıranlar) zamanlayıcı yüzdesine düşülür. Üretimde ilk bırakmadan sonra bu yol kapanır.
   - `cb_skip_pct` (geri çağrı tanısı) değişmez.
   - `render ev=present` satırına `hold_n= hold_short_pct= hold_long_pct=` eklenir (log penceresi).
   - `AdaptivePacer.onSkipWindow` aynı `skipPct`'yi alır.
3. **`AdaptivePacer` `skipped` (tanı):** "kadansın 1,5 katından büyük" yerine "kadanstan en az bir vsync uzun" (`> cadence + P/2`). `n = 1`'de sonuç aynı; `n = 2`'de 3 vsync artık atlama sayılır. Kararlar değişmez.
4. **İçerik kadansı çıkarımı (`ArrivalTracker`, `FrameInterval.resolve`):**
   - Tracker son 16 yakalama aralığından kararlı bir içerik aralığı çıkarır. Giriş: ortancanın ±1 ms'inde ≥ 12 aralık. Çıkış: < 8 aralık (histerezis). Panel periyodundan bağımsızdır.
   - `resolve(..., cadenceNs)`: panel > 90 Hz iken (P < 11,1 ms) kararlı aralık 2P'ye (±1 ms) eşitse ve akış aralığı daha kısaysa 2P döner. Böylece Oyun 120 + 120 Hz + 60 fps içerik 2:1 kilide gider.
   - 120 fps içerik ve 60 Hz panel yolları değişmez.
   - Renderer `intervalOf` ve geri çağrı kadansı `arrival.cadenceNs`'yi geçirir.
5. **`AdaptivePacer`:** aynı panel döneminde `n` değişirse (çıkarım 1↔2) kilit ve D yeniden kurulur (`recadence`), titreme geçmişi ve seviye korunur. Bu olmazsa 2→1 geçişinde D > P geç-düşürme koşusu yapar. Sabit `n`'de hiçbir şey değişmez.
6. **Renderer:** `CodecSink.render` bırakma anında grid'i ve slotu okuyup `stats.onReleased(..., slotNs, periodNs)` çağırır. `onFrame` değişmez. `logPresent` hold alanlarını ekler. Kilit altında yeni dış çağrı yoktur (T-161).
7. **`sim.py --holds`:** aynı algoritma (koşu sürekliliği, latch formülü, kısa/doğru/uzun, `skip_pct` = uzun%). Self-test JVM testindeki vektörle aynıdır.
8. **Testler (`video/`):**
   - `PresentationMetricTest`: aynı akış tampon 0 (anında bırakma) ve uyarlamalı zamanlayıcıyla aynı hesaptan raporlanır; kadans 2'de 3 vsync uzun sayılır; değiştirme, kaynak boşluğu ve periyot değişimi yargılanmaz.
   - `Game120CadenceTest`: Oyun 120 + 120 Hz + 60 fps → `phaseLock`, ≥ %99 tam 2 vsync; 120 fps → kararlar çıkarımsız sürümle kare kare aynı; 60↔120 içerik geçişinde geç-düşürme koşusu yok; tracker histerezisi.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
