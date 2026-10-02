---
id: T-125
title: Tablet — alt taşmadan sonra geç gelen toplu ses paketleri seviyeyi şişirmesin (çalarken ileri atla, yumuşak geçişle)
status: done
phase: 5
owner: android-client-dev
depends_on: [T-118, T-123]
decisions: [0011]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/test/
  - backlog/tasks/T-125-client-audio-late-bunch-skip.md
---

## Amaç

Cihaz (Wi-Fi, 2026-10-02 ~12:40, NOTES'a eklenecek):
- t=258'de tek bir ~80 ms gecikmeyle (`owd_max` 94) alt taşma olur.
- Çalma, birkaç paketle yeniden başlar (T-118 kırpması başlangıçta yapılır, `refill_trims` +1). Ama geciken paketler çalma **başladıktan sonra** toplu gelir.
- Seviye hedefin (45 ms) çok üstüne çıkar: `level_ms` 85 → ikinci alt taşmadan sonra (t=269) 134, `refill_trims` artmadı.
- `audio_ms` 187'ye, `av_offset_ms` 149'a çıkar. PI denetleyici (en çok 5000 ppm ≈ 5 ms/s) bunu ~20 s'de geri alır.
- Kullanıcı bunu kesintinin ardından sesin uzun süre görüntünün gerisinde kalması olarak yaşar.

Alt taşmada zaten bir boşluk duyuldu. Ardından gelen fazlayı çalmak yerine atlamak daha iyi.

## Kapsam dışı

- Güvenlik payı politikası (T-118/T-123 değerleri).
- Ağ tarafı (T-124).

## Kabul kriterleri

- [x] Çalma sürerken seviye, alt taşmadan sonraki kısa pencerede (örneğin ilk 2 s; Plan'da gerekçe) `target + eşik` üstüne çıkarsa en eski fazlalık atılır. Örnek eşik: 20 ms.
  - Atlama tıklama yapmamalı: kısa çapraz geçiş ya da sön/yüksel (≤ 5 ms).
  - Bir alt taşma penceresinde en çok bir atlama.
  - Sayaç: `skip_trims=`, `skip_trim_ms=` (stats satırı).
- [x] Alt taşma penceresi dışında, seviye çok yüksekse (örneğin > `target + 60 ms`, 3 s boyunca) yine tek seferlik atlama yapılır. Normal sapma PI ile düzeltilmeye devam eder. Bu, sessizlikten sonra başlayan seslerin başını kesmemelidir (T-118 `idleRestart` kuralına benzer biçimde).
- [x] A/V hedefi (AvSync tabanı) atlamayla bozulmaz: hold sonrası bilinçli yüksek seviye atılmaz.
- [x] Birim testleri:
  - (a) alt taşma + 80 ms sonra toplu varış → seviye ≤ 1 s'de hedef ±10 ms;
  - (b) sessizlik sonrası yeni ses başı kesilmez;
  - (c) A/V hold seviyesi korunur;
  - (d) T-118 `UnderrunRefillTest` geçer.
- [x] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

**Kök neden (kod okundu):** T-118 kırpması yalnız PRIMING → PLAYING anında çalışıyor. Takılmanın birikmiş paketleri yakalama hızıyla (birkaç paket / 10 ms) gelirse hızlı yeniden başlama (`quickRestart`) ilk birkaç paketle başlar; kırpılacak fazla henüz yoktur. Geri kalan paketler çalma başladıktan sonra gelir ve seviye `target + ~takılma` olur. Bunu yalnız PI geri alır (en çok 5 ms/s).

**1. Alt taşma penceresi (`PlayoutCore`).**
- Açılış: bir yeniden başlamada açılır. Koşullar: önceden çalınmış (`hasPlayed`), A/V bekletmesiyle başlamamış (`heldThisPriming` değil), sessizlik sonrası değil (`idleRestart` değil). Alt taşma ve `Rebuffer` sonrası açılır. İlk açılışta açılmaz: o yeni bir sesin başıdır.
- Kapanış: pencere `SKIP_WINDOW_MS = 2000` sürer. Kuruma sonradan "idle" sınıflanırsa (`classifyStarve`, ikinci pakette sıçrama) pencere hemen kapanır: o ses yeni bir sesin başıdır.
- Ölçüm: pencerede seviye `SKIP_PROBE_MS = 200` ms'lik alt pencerelerle izlenir; her alt pencerenin en düşüğü (taban) alınır. Anlık seviye değil taban kullanılır, çünkü Wi-Fi'de testere 40–50 ms (varış boşlukları 41–50 ms). Anlık seviye `target + 20`'yi normalde de aşar. 200 ms, Wi-Fi'de en az 4 varış boşluğunu kapsar ve atlamayı toplu varıştan sonra ≤ ~0,4 s'ye getirir.
- Atlama: taban `target + SKIP_ABOVE_MS (20)` üstündeyse fazla (`taban − target`) atılır. Kuruma henüz sınıflanmadıysa T-118'deki gibi bir güvenlik adımı (+5) bırakılır. Atma `buffer.skipCrossfade`: okuma başından yeni konuma 3 ms çapraz geçiş (≤ 5 ms). Tık olmaz, perde değişmez. Pencerede en çok bir atlama; atlamadan sonra pencere kapanır. Yeni bir alt taşma yeni pencere açar.
- 2 s'nin gerekçesi: toplu varış, takılma süresi artı yakalama süresi içinde gelir. Gözlenen değerler: takılma ~80 ms, `owd_max` 94, RTT p95 en çok 126 ms; yani yeniden başlamadan sonra < ~0,3 s. 2 s birkaç ölçüm alt penceresine yer bırakır. Sonrasında 1 s'lik PI pencereleri ve kural 2 devrededir.
- Taban, 200 ms'lik kısa pencerede 1 s'lik tabandan biraz yüksek ölçülür. Hedefe tam inmek bu yüzden pratikte küçük bir pay bırakır; ayrıca pay eklenmez.

**2. Uzun süre yüksek seviye (pencere dışı).**
- `DriftController` tamamlanan pencere sayısını (`windows`) verir. `PlayoutCore`, art arda `SUSTAINED_WINDOWS = 3` pencerede (3 s) taban > `target + SUSTAINED_ABOVE_MS (60)` olursa tek bir atlama yapar (`taban − target`), sonra sayaç sıfırlanır.
- Sayaç her çalma başlangıcında sıfırlanır; pencereler `onPlaybackStart` ile başlar. Böylece en erken atlama, kesintisiz 3 s çalmadan sonradır. Sessizlikten sonra başlayan bir sesin başı (ilk 3 s) hiçbir zaman kesilmez.
- 60 ms altındaki sapma PI ile düzeltilmeye devam eder. 120 ms üstü mevcut `Resync`'tir.

**3. A/V koruması.**
- Hedef `max(safety, avFloor)`. Fazla her zaman bu hedefe göre ölçülür, A/V tabanının altına inilmez.
- A/V bekletmeli başlangıçta pencere açılmaz (T-118 kırpmasıyla aynı kural). O seviye bilinçli ve `seedAvFloor` ile hedef olur.
- `drift.onSkip(frames)`:
  - yeni bir PI penceresi başlatır (toplu varışın tepesi `lastSpan`'i şişirmesin);
  - `lastFloorFrames`'i atılan kadar düşürür (`Resync` ile aynı anlam);
  - oranı integrale çeker (hata ~0; hızlı moddaki +5000 ppm bir pencere daha boşaltıp hedefin altına inmesin).
- `AudioPlayout`: atlama olan istatistik saniyesinin A/V örneği `onAvOffset`'e verilmez, çünkü atlama öncesi ve sonrası seviyeleri karışıktır. Sonraki saniyenin örneği temizdir.

**4. Log.** Stats satırına `skip_trims=`, `skip_trim_ms=` eklenir.

**5. Testler** (yeni `LateBunchSkipTest`):
- (a) USB benzeri simülasyon: güvenlik payı 40 ms, 80 ms takılma; birikmiş paketler 4× hızla gelir (yakalama). Beklenen: 1 alt taşma, `skip_trims` 1. Toplu varıştan sonra ≤ 1 s'de taban hedefin ±10 ms'inde, anlık seviye ≤ target + 20; perde ≤ %0,5. Atlama kapatılınca testin düştüğü elle doğrulanır.
- (a') Aynı pencerede iki toplu varış → en çok bir atlama.
- (b) Sessizlik → yeni ses (yakalama zamanında sıçrama), paketler toplu gelir. Beklenen: `skip_trims` 0, atılan kare 0 (`drops` 0), 3 s içinde kesilme yok.
- (c) A/V bekletmeli başlangıç + kararlı akış: `skip_trims` 0, seviye korunur.
- (d) Kural 2: alt taşmasız +100 ms fazla. 3 s dolmadan atlama yok; dolunca tek atlama ve taban hedefe yakın. +50 ms fazlada atlama yok.
- (e) T-118 `UnderrunRefillTest` ve diğer mevcut testler değişmeden geçer.

## Handoff

- **Commit:** `fa1196a` (uygulama), plan `7ff8d16`; bu handoff ayrı commit. Dal: `task/T-125-audio-late-bunch-skip`.
- **Dokunulan dosyalar:**
  - `audio/PlayoutCore.kt`:
    - alt taşma penceresi: `SKIP_WINDOW_MS` 2000, `SKIP_PROBE_MS` 200, `SKIP_ABOVE_MS` 20;
    - uzun süre yüksek seviye kuralı: `SUSTAINED_ABOVE_MS` 60, `SUSTAINED_WINDOWS` 3;
    - `checkSkip`, `skip` ve `skipTrims`/`skipTrimFrames` sayaçları;
    - kuruma sonradan "idle" sınıflanırsa pencere kapanır.
  - `audio/DriftController.kt`: `windows` (tamamlanan pencere sayısı) ve `onSkip(frames)`. `onSkip` yeni pencere başlatır, `lastFloorFrames`'i atılan kadar düşürür ve oranı integrale çeker.
  - `audio/AudioPlayout.kt`: stats satırına `skip_trims=`, `skip_trim_ms=`; atlama olan saniyenin A/V örneği `onAvOffset`'e verilmez.
  - Yeni test: `LateBunchSkipTest`, 9 test.
- **Varsayımlar:**
  - Cihazdaki toplu varış, yakalama hızında gelen birikmiş paketlerdir. Testte 4× hız, 80 ms takılma kullanıldı.
  - Taban tahmini 200 ms'lik alt pencerenin en düşüğüdür. Wi-Fi'nin 40–50 ms'lik testeresi bunun içinde kalır. Daha seyrek, uzun boşluklar güvenlik payının işidir.
  - Atlama, okuma başında mevcut 3 ms çapraz geçişle (`skipCrossfade`) yapılır; bu, `Resync` ile aynı mekanizmadır. Bu atma `drops`/`drop_ms` sayaçlarına da yansır.
  - Plan'daki "anlık seviye ≤ target + 20" sınırı testte gerçekçi testereye göre gevşetildi: düzgün varışta ≤ target + 25, dörtlü (40 ms) varışta ≤ target + 50. Taban ölçütü (±10 ms) değişmedi.
  - Doğrulama: atlama kapatılınca (a) ve (d) testleri düşüyor. 1 s sonra taban 25–47 ms yüksek; kural 2 testinde 75 ms.
  - İlk açılışta (oturumun ilk çalması) pencere açılmaz, çünkü o yeni bir sesin başıdır.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  1. Wi-Fi'de alt taşmadan sonra (`underruns` +1) stats satırında `skip_trims` +1 olmalı. `level_ms_floor` 1–2 stats saniyesinde `target_ms` ±10'a dönmeli. `audio_ms` / `av_offset_ms` ~20 s değil ~1 s içinde normale inmeli (önceki gözlem: 187 / 149).
  2. Kulakla: kesintiden hemen sonra tık, ikinci bir boşluk ya da perde kayması duyulmamalı; atlama ≤ 3 ms çapraz geçiş.
  3. Sessizlikten sonra başlayan seslerin (bildirim sesi, video başlatma) başı kesilmemeli: `idle_gaps` artarken `skip_trims` artmamalı.
  4. Kararlı çalmada (USB ve Wi-Fi) `skip_trims` 0 kalmalı; `underruns` artmadan atlama olmamalı.
  5. A/V: atlamadan sonra `av_offset_ms` hedefe (~5 ms) yaklaşmalı, `target_ms` sıçramamalı.
- **Açık sorular:**
  - `docs/LOGGING.md` kartın `files:` listesinde değil. Yeni `skip_trims`/`skip_trim_ms` alanlarını orkestratör ekleyebilir.
  - Drift'in kendi `Resync` kararından sonra da aynı saniyenin A/V örneği karışık. Bu kartta dokunulmadı (kapsam dışı); gerekirse aynı `avSkipSeen` kuralı uygulanabilir.
