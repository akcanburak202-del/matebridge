---
id: T-286
title: İstemci — çözücü döngülerinde sabit 4/5 ms yoklama yerine olaya bağlı uyanma (10 fps'te ~950 uyanma/s)
status: todo
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

## Open questions
