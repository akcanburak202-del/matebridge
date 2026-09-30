---
id: T-052
title: Tablet — uyarlanır kare zamanlaması (en az gecikmeyle takılmasız sunum, 60/120 Hz)
status: review
phase: 5
owner: android-client-dev
depends_on: [T-050]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-052-client-adaptive-pacing.md
---

## Amaç

NOTES 2026-10-01 "Takılma ölçümü": Mac kareleri kusursuz 8,3 ms aralıkla gönderiyor; tablette sunumda vsync'lerin **%21'i atlanıyor** (iki kare aynı vsync'e düşüp sonra bir vsync boş kalıyor). `jitter=2` (2 karelik tampon) atlamayı %2'ye indiriyor ama +16,7 ms gecikme ekliyor; `jitter=1` (+8,35 ms) **hiç etkisiz** — büyük olasılıkla `FramePacer`/`drainOutput` mantığında hata. Kullanıcı hem düşük gecikme hem takılmasızlık istiyor; kalem kullanıyor.

## Kabul kriterleri

- [ ] **Neden analizi:** `jitter=1`'in neden etkisiz olduğu bulunur ve Handoff'ta açıklanır (ör. hedef zamanın vsync'e göre fazı, `releaseOutputBuffer(idx, ns)`'nin SurfaceFlinger'daki davranışı, aynı çekilişte (drain) iki kare, "collided" mantığı).
- [ ] **Uyarlanır zamanlama** (yeni varsayılan, surface ve GL yollarında): her kare, varış zamanlarının düzgünleştirilmiş fazına göre bir vsync'e atanır; ek bekleme `D` en az tutulur ve ölçülen atlama oranına göre ayarlanır (hedef: atlanan vsync < %2, `D` genelde ≤ 1 vsync; 60 ve 120 Hz'te çalışır; panel hızı değişince (60↔120, Huawei dokunma kuralı) yeniden kilitlenir). Birikme yok: sınırlı kuyruk, gecikince en yeni kare kazanır (AGENTS.md).
- [ ] **Ölçüm istatistikte:** `OnFrameRenderedListener` zamanlarından sunum aralığı histogramı → `MB/render` satırına `skip_pct` (1,5 vsync'ten uzun aralıklar, kare mevcutken), `pace_ms` (ortalama ek bekleme), `vsync_ms`. İstatistik katmanında da görünür.
- [ ] Eski `--ei jitter N` sabit tampon seçeneği deney için kalır; `--ei jitter -1` (ya da benzeri) uyarlanır modu kapatır.
- [ ] Saf zamanlama mantığı birim testli (sahte saat, vsync, dalgalanan çözme süreleri: atlama oranı ve ek gecikme sınırları). `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Host. Cihaz ölçümü orkestratörde (`dumpsys SurfaceFlinger --latency`, scratch `pace.sh`).

## Plan

### Kök neden analizi (jitter=1 neden etkisiz)

`FramePacer.schedule`, hedef vsync'i `base = ilk vsync >= şimdi + N*P` ile seçiyor. Bu bir **tam sayı kaydırma**: `ceil(t + P) = ceil(t) + P`. Yani tampon N, karenin varış fazını vsync ızgarasına göre *hiç değiştirmiyor*; iki kare aynı vsync aralığına düşüyorsa (dalgalı çözme süresi) yine düşüyor, sadece hepsi N*P geç. Bu dalgalanmayı emen bir mekanizma yok.

Üstüne üç bozucu etki:
1. **Kadans mantığı 120 Hz'de ölü:** `fi == P` iken `v = max(base, last + P)`; `v - base` ızgaraya hizalı olduğu için 0 ya da >= P; `> fi/2` kuralı (P/2) her borç durumunu "çok borç" sayıp `v = base`'e geri sarıyor. Sonuç `v == base` (özdeşlik eşlemesi), çakışmada aynı slot.
2. **Zaman damgası ufkun içinde:** damga `V - P/2` ve `V - now` in [P, 2P) ise damganın şimdiye uzaklığı yalnızca [0,5P, 1,5P). SurfaceFlinger'ın (HarmonyOS/VRR) latch ufku genelde >= 1-2 vsync; ufuktan yakın damga "hemen sun" gibi davranır. Ölçüm bunu doğruluyor: jitter=0 (99/26) ile jitter=1 (98/27) birebir aynı, yalnızca `pace_add` 8,35 ms; jitter=2'de damga 1,5-2,5 P ileri -> damga gerçekten uygulanıyor ve 0 atlama.
3. Damga fazı (Choreographer app-vsync'i vs SF vsync'i arasındaki sabit kayma) bilinmiyor; `V - P/2` ancak bu kayma < P/2 ise doğru slotu verir.
Bu (2) ve (3) cihazda doğrulanamaz (bu oturumda tablete dokunulmuyor); (1) kod okumasıyla kesin.

### Çözüm: AdaptivePacer (video/AdaptivePacer.kt)

Host yakalama zamanı kusursuz düzenli (8,3 ms), varış/çözme çıkışı dalgalı. Bu yüzden playout gecikmesi yakalama zaman damgasına göre:
- `x = hazır_zamanı - captureUs*1000` (saat ofseti sabit, yalnızca fark önemli). Kayan 2 sn pencerede min `m` = en iyi durum hat gecikmesi; `dev = x - m >= 0` = o karenin fazla gecikmesi.
- `D = p98(son 256 dev) + 0,5 ms + extra`; `extra` = atlama oranına göre geri besleme (skip_pct > %2 -> +P/4, en çok 2P; 5 pencere < %0,5 -> -P/8).
- hedef = `hazır - dev + D` (yani `capture + m + D`, kare aralığı tam fi); slot = hedefi aşan ilk vsync (en erken şimdiki vsync); kare başına ayrı vsync (`slot >= son + P`); birikme `D + 2P`'yi aşarsa en yeni kazanır (çakışma, eski kare atılır).
- Damga `slot - P/2` (eski gibi). Panel hızı değişince (P %10+ değişirse) pencere, extra ve son slot sıfırlanır.
- Ölçüm: `PresentMeter`; `OnFrameRenderedListener` (pts -> hazır zamanı eşlemesi) aralıkları; aralık > 1,5 * kadans ve kare önceki gösterimden önce hazırsa "atlanan". `MB/render`: `skip_pct`, `pace_ms`, `vsync_ms`; overlay'de de.
- Modlar: `--ei jitter` yok -> uyarlanır (yüzey yolu); 0..2 sabit tampon (eski); -1 -> uyarlanır kapalı (=0). GL yolunda presenter kendi vsync hizalamasını yapıyor ve SurfaceTexture damgaları yok sayar; uyarlanır mod GL'de kapalı kalır (Açık soru).
- Testler: sahte saat/vsync, dalgalı hazır zamanları; 60/60, 120/120, 60 fps içerik 120 Hz; panel değişimi; PresentMeter; StatsFormat.


## Handoff

- **Commit:** dalın son commit'i (SHA orkestratöre raporlandı).
- **Dokunulan dosyalar:** `video/AdaptivePacer.kt` (yeni), `video/PresentMeter.kt` (yeni), `video/VideoRenderer.kt`, `video/VideoStats.kt`, `stream/StatsFormat.kt`, `MainActivity.kt`, `test/.../video/AdaptivePacerTest.kt` (yeni), bu kart.
- **Kök neden:** Plan'ın "Kök neden analizi" bölümü. Özet: `FramePacer` tamponu tam sayı vsync kaydırması (`ceil(t+P)=ceil(t)+P`), yani fazı değiştirmiyor; 120 Hz'te kadans/`fi/2` kuralı ölü (özdeşlik eşleme); ayrıca damga (`V-P/2`) 1 tamponda SurfaceFlinger latch ufkunun içinde kalıp muhtemelen "hemen sun" gibi işleniyor (jitter 0 ile 1 ölçümünün birebir aynı olmasıyla tutarlı). İlk madde kod okumasıyla kesin; ufuk/faz maddeleri cihazda doğrulanmadı.
- **Varsayımlar:** host yakalama zamanı (`captureTimeUs`) düzenli; saat ofseti sabit (yalnızca fark kullanılıyor, 2 sn min penceresi sapmayı karşılar). `OnFrameRenderedListener` zamanı gerçek sunum değil istenen render zamanı olabilir (zamanlı release'te); öyleyse `skip_pct` zamanlama düzenliliğini ölçer, gerçek atlama `dumpsys SurfaceFlinger --latency` ile doğrulanmalı. Varsayılan artık uyarlanır (yüzey yolu): `--ei jitter` yoksa; 0..2 eski sabit tampon; -1 uyarlanır kapalı (=0).
- **Test edilmeyenler / cihazda doğrulanacaklar:** `anim` (120 Hz, performans modu) ile `MB/render` satırında `skip_pct`, `pace_ms`, `vsync_ms`; `pace.sh` ile SF atlama oranı (hedef <%2, `pace_ms` yaklaşık <= 8 ms); aynı ölçüm 60 Hz'de ve dokunma ile 60<->120 geçişinde (yeniden kilit: `extra` sıfırlanır); `--ei jitter 0/1/2/-1` eski davranış; kalemle gecikme hissi. AdaptivePacer sabitleri (p98, 0,5 ms marj, geri besleme eşikleri) ölçüme göre ayarlanabilir. Birim testler simüle jitter ile: naif eşleme >%10 atlama, uyarlanır <%2, ek bekleme <= 1 vsync.
- **Ek tur (cihaz sonucu: pace_ms ~15-16,7, çözme ~12-13 ms dalgalı):**
  - Çıkış tarafı artık **ayrı iş parçacığında** (`mb-decoder-out`), bloklayan `dequeueOutputBuffer(5 ms)` ile; eskiden çıkış yalnızca giriş döngüsünün `queue.poll(4)`/`dequeueInputBuffer(4 ms)` beklemeleri arasında boşaltılıyordu (hazır kare 0-4 ms geç işleniyordu; bu doğrudan `dev` sapmasına ve dolayısıyla D'ye yansır). Sınırlı kuyruk/en yeni kazanır mantığı aynı (burst içinde ilk dequeue bloklar, kalanlar beklemesiz). Çıkış iş parçacığı hatası giriş döngüsünü durdurur ve eski yeniden başlatma politikasına gider; `stop()` öncesi join.
  - `KEY_OPERATING_RATE`: varsayılan akış fps; `--ei oprate -1` = `Short.MAX_VALUE` deneyi, `-2` = ayarlama, N = açık değer. `KEY_PRIORITY=0` zaten vardı. `MB/decoder codec_start` satırı istenen hızı ve `codec.inputFormat`'tan kabul edilen `priority`/`operating_rate`/`low_latency` değerlerini loglar.
  - Kare başına çözme gecikmesi (input -> output) p50/p95/p99: `MB/render` satırında `dec_p50_us/dec_p95_us/dec_p99_us`, `pace_d_us` (seçilen D); overlay pacing satırında `D x ms | çözme p95 y ms`.
  - Doğrulanacak: çıkış iş parçacığıyla `pace_ms` ve `skip_pct` (önce/sonra), `dec_p95` ile oprate 0/-1/-2 karşılaştırması, kabul edilen oprate değeri. Kod yolu değişti: soğuk başlangıç, detach/yeniden bağlanma, 60<->120 geçişi, decoder hata yeniden başlatmada takılma/çökme olmamalı.
- **Tur 3 (PresentMeter SF'den fazla atlama gösteriyordu, D 8<->16 salınıyordu):**
  - Sorun: frame-rendered callback zamanı gerçek sunum zamanı değil (istenen render/bırakma zamanı, toplu callback); çözme jitter'ı bile aralıkları >1,5 vsync gösteriyordu. `PresentMeter` artık yalnızca tanı (`cb_skip_pct`).
  - Yeni atlama sinyali (`skip_pct`): `AdaptivePacer` kendi çizelgesinden hesaplar: kare hedef slotunu kaçırdıysa (`late`: hedef slot < en erken vsync) ve önceki slot ile arası > 1,5 kadans ise "atlama" (boşta kaynak/statik ekran sayılmaz, çünkü hedef `capture` zamanına bağlı). Serbest bırakma zamanı damgalarının uygulandığı varsayımıyla SF'deki atlamayla eşdeğer olmalı. Karşılaştırma: `skip_pct` vs SF vs `cb_skip_pct`.
  - D hesabı: önceki karelerin gecikme sapmasının p99'u (mevcut kare hariç, böylece beklenenden kötü kare "geç" sayılır) + 0,5 ms; artı geri besleme seviyesi (0 / P/2 / P). Seviye artışı: skip > %3 art arda 3 pencere; azalış: < %1 art arda 5 pencere; her değişiklikten sonra 10 pencere bekleme (histerezis). Eski P/4 adımlı süzme kaldırıldı.
  - Testler: 120 Hz'te 3 ms çözme jitter'ı, 1 dakika: seviye hiç değişmiyor, atlama <%1, D <= 1 vsync; histerezis/bekleme; boşta kaynak atlama sayılmaz; geç kare atlama sayılır.
- **Tur 4 (60 Hz panelde 120 fps içerik: D 50 ms, gecikme 53 ms):**
  - Kök neden: içerik paneden hızlı (fi < P) iken her kare `lastSlot + P`'ye itiliyordu; kare başına 8,3 ms gelirken slot 16,7 ms ilerlediği için birikme büyüyor, gelecekte damgalı tamponlar SF'de bekleyip codec çıkış tamponlarını tutuyor, çözücü tıkanıyor (`dec p95` 69 ms = kuyruk bekleme, gerçek çözme değil), `dev` ve D şişiyor, giriş kuyruğu taşıp "Atılan"/keyframe isteği üretiyor.
  - Düzeltme (`AdaptivePacer`): `surplus = fi < 0.75 P` iken D <= 1 vsync + 0,5 ms (seviye eki yok) ve slot çakışırsa **itme yok, en yeni kazanır** (`collided`, eski kare atılmış sayılır, `skipped` değil). Panel hızı değişince (`setNominalHz` ile anında; ayrıca pacer >%10 periyot farkını görür) pencere, seviye ve son slot sıfırlanır: geri dönüşte taban D.
  - Giriş tarafı: `FrameQueue` P-kare zinciri nedeniyle kare atlayamaz (taşarsa hepsini atıp keyframe ister: protokol kuralı); çözme akıcı kaldığı sürece taşmaz. Kare atma çıkışta (render=false/aynı damga) yapılıyor. `dec_*` yüzey tamponları tutulduğunda kuyruklanmayı da içerebilir: artık itme olmadığı için ~çözme süresine dönmeli.
  - Testler: 120 fps @ 60 Hz 30 sn: ~%40-60 atma, D <= P60 + marj, ortalama gecikme <= 2 vsync, atma atlama sayılmıyor; 120 -> 60 -> 120 geçişinde seviye/D sıfırlanıyor.
  - Cihazda bak: 60 Hz'de (dokunmadan) `pace_ms`, D, Gecikme, `dec_p95`, "Atılan"; keyframe isteği olmamalı; dokunma ile 120 <-> 60 geçişinde toparlanma.
- **Açık sorular:** (1) GL yolunda uyarlanır mod kapalı (SurfaceTexture render damgalarını yok sayar; presenter kendi vsync hizalamasını yapıyor): kabul ölçütündeki "GL yolunda da" karşılanmadı; istenirse presenter kuyruklamasıyla ayrı kart. (2) Damga fazı (`V-P/2`) Choreographer/SF vsync kaymasına bağlı; ölçümde sistematik 1 vsync sapma görülürse faz parametresi eklenmeli.
