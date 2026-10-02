---
id: T-121
title: Tablet — kısa kare yığılmasında keyframe fırtınası (MAX_PENDING=2 → bırak-hepsini + KEYFRAME_REQUEST); yığılmayı yut, istekleri sınırla
status: review
phase: 5
owner: android-client-dev
depends_on: [T-120]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/test/
  - tools/pacing/
  - backlog/tasks/T-121-client-keyframe-storm.md
---

## Amaç

Cihaz (2026-10-02 ~11:00, NOTES'a eklenecek): ses kesintilerinin kökü bir **keyframe fırtınası**. İncelenen her büyük ses boşluğundan (60–253 ms) hemen önce host logunda 100–300 ms içinde art arda 4–6 `keyframe_request` var:
- çoğu `reason=2` FRAMES_DROPPED;
- arada `reason=0` STARTUP ve `codec_config_resent`.

Örnek (USB, 120 Hz, imleç hareketi):
- tablet `MB/decoder` bir saniyede `bytes` 476 KB → **4,87 MB**, `drop=24`;
- `MB/render` `late_drops=46`;
- aynı anda ses `owd` 13 → 41 ms, alt taşma.

T-120 `tick_late_ms=0.1`: tablet süreci donmamış. Veri gerçekten geç geldi, çünkü birkaç büyük IDR (2800×1840, her biri yüzlerce KB – ~1 MB) bağlantıyı (USB ya da Wi-Fi) dolduruyor ve ses arkada kalıyor.

`FrameQueue` (`MAX_PENDING = 2`):
- Bekleyen kare 2'yi aşınca tüm bekleyenleri ve geleni atıyor, keyframe gelene kadar kapıyı kapatıyor ve `KEYFRAME_REQUEST(FRAMES_DROPPED)` üretiyor.
- 120 fps'te çözme ~10–15 ms (boru hattında 3 kare). Ağdan 3–4 karelik kısa bir yığılma bu yüzden tam sıfırlamaya yetiyor.
- IDR'nin kendisi büyük ve yavaş çözülüyor; arkasından yine taşma oluyor ve bir istek daha geliyor. Zincirleme fırtına bu.

## Kapsam dışı

- Host tarafı istek birleştirme (T-122, paralel).
- Kodlayıcı ayarları (IDR boyutu, intra refresh): ayrı karar.
- Protokol değişikliği.

## Kabul kriterleri

- [x] **Kök neden ölçümü:** taşma anında bir `W`/`I` satırı yazılır. İçeriği: bekleyen kare sayısı, codec'teki kare sayısı (`in_codec`), son çözme süresi, son varış aralıkları, taşmanın keyframe'den sonraki kaçıncı kare olduğu. `reason=0 STARTUP`'ın akış ortasında neden gönderildiği (codec yeniden başlatma mı?) bulunur, Plan/Handoff'a yazılır.
- [x] **Kısa yığılmayı yut:** sınırlı bir derinliğe kadar (örneğin 120 fps'te ~6–8 kare ≈ 50–65 ms; Plan'da gerekçe) bekleyen kareler atılmaz. Çözücü yetişir, sunumda zaten "en yeni kazanır" kuralı geçerlidir (pacer eski kareyi göstermez).
  - Gerçek taşma (sınır aşıldı) bugünkü gibi bırak + istek.
  - AGENTS.md kuralı korunur: kuyruk sınırlıdır, eski kare gösterilmez.
  - Plan'da gecikme etkisi yazılır: yığılma sırasında geçici; sürekli çözücü yetersizliğinde sınırla kesilir.
- [x] **İstek sınırı:** bir KEYFRAME_REQUEST'ten sonra keyframe gelene kadar ya da en az 500 ms (sabit, Plan'da gerekçeli) yeni FRAMES_DROPPED isteği gönderilmez. STARTUP / DECODE_ERROR hemen gider ama aynı kural uygulanır (aynı keyframe'i bekle).
- [~] Sayaçlar (ayrı `ev=queue` satırında, bkz. Açık sorular): `MB/decoder` stats satırına `kf_req=`, `overflows=`, `max_pending=` eklenir.
- [x] Birim testleri:
  - (a) 120 fps akışta 4 karelik yığılma → atma yok, istek yok;
  - (b) sürekli yetersiz çözücü → sınırda atma + tek istek;
  - (c) 500 ms içinde ikinci taşma → ikinci istek yok;
  - (d) keyframe gelince kapı açılır;
  - (e) mevcut `FrameQueue` testleri geçer ya da gerekçeyle güncellenir.
- [x] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

**Kök neden (kod okuması, 2026-10-02):** akış ortasındaki `reason=0 STARTUP` bir codec yeniden başlatması değil. `MainActivity` ticker'ı her 500 ms'de `renderer.isWaitingKeyframe()` doğruysa `KEYFRAME_REQUEST(STARTUP)` gönderiyor. Taşma kapıyı kapattıktan sonra IDR gelene kadar (100–300 ms) ticker bir kez ateşlenirse, FRAMES_DROPPED'ın hemen arkasından bir STARTUP daha gider. Host STARTUP'ta `codec_config_resent` yapar. Cihazdaki `kf_request src=` satırları bunu doğrulayacak.

1. **`FrameQueue` derinliği:** `maxPending` artık ayarlanabilir. `depthForFps(fps) = clamp(ceil(fps × 64 ms), 2, 8)`, yani 120 fps → 8 kare (≈ 67 ms), 60 fps → 4 kare. Gerekçe: 2800×1840 IDR (0,3–1 MB) Wi-Fi'de ~40–60 ms bağlantıyı tutar, arkasındaki P kareleri 5–7 kare yığılır. Çözücü yığılmayı ~30–40 ms'de eritir (codec'te 3 kare boru hattı). Gecikme etkisi geçicidir: sunumda "en yeni kazanır" (pacer geç kareyi late-drop eder), eski kare gösterilmez. Sürekli çözücü yetersizliğinde kuyruk sınıra dolar ve bugünkü gibi hepsini bırak + kapıyı kapat + istek. `VideoRenderer` derinliği constructor'da ve `reconfigure`'da `config.fps`'ten ayarlar.
2. **İstek sınırlayıcı (`FrameQueue` içinde, saat enjekte edilebilir):** `HOLDOFF_MS = 500`. Bir istekten sonra 500 ms dolmadan yeni FRAMES_DROPPED gitmez. Keyframe gelişi süreyi sıfırlamaz: IDR → taşma → istek zincirini kıran şey bu. Bastırılan istek "bekleyen" olarak işaretlenir. Kapı kapalıyken süre dolduktan sonraki ilk gelen karede FRAMES_DROPPED olarak gider; kare gelmiyorsa ticker gönderir. `reset()` (STARTUP) ve `onDecoderError()` (DECODE_ERROR) hemen döner ama süreyi yeniden kurar. 500 ms gerekçesi: ticker'ın `KEYFRAME_RETRY_MS` aralığıyla aynı. Bir IDR'nin gidiş-dönüşünü (istek + kodlama + 1 MB aktarım + çözme ≈ 100–300 ms) karşılar. Saniyede en çok 2 istek demek.
3. **Ticker (MainActivity kapsam dışı):** `VideoRenderer.isWaitingKeyframe()`, `takeKeyframeRetry()`'ye delege eder. Yalnızca kapı kapalıysa **ve** son istekten 500 ms geçmişse true döner, ve isteği gönderilmiş sayar. Böylece ticker sınırlayıcıdan geçer ve taşmanın arkasından STARTUP gitmez. Açık soru: MainActivity'nin yeni adı çağırması.
4. **Ölçüm:** taşma anında `W decoder ev=queue_overflow` yazılır: `pending`, `limit`, `in_codec` (InFlightGauge), `decode_last_us` (VideoStats'a son çözme süresi), `since_kf` (keyframe'den sonraki kare sırası), `gaps_us` (son 8 varış aralığı), `req=sent|held`, `since_req_ms`. Her istek için `I decoder ev=kf_request reason= src=overflow|deferred|retry|reset|error` yazılır.
5. **Sayaçlar:** `kf_req`, `kf_held`, `overflows`, `max_pending`, `limit`. `MB/decoder ev=stats` satırı MainActivity'de kurulduğu ve dosya kapsam dışı olduğu için sayaçlar `onSkipWindow`'da (stats tick'te, her pencerede) ayrı bir `I decoder ev=queue ...` satırına yazılır. Açık soru: ev=stats'a taşımak.
6. **Testler:** (a)–(e) kart listesi; ayrıca reset/hata isteği sınır içinde bile gider, `takeRetry` ve taşma bilgisi içeriği test edilir. Mevcut testler (PaceTrace, InputHandoff, FrameQueueTest overflow) taşma kuralını sınamak için `maxPending = 2` ile kurulur. Kural aynı, yalnızca derinlik farklı.
7. SessionController'a ve tools/pacing'e değişiklik gerekmiyor.

## Handoff

- **Commit:** `c5906e4` (uygulama), `235c0d2` (plan); handoff commit'i bunun üstünde.
- **Dokunulan dosyalar:**
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameQueue.kt`: derinlik `depthForFps`, 500 ms istek sınırı, bekleyen istek, taşma bilgisi, sayaçlar, `takeRetry`.
  - `video/VideoRenderer.kt`: derinliği fps'ten ayarlar; `queue_overflow` / `kf_request` / `queue` log satırları; `takeKeyframeRetry`; `isWaitingKeyframe` artık ona delege ediyor.
  - `video/VideoStats.kt`: `lastDecodeUs`.
  - Testler: yeni `FrameQueueBurstTest.kt` (10 test). `VideoTest.kt` (FrameQueueTest), `PaceTraceTest.kt` ve `InputHandoffTest.kt` taşma kuralını kısa tutmak için `maxPending = 2` ile kuruluyor. Kural aynı, yalnızca derinlik farklı.
  - SessionController ve tools/pacing'e dokunulmadı, gerek olmadı.
- **Kök neden (STARTUP):** akış ortasındaki `reason=0 STARTUP` bir codec yeniden başlatması değil, `MainActivity` ticker'ının 500 ms'lik "kapı kapalıysa STARTUP gönder" yeniden denemesi. Taşmadan sonra IDR gelene kadar ticker ateşlenirse FRAMES_DROPPED'ın hemen arkasından gidiyordu. Host bunu `codec_config_resent` ile cevaplıyor. Artık ticker, `isWaitingKeyframe()` → `takeRetry()` üzerinden sınırlayıcıdan geçiyor. Cihazda `MB/decoder ev=kf_request src=retry` satırları doğrulayacak. Gerçek codec yeniden başlatmasında `src=reset` ya da `src=error` görünür, ayrıca `ev=codec_stop` / `codec_start` var.
- **Varsayımlar:**
  - `STREAM_CONFIG.fps` gerçek akış hızına yakın kabul edildi. 120 fps'te derinlik 8; host 60 Hz'e inceltirse (T-059) aynı 8 kare ≈ 133 ms. Sınırlı ve geçici, sunum yine en yeni kareyi gösteriyor.
  - Keyframe gelişi 500 ms süreyi sıfırlamıyor (test c). Zincirdeki ikinci taşmada ekran en çok ~500 ms + RTT donabilir. Bunun karşılığı fırtınanın kesilmesi.
- **Test edilmeyenler / cihazda doğrulanacaklar** (cihaz testi yapılmadı):
  1. USB'de 120 Hz'te imleç ya da pencere hızlıca sürüklenir. Beklenen: `adb logcat -s MB/decoder` çıktısında `ev=queue_overflow` nadir olmalı. `ev=queue` satırlarında `max_pending` çoğunlukla 1–4, `overflows=0`, `kf_req` 0 olmalı. Saniyede 2'yi geçmemeli.
  2. Taşma olursa `ev=queue_overflow` satırı okunur: `in_codec`, `decode_last_us`, `gaps_us` (önce büyük boşluk, ardından ~0 aralıklı yığılma beklenir), `since_kf`. Bu satırlar kök nedeni ayırır: ağ yığılması mı, çözücü yetersizliği mi.
  3. Host logunda 100–300 ms içinde art arda 4–6 `keyframe_request` artık görünmemeli. İki istek arası ≥ 500 ms olmalı. `reason=0` yalnızca bağlantı veya yüzey başında görünmeli. Mac'te ses `owd` sıçramaları ve alt taşmalar azalmalı.
  4. Wi-Fi'de aynı test ile `MB/render late_drops` ve sunum gecikmesi (`latency_us`) karşılaştırılır. Yığılma sırasında geçici artış beklenir, kalıcı artış beklenmez.
  5. Arka plan → ön plan ve akış ayarı değişimi (reconfigure) sonrası görüntü geri gelmeli: `src=reset`, ardından keyframe.
- **Açık sorular:**
  - `MB/decoder ev=stats` satırı `MainActivity.statsTick` içinde kuruluyor ve dosya kartın `files:` listesinde değil. Sayaçlar bu yüzden her pencerede ayrı bir `I decoder ev=queue kf_req= kf_held= overflows= max_pending= limit=` satırına yazılıyor. Kart ev=stats'a eklemeyi istiyor. Orkestratör isterse MainActivity'de iki satırlık bir takip işi yeter.
  - Ticker'ı sınırlamak için `VideoRenderer.isWaitingKeyframe()` yan etkili oldu: true dönüşü bir isteği gönderilmiş sayar. Doğrusu `MainActivity`'nin `takeKeyframeRetry()`'yi çağırması (tek satır, kapsam dışı).
  - `docs/PROTOCOL.md` §5 (satır ~527) hâlâ "en çok **2** kare" diyor. Tel formatı değişmedi, ama davranış metni güncellenmeli (8 kare ≈ 64 ms, 500 ms istek sınırı). Bunu yalnızca orkestratör değiştirebilir. Yeni `ev=queue_overflow`, `ev=kf_request` ve `ev=queue` satırları `docs/LOGGING.md`'ye de eklenmeli.
