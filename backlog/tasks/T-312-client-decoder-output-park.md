---
id: T-312
title: Tablet — codec boşken çözücü çıkış iş parçacığı park eder (CB2, A/B anahtarı); Tam renk aux çözücü ve GL beklemesi olay tabanlı (C10/CB9)
status: review
phase: 7
owner: android-client-dev
depends_on: [T-303]
decisions: [0019]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt (orchestrator)
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - backlog/tasks/T-312-client-decoder-output-park.md
---

## Amaç

T-298 CB2 (`docs/reviews/2026-10-08/agents/opt-b-client.md`) ve T-297 C10. T-296 tabanı: kaydırma ve hareket sahnelerinde çözücü yolu ~1.900 uyanma/s (`MediaCodec_loop` ~780, `mb-decoder-out` ~515, `CodecLooper` ~430). Çıkış iş parçacığı, son 300 ms içinde çıktı geldiyse codec boş olsa bile 5 ms'de bir yokluyor. Zaman aşımına uğrayan her senkron dequeue iki looper uyanması daha getiriyor.

## Kabul

1. **Sayaç:** çıkış iş parçacığı, codec'e verilen (CODEC_CONFIG hariç) ve alınan karelerin farkını izler.
2. **Park:** fark 0 ve tutulan tampon yoksa iş parçacığı `LockSupport.park`'a girer. Giriş iş parçacığı `queueInputBuffer` sonrasında ve emeklilikte (retire) `unpark` eder. Sigorta 20 ms.
3. Kare uçuştayken 5 ms dequeue aynen kalır. **Uzun dequeue yok.**
4. **A/B anahtarı:** `--es dec_out_park off|on`, varsayılan `off`. DevKnobs ve `ev=profile knobs=`. Benimsenirse varsayılan değişir.
5. **Davranış:** 0019 kuşak, emeklilik ve sahiplik kuralları ile `FirstOutputBypass` değişmez. `DecoderLifecycleTest`, `GenerationHandoffTest` ve diğerleri geçer; park ve unpark yolu için yeni testler (kaçan unpark → sigorta).
6. **C10:**
   - `AuxDecoder` giriş iş parçacığı 4 ms `awaitNext` yerine olay park eder (`DecoderWaits.EVENT_INPUT_WAIT_NS` gibi uzun sigorta).
   - Çıkış `IdleWait` kullanır.
   - `PackedPresenter` GL 25 ms beklemesi yalnız bildirimle uyanır (sigorta korunur).
   - Bekçi (2 s) en geç 250 ms'de bir kontrol edilir.
7. **Cihaz A/B (orkestratör, T-286 yöntemi):** `/proc` iş parçacığı uyanmaları ve `cap_dec` p50/p95 ±1 ms, 10 fps ve hareket sahnesi.

## Plan

1. `OutputPark` (yeni, saf, JVM testli): in-flight sayaç (CODEC_CONFIG hariç), `parkIfEmpty(holding, sinceLastOutputNs)`, `signal()`; sigorta 20 ms; 1 s çıktısız kalırsa sayaç 0'a eşitlenir (codec'in yuttuğu kare yüzünden park sonsuza dek kapanmasın).
2. `VideoRenderer`: codec başına `OutputPark(outPark)`; giriş iş parçacığı `queueInputBuffer` ÖNCESİ sayar, SONRASI `signal()`; çıkış iş parçacığı tutulan tampon yoksa ve sayaç 0 ise park eder, kare uçuştayken 5 ms dequeue aynen; retire (`st.stop()` sonrası) `signal()`. `outPark` alanı varsayılan false.
3. `DevKnobs`: `dec_out_park off|on` (debug-only, STRING, profile `knobs=` listesine otomatik girer).
4. C10: `AuxDecoder` giriş beklemesi `DecoderWaits.EVENT_INPUT_WAIT_NS` (olay tabanlı; `AuxFrameQueue.awaitNext(abort)` kilit altında kontrol eder, çıkış hatası `queue.wake()`); aux çıkış `IdleWait`; `PackedPresenter` GL beklemesi `GlWait`: bekleyen iş (tutulan görüntü, çitsiz çizim, retire kuyruğu, son çizimden 500 ms) varsa 25 ms, yoksa 250 ms sigorta + bildirim.
5. Testler: `OutputParkTest` (saf park/unpark/sigorta/resync, GL politikası, aux kuyruk, sahte codec ile renderer A/B), `DevKnobsTest`.

## Handoff

- Branch `task/T-312-output-park`; commit SHA: `git log -1` (tek commit, "T-312: ...").
- Dosyalar: `video/OutputPark.kt` (yeni: `OutputPark`, `GlWait`), `video/VideoRenderer.kt`, `video/AuxDecoder.kt`, `video/AuxFrameQueue.kt`, `video/PackedPresenter.kt`, `video/ChromaReuse.kt` (`DrawWatch.hasOutstanding`), `session/DevKnobs.kt`, testler `OutputParkTest.kt` (yeni), `DevKnobsTest.kt`.
- `./scripts/check.sh`: ALL OK.
- Varsayımlar: sayaç codec başına; çıktılar yalnız `isFrame` (CODEC_CONFIG değil) sayılır; giriş sayımı `queueInputBuffer` ÖNCESİ (çıktı çağrı dönmeden gelebilir), unpark SONRASI. Park yalnız sayaç 0 ve tutulan tampon yokken; aksi halde bire bir eski 5 ms (uzun dequeue yok). Kaçan unpark en çok 20 ms sigorta. `dec_out_park off` = eski davranış (sayım bile yapılmaz).
- GL (CB9): bekleyen iş yokken 25 ms yerine 250 ms (bildirim `offerMain/offerAux/shutdown` ile uyandırır). Bekleyen iş = tutulan görüntü, tamamlanmamış çizim, retire kuyruğunda görüntü veya son çizimden <500 ms (zaman damgası kuyruğu). Fence_stall bekçisi (500 ms) bekleyen çizim varken 25 ms'de kalır.
- Aux (C10): giriş 4 ms yerine 250 ms olay beklemesi; bekçi (2 s) en geç 250 ms'de bir kontrol edilir. Aux çıkış 5 ms -> 20 ms (300 ms çıktısız sonra).
- TABLETTE TEST EDİLMEDİ. Orkestratör: (1) (bağlantı yapıldı: MainActivity `it.outPark = devKnobs.decOutPark`; `dec_out_park` yalnız `--ez dev true` ister, debug olmayan günlük derlemede de çalışır, karar 0037) `--es dec_out_park on` ile 10 fps ve hareket sahnesinde `/proc` iş parçacığı uyanmaları (`mb-decoder-out`, `MediaCodec_loop`, `CodecLooper`) ve `cap_dec` p50/p95 (±1 ms) `off` ile karşılaştır; (2) `ev=profile knobs=` içinde `dec_out_park:on` görünmeli; (3) Tam renk açıkken `mb-gl` ve `mb-aux-dec` uyanmaları statik ekranda düşmeli, late upgrade ve `gl_*` istatistikleri değişmemeli; (4) detach/yeniden bağlanma ve uyku-uyanma sonrası görüntü gelmeli.

- Review turu 1 (Codex P1): `OutputPark` sayaç sıfırlaması "son çıktıdan beri" süreye bakıyordu; uzun statik ekrandan sonra ilk karenin sayacı hemen sıfırlanıp çıkış dequeue'su atlanıyor, görüntü donuyordu. Düzeltme: en eski bekleyen girişin kuyruğa girme zamanı damgalanır (sayaç ve damga tek kilit altında); 1 s'den eski bekleyen giriş yutulmuş sayılır, sayaç sıfırlanır AMA o çağrı yine gerçek dequeue yaptırır (park bir sonraki turda). Yeni sayılan giriş için dequeue asla atlanmaz. Testler: 5 s boşta sonra tek kare, boşta sonra yığın, yutulan kare sonrası park devamı, kaçan unpark sigortası, renderer ile 2 s boşta + yığın + sonraki kare.
- Review turu 2 (Codex P1): sayaç + 1 s resync tasarımı yutulan/geç çıktıda yine donma üretebiliyordu. Tasarım değişti: sayaç yalnız park KARARI için ipucu; park her zaman 20 ms sigortalı ve park dönünce bir sonraki tur HER ZAMAN gerçek `dequeueOutputBuffer` (5 ms) yapar (üst üste iki atlama imkansız). Resync/sıfırlama ve zaman damgası tamamen silindi; yutulan kare sayacı >0 bırakırsa yalnız eski 5 ms yoklama sürer (donma yok, tasarruf kaybı). En kötü durum: geç/yetim kare ~25 ms içinde görülür; boşta ~50 uyanma/s (IdleWait ile aynı). Testler: park sonrası zorunlu prob, yutulan kare, probdan sonra gelen çıktı bir sigorta içinde, boşta+tek kare+yığın, rastgele serpiştirme değişmezi (üst üste iki park yok), renderer'da 2 s boşta+yığın+sonraki kare.

## Open questions

- `docs/KNOBS.md` `dec_out_park` satırı orkestratörde (kart dosyaları dışında).
