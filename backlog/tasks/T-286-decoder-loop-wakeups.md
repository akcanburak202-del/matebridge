---
id: T-286
title: İstemci — çözücü döngülerinde sabit 4/5 ms yoklama yerine olaya bağlı uyanma (10 fps'te ~950 uyanma/s)
status: review
phase: 6
owner: android-client-dev
depends_on: [T-282]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VsyncIdle.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameQueue.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/InputBufferSlot.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - backlog/tasks/T-286-decoder-loop-wakeups.md
---

## Amaç

T-282 ölçümü (`docs/research/2026-10-07-perf-profile.md` §Sıcak noktalar 3): giriş döngüsü `INPUT_WAIT_NS` = 4 ms, çıkış döngüsü `OUTPUT_WAIT_US` = 5 ms bekliyor. `IdleWait` yalnız 300 ms karesiz kalınca 20 ms'e çıkıyor. 10 fps akışta (ör. Mac'te bir animasyon):
- `mb-decoder` ~265, `mb-decoder-out` ~246, `MediaCodec_loop` ~453 uyanma/s;
- bu üçü ve `CodecLooper` toplam ~%12 tek çekirdek.

60 fps'te aynı iş parçacıkları %34. **Gecikme yolu: risk yüksek.** Protokol değişmez.

## Kabul

1. Önce okuma ve not: her iki döngünün neden zaman aşımıyla beklediği (T-077 giriş yuvası önceden alma, T-141 boşta uyku, çıkış biçim değişimi ve hata yakalama, `VideoHealth`). Plan bunu yazar, sonra uygular.
2. Giriş döngüsü kare yokken `FrameQueue`'da **kare gelene ya da durdurulana kadar** bekler, boş yere dönmez. Kare gelince uyanma gecikmesi bugünküyle aynı ya da daha iyi. Kuyruğa koyan taraf uyandırır.
3. Çıkış döngüsü bekleyen giriş yoksa (kuyruğa verilmiş ve çıkışı alınmamış kare sayısı 0) kısa yoklamayı bırakır. Çıkış beklenirken bugünkü süre korunabilir; zaman aşımı dışında başka bir uyarı yolu yoksa bu açıkça yazılır.
4. Durdurma, oturum değişimi, codec yeniden kurma ve `VideoHealth` takılma algısı aynı çalışır: testler, uyanmayan iş parçacığı kalmadığını gösterir. "Kayıp uyanma" yarışı için test (VsyncIdle'daki gibi).
5. Cihaz A/B (orkestratör, tek seferde): 10 fps arka plan ve Oyun 60. Hedef: 10 fps'te üç iş parçacığında toplam uyanma ≥500/s azalır. `latency_ms` p50/p95 ve `decode_ms` kötüleşmez (±1 ms). Kötüleşirse kart geri alınır, sonuç yazılır.

## Plan

Okuma notları (kod: `VideoRenderer.runCodec`, `FrameQueue.awaitNext`, `IdleWait`, `InputBufferSlot`):

**Giriş döngüsü (`mb-decoder`) neden 4 ms'de bir zaman aşımına düşüyor?** Kare gelmesi için değil: `FrameQueue.offer` zaten park eden iş parçacığını `unpark` ediyor (T-077), `revokeConsumer`/`assignConsumer` de (retire, yeni nesil). Zaman aşımı yalnız şunlar için "sigorta":
1. `outError` (çıkış iş parçacığı bir hata yakaladı): giriş döngüsü bunu ancak bir sonraki turda `while` koşulunda görüyor; çıkış tarafı giriş tarafını uyandırmıyor. Yani hata algısı en çok 4 ms gecikiyor.
2. `att.active` (retire): `handoff.retire` önce `active=false`, sonra `revokeConsumer` `unpark` ediyor, `owns()` kontrolü yüzünden `awaitNext` hemen null dönüyor. Bu yol zaten olaya bağlı. Zaman aşımı ikinci bir güvence.
3. `IdleWait` (T-141): 300 ms karesiz kalınca 20 ms. Yalnız uyanma sayısını azaltmak için, davranış için değil.
4. Başka bir şey zaman aşımına bağlı değil: tur sonunda tek iş `inSlot.prefetch()` (T-077, tutulan indeks varsa çağrı yok) ve `lastFrameNs`. T-252 yakalama süresi (`catchUp` son tarihi) `take()` içinde kontrol ediliyor ama yalnız kuyrukta `limit`'ten fazla kare varken tetikleniyor; o durumda `take` zaten bekleme olmadan çağrılır. Yani boş kuyrukta zaman aşımı onun için gerekmiyor.
`held != null` (codec girişi dolu) yolunda `awaitNext` zaten çağrılmıyor, `dequeueInputBuffer(4 ms)` bekliyor; değişmez.

**Çıkış döngüsü (`mb-decoder-out`) neden 5 ms?** `dequeueOutputBuffer(waitUs)` çıkış hazır olunca hemen döner; zaman aşımı yalnız (a) `st.current` (durdurma: giriş iş parçacığı `st.stop()` yapıp 500 ms `join` ediyor; MediaCodec bekleyen `dequeue`yi başka iş parçacığından uyandırmanın yolu yok, `interrupt` yerel beklemeyi kesmez) ve (b) `SlotReleaser`'da tutulan tamponun son tarihi (`untilDeadlineNs`, bu zaten `waitUs`'u kısaltıyor) için. Her zaman aşımı MediaCodec `looper` iş parçacığında da 2 uyanma (sync `dequeueOutputBuffer` mesajı + zaman aşımı mesajı) harcıyor, `MediaCodec_loop` 453/s'nin kaynağı bu.

**Yeni davranış (`DecoderWait.EVENT`, kapı: `--ez dev true --es dec_wait event`; varsayılan `poll` = bugünkü kod, bayt bayt aynı yol):**
- Giriş: `awaitNext` kare gelene dek park eder; sigorta zaman aşımı 250 ms (`EVENT_INPUT_WAIT_NS`). Durdurma/hata sigortaya bağlı değil: `awaitNext`'e `abort` koşulu eklenir (`!att.active || outError != null`, park etmeden önce her turda), çıkış iş parçacığı `outError`'u yazınca `queue.nudge()` ile park edeni uyandırır. Kayıp uyanma yok: `outError` ve `waiter` volatile, bekleyen `waiter`'ı yayınlayıp sonra `abort`'u kontrol eder; hata yazan `outError`'u yazıp sonra `waiter`'ı okur (VsyncIdle'daki gibi karşılıklı yazma/okuma).
- Çıkış: kuyruğa verilmiş ve çıkışı alınmamış kare yok (`InFlightGauge.current()==0`) ve tutulan tampon yok (`untilDeadlineNs==null`) ise `dequeueOutputBuffer` 50 ms (`EVENT_OUTPUT_IDLE_WAIT_US`) bekler. Bu bir zaman aşımıdır, çünkü durdurmayı uyandıracak başka yol yok; açıkça: durdurma gecikmesi en çok +50 ms (bugün 5-20 ms). Çıkış hazır olunca `dequeue` yine hemen döner (kare gecikmesi aynı). Kare uçuştayken ya da tampon tutulurken bugünkü 5 ms (ve `IdleWait`) kalır. Sayaç yanlış >0 kalırsa (codec girişi yuttuysa) davranış bugünküne düşer, güvenli yön.
- Saf mantık (`DecoderWait`, `DecoderWaits.inputWaitNs/outputWaitUs`) `VsyncIdle.kt`'de, JVM testli. `VideoRenderer.decoderWait` `@Volatile var` (her turda okunur), `catchUp` bilgisi gibi MainActivity'den bağlanır.

**Testler:** (1) kare yokken `awaitNext` uzun bekler, `offer` ile uyanır (gecikme < 20 ms); (2) `abort` + `nudge` ile uyanır, kayıp uyanma yarışı (VsyncIdle stili, yüzlerce tekrar); (3) `DecoderWaits` politika tablosu; (4) FakeDecoderCodec ile `VideoRenderer` event kipinde: kare akışı, detach, reconfigure, çıkış hatası (decode_error) sonrası iş parçacığı kalmaması (`decoderThreadsFinished`), poll kipiyle aynı sonuç; (5) `DevKnobs` `dec_wait`.

**Kapsam notu:** kapı `DevKnobs.kt` + `MainActivity.kt` + `DevKnobsTest.kt` dosyalarına dokunuyor (kartın `files:` listesinde yok). Orkestratörün "mevcut ayar deseni" talimatı bunu gerektiriyor; en küçük değişiklik (bir alan, bir `Spec`, bir satır) yapılır, Open questions'ta işaretlenir.

## Handoff

Commit: bkz. `git log task/T-286-decoder-loop-wakeups` (kod commit'i "T-286: event-driven decoder waits behind dec_wait knob"; plan commit'i 918ea048).

**Dosyalar:** `video/VsyncIdle.kt` (`DecoderWait`, `DecoderWaits`), `video/FrameQueue.kt` (`awaitNext(abort=)`, `nudge()`), `video/VideoRenderer.kt` (`decoderWait`, iki döngü), test `video/DecoderWaitTest.kt` (yeni), `video/FakeDecoderCodec.kt` (`longOutputWaits`). Kapı için kapsam dışı üç dosya (Open questions 1): `session/DevKnobs.kt`, `MainActivity.kt` (tek satır), `session/DevKnobsTest.kt`. `InputBufferSlot.kt` değişmedi (gerek yok).

**Ayar (varsayılan kapalı = bugünkü kod yolu):** `--ez dev true --es dec_wait event` (A: `--es dec_wait poll` ya da hiç verme). `ev=profile` satırının `knobs=` alanında `dec_wait:event` görünür. `VideoRenderer.decoderWait` her döngü turunda okunur (çalışırken değişebilir; MainActivity yalnız açılışta atar).

**Davranış (event kipi):**
- Giriş (`mb-decoder`): kare yokken `awaitNext` 250 ms'lik sigorta ile park eder (`EVENT_INPUT_WAIT_NS`); `offer`, retire/revoke ve yeni `abort` (`!att.active || outError != null`) + `queue.nudge()` hepsi anında uyandırır. Bugünkü 4 ms/20 ms yok.
- Çıkış (`mb-decoder-out`): codec içinde kare yok (`InFlightGauge.current()==0`) ve tutulan tampon yok ise `dequeueOutputBuffer` 50 ms bekler (`EVENT_OUTPUT_IDLE_WAIT_US`); aksi halde bugünkü 5 ms/`IdleWait`. **Başka uyarı yolu yok**: durdurmayı bir bekleyen `dequeueOutputBuffer`'a ileten yol olmadığı için zaman aşımı kalır; durdurma gecikmesi en çok +50 ms (bugün 5–20 ms). Çıkış hazır olunca `dequeue` yine anında döner, kare gecikmesi aynı.
- Kalan sigorta bedeli: giriş ~4 uyanma/s, çıkış ~20 uyanma/s (boşta). Beklenen 10 fps'te: `mb-decoder` ~265 → ~5 (kare aralarında), `mb-decoder-out` ~246 → ~20-60, `MediaCodec_loop` orantılı düşer (her sync `dequeueOutputBuffer` zaman aşımı looper'da 2 uyanma) [Tahmin].
- 60 fps'te kare uçuştayken çıkış iş parçacığı 5 ms poll'da kalır; kazanç küçük olur (orkestratör ölçer).

**Tablette kontrol (orkestratör, tek seferde A/B):** aynı Mac senaryosu (10 fps arka plan, sonra Oyun 60), A = `dec_wait` yok, B = `--ez dev true --es dec_wait event`.
1. `/proc/<pid>/task/*/status` gönüllü bağlam değişimi/s: `mb-decoder`, `mb-decoder-out`, `MediaCodec_loop`, `CodecLooper` (T-282 yöntemi). Hedef 10 fps'te üçünün toplamı ≥500/s düşer.
2. `MB/render ev=stats`: `cap_dec_p50_us`, `cap_dec_p95_us`, `cap_dec_p99_us` (eski `latency_us`/`latency_ms` de), kötüleşme ±1 ms. Çözme süresi için `MB/decoder ev=stats`; `ready_slot_*`, `skip_pct`, `cb_skip_pct` aynı kalmalı.
3. Bozulma işareti: `MB/decoder` altında `decode_error`, `output_straggler`, `detach_slow`, `decoder_previous_stuck` satırı çıkmamalı; Oyun'a/Günlüğe geçişte (reconfigure) ve ekran kapat/aç sonrası akış normal dönmeli; soğuk başlangıçta ilk kare gecikmesi artmamalı.
4. Durdurma yolu (ekranı kapat/aç, mod geçişi) en çok +50 ms yavaşlayabilir; `detach_slow` görmemek yeterli.
Kötüleşirse kart geri alınır (varsayılan zaten `poll`).

**Varsayımlar:** `InFlightGauge` sayacı yanlışlıkla >0 kalırsa (codec girişi yutarsa) çıkış döngüsü bugünkü poll'a düşer: güvenli yön. Giriş sigortası 250 ms: bilinmeyen bir kayıp uyanma, takılma yerine ≤250 ms gecikme olarak görünür. `mb-video`/ağ iş parçacıkları ve `held != null` (codec girişi dolu, `dequeueInputBuffer(4 ms)`) yolu değişmedi.

**Test edilmedi (tablet gerekir):** gerçek MediaCodec'te `dequeueOutputBuffer(50 ms)` davranışı, gerçek uyanma sayıları, 60 fps'te kazanç, HiSilicon decoder'ın boşta uzun `dequeue`'ye tepkisi.

**Birim testler:** `DecoderWaitTest` (politika tablosu; `abort`+`nudge` ve 400 turluk kayıp uyanma yarışı; uzun parkta `offer`/revoke; sahte codec ile event kipinde boşta uyanma sayısı sınırlı ve poll'dan az; uzun boşluktan sonra kare <100 ms'de girer; seyrek akış sırayla çözülür/gösterilir; kip çalışırken değişir; detach, reconfigure ve çıkış hatası park halindeki iş parçacığını anında bitirir). `DevKnobsTest` `dec_wait`. `./scripts/check.sh`: ALL OK.

### Ek: `event_in` (üçüncü kip, dal `task/T-286-event-in`)

Neden: cihaz A/B'sinde (NOTES 2026-10-07 ~00:30–01:05) `event` uyanmayı ~955 → ~300/s ve istemci CPU'sunu ~%6 düşürdü, ama `cap_dec_p50` +1,6 ms, p95 +2,5 ms (kart sınırı ±1 ms), `dec_p50` aynı. Şüphe: çıkıştaki 50 ms'lik `dequeueOutputBuffer` beklemesi (InFlightGauge 0 iken) HiSilicon codec'te kare kuyruğa girince hemen uyanmıyor.

**Ayar:** `--ez dev true --es dec_wait event_in` (`poll` varsayılan kalır, `event` olduğu gibi). `ev=profile knobs=` içinde `dec_wait:event_in`.
- Giriş (`mb-decoder`): `event` ile aynı: 250 ms sigortalı park, `offer`/retire/hata-`nudge` ile anında uyanma.
- Çıkış (`mb-decoder-out`): bugünkü `poll` gibi (5 ms + `IdleWait`; kare uçuşta olsun olmasın, tutulan tampon son tarihi aynı), 50 ms boşta beklemesi yok.
- Kod: `DecoderWait` artık `parksInput` / `longOutputIdle` özellikleri taşıyor (`POLL` false/false, `EVENT` true/true, `EVENT_IN` true/false); `VideoRenderer` iki döngüde kip yerine bu özelliklere bakıyor (`event` ve `poll` davranışı bayt bayt aynı). Durdurma gecikmesi `poll` ile aynı (5–20 ms): `event`'teki +50 ms yok.
- **Beklenen uyanma azalması (10 fps, tahmin):** `mb-decoder` ~265 → ~5/s (giriş park), `mb-decoder-out` ~246/s kalır (poll), `MediaCodec_loop` ~453/s kalır; üç iş parçacığı toplamı ~955 → ~700/s (~-250/s), yani `event`in kazancının yaklaşık dörtte biri/üçte biri; CPU kazancı da orantılı küçük (~%2–3 tek çekirdek). Kart hedefi (≥500/s) bu kipte tutmaz; amaç `cap_dec` +1,6 ms'in kaynağının çıkış beklemesi mi giriş parkı mı olduğunu ayırmak.
- **Orkestratör A/B:** aynı senaryoda üç kol (`poll`, `event`, `event_in`): üç iş parçacığı uyanma/s ve `cap_dec_p50/p95` + `dec_p50`. Yorum: `event_in` `cap_dec` ±1 ms içindeyse sorun çıkış 50 ms'indeydi (o halde varsayılan adayı `event_in`, ek kazanç için çıkış bekleme süresi ara değerle denenebilir); `event_in` de +1,6 ms ise sebep giriş parkı (park/unpark gecikmesi), `event` ailesi bırakılır.
- Testler: `DecoderWaitTest` (parse, `event_in` politika tablosu = çıkışta `poll` ile eş, boşta giriş uyanması az ve 50 ms'lik çıkış bekleme yok, uzun boşluktan sonra kare anında girer, detach/reconfigure/çıkış hatası park halindeki girişi anında bitirir), `DevKnobsTest` (`dec_wait event_in`, dev yokken yok sayılır). `./scripts/check.sh`: ALL OK.
- Kapsam dışı dosya yok (bu dalda `files:` dışına yalnız `DevKnobs.kt` dokunuldu; T-286'daki aynı gerekçe, Open questions 1). `docs/KNOBS.md` 23e satırı orkestratörde: `poll/event` → `poll/event/event_in` güncellenmeli.

## Open questions

1. **Kapsam genişlemesi (onay gerekir):** "mevcut ayar deseni" `DevKnobs.kt` (alan + `Spec`), `MainActivity.kt` (`it.decoderWait = devKnobs.decoderWait`, tek satır) ve `DevKnobsTest.kt` dosyalarını gerektiriyor; kartın `files:` listesinde yoklar. Orkestratörün açık talimatıyla en küçük değişiklik yapıldı. İstenmezse bu üç dosya geri alınır ve ayar yalnız `VideoRenderer.decoderWait` olarak kalır (cihazda tetiklenemez).
2. **`docs/KNOBS.md` satırı (orkestratör ekler, kart dışı):** 23e `--es dec_wait poll|event`; varsayılan yok = `poll` (bugünkü 4/5 ms + `IdleWait`); `event` = girişte park (250 ms sigorta; `offer`/retire/hata `nudge` ile anında), çıkışta codec içinde kare yokken 50 ms; kod: `DevKnobs.kt` (`decoderWait`), `VideoRenderer.decoderWait`, `video/VsyncIdle.kt` (`DecoderWaits`); kart T-286; sınıf yalnızca geliştirici; A/B sonucuna göre benimsenir (varsayılan `event`, `poll` kalkar) ya da silinir.
3. **`docs/LOGGING.md`:** değişmedi (yeni log alanı yok; yalnız `ev=profile knobs=` listesinde `dec_wait:event`).
4. Not (kapsam dışı): `FrameQueue.awaitNext` iş parçacığı kesilmişse (interrupt bayrağı) hemen null döner ve giriş döngüsü dönerek bekler (T-112 notu). Şu an hiçbir yer kesmiyor; dokunulmadı.
