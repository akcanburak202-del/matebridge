---
id: T-220
title: One presentation metric across pacers; infer 60 fps cadence in Oyun 120
status: done
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
  - tools/pacing/README.md   # review 2026-10-04: approved by the orchestrator
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/PaceTrace.kt   # review: latch columns (orchestrator's request)
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

- [x] [JVM] Aynı sentetik akış iki zamanlayıcıda (tampon 0 ve uyarlamalı) aynı ölçütle raporlanır; 3 vsync tutma kadans 2'de "uzun" sayılır.
- [x] [JVM] Oyun 120 config + 120 Hz panel + 60 fps içerik → 2:1 kilit kurulur; 120 fps içerik → 1:1, değişmez.
- [ ] [device] Ori Oyun 60 ve Oyun 120, dokunmayla 120 Hz: aynı ölçütle tampon 0 ve uyarlamalı karşılaştırması NOTES'a.

## Plan

1. **Tek sunum ölçütü (`HoldMeter`, `VideoStats.kt` içinde, saf Kotlin):**
   - Çözülen her karenin yakalama damgası (`onOutput`) bir "akış koşusu"na yazılır: ardışık yakalama aralıkları koşunun ilk aralığından ±1 ms içindeyse koşu sürer.
   - Ekrana bırakılan her kare (`onReleased`), bırakıldığı anda düşeceği vsync ile bildirilir. Bu vsync iki zamanlayıcıda aynı formülle hesaplanır: istenen slot (`renderNs + lead`), ama `release + deadline` sonrasındaki ilk vsync'ten önce olamaz. Tampon 0'da istenen slot yoktur, o yüzden en erken vsync kullanılır.
   - Aynı vsync'e düşen iki bırakmada yeni kare eskisinin yerine geçer; eski kare hiç gösterilmemiş sayılır.
   - Ardışık iki gösterilen kare (A, B) yalnızca şu koşullarda yargılanır: kaynak A'dan B'ye kesintisizse (B'nin koşusu A'yı kapsıyorsa), panel periyodu değişmediyse ve koşu aralığı `n·P ± 1 ms` ise (`n ∈ 1..3`).
   - Tutma `h = round((slotB − slotA)/P)`. `h < n` kısa, `h = n` doğru, `h > n` uzun sayılır. Arada düşen kare, ardılı kendi slotunda kaldıysa uzun tutma olarak görünür; aynı slotta yerini aldıysa tutma doğrudur ve kare `discarded` olarak sayılır.
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
5. **`AdaptivePacer`:** aynı panel döneminde `n` değişirse (çıkarım 1↔2) kilit ve D yeniden kurulur (`recadence`), titreme geçmişi ve seviye korunur. Sabit `n`'de hiçbir şey değişmez. (Uygulamada: sentetik testlerde `recadence` açık/kapalı arasında ölçülebilir fark çıkmadı; kafes n'ye bağlı sınırlarla tutarlı kalsın diye tutuldu, bkz. Handoff.)
6. **Renderer:** `CodecSink.render` bırakma anında grid'i ve slotu okuyup `stats.onReleased(..., slotNs, periodNs)` çağırır. `onFrame` değişmez. `logPresent` hold alanlarını ekler. Kilit altında yeni dış çağrı yoktur (T-161).
7. **`sim.py --holds`:** aynı algoritma (koşu sürekliliği, latch formülü, kısa/doğru/uzun, `skip_pct` = uzun%). Self-test JVM testindeki vektörle aynıdır.
8. **Testler (`video/`):**
   - `PresentationMetricTest`: aynı akış tampon 0 (anında bırakma) ve uyarlamalı zamanlayıcıyla aynı hesaptan raporlanır; kadans 2'de 3 vsync uzun sayılır; değiştirme, kaynak boşluğu ve periyot değişimi yargılanmaz.
   - `Game120CadenceTest`: Oyun 120 + 120 Hz + 60 fps → `phaseLock`, ≥ %99 tam 2 vsync; 120 fps → kararlar çıkarımsız sürümle kare kare aynı; 60↔120 içerik geçişinde geç-düşürme koşusu yok; tracker histerezisi.

## Handoff

- **Commit:** `b407dd3` (kod, testler, araç, belge); plan `7d992d9`; Codex inceleme düzeltmeleri `3a1f175`; Handoff ayrı commit'ler. Dal `task/T-220-client-presentation-metric-and-game120-cadence`. `./scripts/check.sh` → ALL OK.
- **Dokunulan dosyalar:**
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoStats.kt`:
    - yeni `HoldMeter` sınıfı;
    - `onReleased(..., slotNs, periodNs)`;
    - `Snapshot.holdJudged/holdShort/holdLong/schedSkipPct`;
    - `skipPct` = uzun tutma %;
    - `holdWindow()` / `HoldCounts.logFields()`.
  - `.../video/FrameInterval.kt`: `ArrivalTracker.cadenceNs` (histerezisli kararlı aralık) ve `resolve(..., cadenceNs)`.
  - `.../video/AdaptivePacer.kt`:
    - `recadence()`;
    - iki yerde `skipped` artık `> cadence + P/2`.
  - `.../video/VideoRenderer.kt`:
    - `intervalOf` ve geri çağrı kadansı `arrival.cadenceNs` geçirir;
    - `CodecSink.render` bırakma anındaki grid'den `HoldMeter.latchSlot` hesaplar ve `onReleased`'e verir;
    - `logPresent` hold alanlarını ekler.
  - Testler (`.../src/test/.../video/`): `PresentRig.kt` (yeni, codec'siz çıkış yolu düzeneği), `PresentationMetricTest.kt` (yeni), `Game120CadenceTest.kt` (yeni).
  - `tools/pacing/sim.py` (`--holds` aynı kurallar, self-test JVM `simSelfTestVector` ile aynı vektör).
  - `docs/LOGGING.md`.
- **Ne değişti:**
  - **Sunum ölçütü:**
    - Her bırakılan karenin "düşeceği vsync"i bırakma anında hesaplanır: istenen slot, ya da son tarih kaçtıysa / tampon 0'da bırakmadan sonraki ilk uygun vsync. Bu iki zamanlayıcıda aynı koddur (`CodecSink.render`).
    - Tutma, bir sonraki gösterilen karenin vsync'ine uzaklıktır ve yakalama aralığından gelen içerik kadansı n ile karşılaştırılır. Yalnız kaynak sürekliyse yargılanır.
    - `skip_pct` = uzun% (`decoder ev=stats`, katman, `onSkipWindow` geri beslemesi). `render ev=present` satırına `hold_n= hold_short_pct= hold_long_pct=` eklendi.
    - Eski tanım yalnızca hiç slot bildirmeyen çağıranlarda kalır (`presentationReported` bayrağı). Üretimde ilk bırakmadan sonra kapanır.
  - **Kadans çıkarımı:**
    - `ArrivalTracker` son 16 aralıkta ortancanın ±1 ms'inde ≥ 12 aralık bulursa kararlı aralığı yayımlar; < 8'e düşünce bırakır.
    - `resolve` yalnız P < 11,1 ms (> 90 Hz) iken ve aralık 2P ± 1 ms ise 2P döndürür. Böylece Oyun 120 + 120 Hz + 60 fps içerik 2:1 kilide gider.
- **JVM sonuçları** (`./gradlew testDebugUnitTest --tests '*PresentationMetricTest*' --tests '*Game120CadenceTest*' -i`):
  - **Aynı akış iki zamanlayıcıda** (60 fps, iki kovalı ±4 ms, 120 Hz, 3600 kare): ölçüt, bırakılan slotlardan bağımsız hesaplanan referansla birebir aynı.
    - Tampon 0: yargılanan 3598, kısa 903, uzun 904 (`skip_pct` %25,1). Cihaz belirtisi.
    - Uyarlamalı: kısa 0, uzun 1 (%0,03).
  - **Kilitli kare slotunu kaçırınca (n = 2):** önceki kare 3 vsync tutulur → uzun 1, kısa 1. Ayrıca `Decision.skipped = true`; önceden false'tu.
  - **Oyun 120 + 120 Hz + 60 fps** (iki kovalı titreme, her 97 karede bir eksik yakalama, 9 faz):
    - Yeni: `phaseLock`, tutma = içerik süresi %99,97–100, `skip_pct` ≤ %0,06.
    - T-220 öncesi: %98,5–98,9. Her eksik yakalamadan sonra kare `early_sparse` oluyor: 33 ms > 3P yalnız kare sayılıyor (1:1'de).
    - Not: Eksik yakalama yokken eski n = 1 kafesi de (k = 2 adımlı) sentetik akışta %100 veriyor. Asıl fark, n'ye bağlı sınırlarda (yalnız kare boşluğu 6P, D tavanı 1,5P, kaçırılan slot kuralı).
  - **120 fps içerik (Oyun 120/120 Hz)** ve **60 Hz panel** (60 fps ve 30 fps içerik): kararlar çıkarımsız sürümle kare kare aynı.
  - **İçerik 60 → 120 → 60 fps, aynı ızgara** (9 faz, eski ile karşılaştırma):
    - Geç düşürme yeni ≤ eski. Örnek: faz 1 ms'de 5'e karşı 14, faz 2 ms'de 4'e karşı 13.
    - Geçiş başına düzensiz aralık ≤ eski + 2.
    - Akış başında ve n 1→2 geçişinde, D büyürken kurulan kilit `REPHASE_FRAMES` sonra bir kez yeniden fazlanır (bir düzensiz tutma). Bu, Oyun 60 akış başındaki T-208 davranışıyla aynı.
  - **Oyun 120, panel 120 → 60 → 120:** her iki ızgarada aralık 16,7 ms olduğu için T-208 aynı-akış yolu çalışır. Geçiş başına ≤ 1 düzensiz aralık.
  - **Mevcut testler değişmeden yeşil:** T-060, T-065, T-115, T-208, `StatsLogWindowTest`, `PresentMeterTest`.
- **Varsayımlar:**
  - "Gerçek tutma" = karenin bırakıldığı vsync. SurfaceFlinger'ın latch'i süreç içinden görülmez.
    - Tampon 0'da aynı vsync'e düşen iki bırakmada yenisinin eskisinin yerine geçtiği varsayılır (SlotReleaser ile aynı model).
    - SF iki kareyi ardışık vsync'lerde gösteriyorsa tampon 0'ın kısa/uzun oranı olduğundan yüksek çıkar. Çapraz kontrol: `cb_skip_pct` ve `dumpsys SurfaceFlinger --latency`.
  - `onSkipWindow` geri beslemesi artık bu ölçütü alıyor. Boşta (sürekli içerik yok) pencereler `null` döner ve yok sayılır; eskiden zamanlayıcı %0 verirdi ve seviyeyi düşürürdü. Seviye yalnız etkin pencerelerde düşer.
  - Çıkarım 60 Hz'de kapalı: 30 fps / 60 Hz T-208'deki gibi kalır.
  - 144 Hz'de 60 fps tam sayı kadans değil, yargılanmaz ve kilitlenmez.
  - `VideoRenderer.kt` yalnız kadans için değil, ölçütün bırakma kancası için de değişti. Tampon 0'da slotu yalnız renderer biliyor; dosya kart listesinde.
- **Test edilmeyenler / cihazda doğrulanacaklar (orkestratör, sırayla):**
  1. Ori, **Oyun 60**, USB, dokunmayla panel 120 Hz, 2–3 dk, `--ez stats_1s true --ez pace_trace true`. A/B: normal açılış (uyarlamalı) ve `--ez dev true --ei jitter 0` (tampon 0).
     - İki durumda da `decoder ev=stats skip_pct` ve `render ev=present hold_n= hold_short_pct= hold_long_pct=` toplanır.
     - Beklenen: tampon 0'da kısa ve uzun belirgin (≈ %10+), uyarlamalıda ≤ %2.
     - Uyarlamalı izde `python3 tools/pacing/sim.py trace.csv --holds` son satırı (`skip_pct ... of N judged`) log'daki `hold_long_pct` ile aynı mertebede olmalı.
     - Sonuç NOTES'a.
  2. Aynı oyun **Oyun 120**'de (120 fps akış, oyun 60 fps):
     - Logda `phase_lock=1`, pace trace'te `path=locked` ve `k=2`, `--holds`'ta `120 Hz, cadence 2: exact ≥ %98`, `skip_pct` ortanca ≤ %2.
     - Aynı A/B tampon 0 ile NOTES'a.
  3. **Akıcı (120 fps) kalemle çizim** regresyonu: `hold_short_pct`/`hold_long_pct` ≈ 0. `--holds`'ta `120 Hz, cadence 1` exact değişmemeli, hazır→slot p50 öncekiyle aynı (±1 ms).
  4. Oyun 120'de oyun menüsü (60 fps) ↔ oynanış geçişi ya da kare hızı değişimi: geçişte en çok bir kısa takılma, ardından `phase_lock=1`.
  5. `cb_skip_pct` ile `skip_pct`'yi karşılaştır. Tampon 0'da ikisi yakın çıkmalı; çok farklıysa latch modeli SF ile uyuşmuyor demektir (açık soru 1).
- **Codex (--high) incelemesi düzeltmeleri (`3a1f175`):**
  - P2, bırakma gecikmesi:
    - Saat ve ızgara artık `releaseOutputBuffer` döndükten sonra okunuyor (`HoldMeter.releasedSlot`, renderer'da `releaseClock` seam). Çağrı içinde son tarihi geçen kare bir sonraki vsync'e yazılır; bu her zamanlayıcıda aynıdır.
    - Slot ve periyot tek ızgara anlık görüntüsünden gelir.
    - Test: `releaseThatStallsPastTheDeadlineCountsForTheNextVsync`. Sahte saat çağrı içinde 2 ms ilerliyor: sonuç slot + P. Tampon 0 da aynı. Çağrı içinde panel 60 Hz'e geçince periyot yeni ızgaradan geliyor.
  - P2, iz farklı ızgara:
    - Pace trace'e son iki sütun eklendi: `latch_slot_ns` ve `latch_period_ns`. Bunlar istemcinin hesapladığı değerlerdir; bypass (`now`) karelerde de yazılır. `PaceTrace.onLatch`, `CodecSink` iz satır kimliğini taşıyor.
    - `sim.py --holds` bu sütunlar varsa yalnız onları kullanır. Eski izlerde eski yeniden kurma sürer.
    - Self-test'e ikinci vektör eklendi: 120 → 60 Hz geçişi. 40–41. satırların zamanlama değerleri eski ızgaradan; sonuç `120 Hz/2: 39`, `60 Hz/1: 38`.
    - `PaceTraceTest`'te üç düzen beklentisi yeni son sütunlara uyarlandı. Yeni test: `traceRecordsTheReleaseTimeVsyncAndPeriod`.
  - P3: `presented()` artık yargılanan aralığın kendi Hz'ini döndürüyor, gruplama ona göre. Bunu yukarıdaki self-test yakalar: 38→39 aralığı 120 Hz'te kalır.
  - `tools/pacing/README.md` T-220 `--holds` kurallarıyla güncellendi; dosya `files:`'a eklendi.
  - `./scripts/check.sh` ALL OK, `python3 tools/pacing/sim.py --holds-selftest` OK.
- **Açık sorular:**
  1. Tampon 0'da SF'nin aynı vsync'e düşen iki tampondan eskisini düşürüp düşürmediği cihazda doğrulanmadı. Uyuşmazsa ölçüt yalnız iz/geri çağrıyla çapraz kontrol edilebilir.
  2. ~~`tools/pacing/README.md` güncellemesi~~ (incelemede yapıldı).
  3. `StatsLogWindowTest` (`stream/`, kart dışı) eski tanımla (`onScheduled`) `skipPct` bekliyor. Bunun için yalnız slot bildirmeyen çağıranlara eski tanım bırakıldı. O test güncellenirse geri dönüş yolu (`presentationReported`) kaldırılabilir.
  4. Ölçülen ama değiştirilmeyen bir T-208 davranışı var: kurulu kilit altında titreme artınca (120 fps ±2 ms → 60 fps iki kovalı), `REPHASE_FRAMES` (≈ 0,5 s) boyunca 1/3 tutmalar oluyor. Bu T-220 öncesinde de aynı. Bir kadans değişiminden sonra T-115 ısınma kuralını açmak bunu kısaltabilir; ayrı kart.
  5. Tampon 0 trace'i sunum satırı yazmıyor; `sim.py --holds` yalnız zamanlanmış izlerde çalışır. Tampon 0 A/B'si log alanlarıyla (`hold_*`, `skip_pct`) yapılır.
  6. `PaceTrace.kt` başta kartta yoktu. Orkestratörün istediği iz sütunu için eklendi (`files:` notlu).
