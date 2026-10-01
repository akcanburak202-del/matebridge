---
id: T-077
title: Tablet — alımdan çözücüye verme gecikmesi (kuyruk→giriş p50 1,16 / p95 2,7 ms; küçük kayıtta 0,6 ms şifre çözme)
status: review
phase: 5
owner: android-client-dev
depends_on: [T-076]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/Records.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/FrameDecoder.kt
  - client-android/app/src/test/
  - backlog/tasks/T-077-client-input-path-latency.md
---

## Amaç

İz (`trace6.csv`, 2026-10-01 ~13:40, 60 fps, USB): `recv→decrypted` p50 0,62 / p95 1,19 ms (kareler ~3 KB), `decrypted→queued` 0,05 ms, **`queued→input` p50 1,16 / p95 2,72 / p99 3,51 ms**, çözme p50 8,7 ms. Kuyruktan `queueInputBuffer`'a geçiş `FrameQueue.poll(4)` (`wait/notifyAll`) + `dequeueInputBuffer(4_000)` + kopya. Hedef: bu yolu ≤ 0,3 ms p95'e indirmek; küçük kayıtlarda sabit şifre çözme maliyetini azaltmak.

## Kabul kriterleri

- [ ] Ölç ve ayrıştır (iz sütunu eklemek serbest): uyanma gecikmesi mi, `dequeueInputBuffer` beklemesi mi (giriş tamponu yok), kopya mı.
- [ ] Giriş tamponu bekleme sebebi ise: boşta bir giriş tamponunu önceden al (pre-dequeue) ya da `MediaCodec` asenkron geri çağrı modunda boş giriş indekslerini tut; kare gelince hemen doldur. Uyanma sebebi ise: daha doğrudan devir (ör. ağ iş parçacığı karar verir, giriş iş parçacığı `LockSupport.unpark`), gereksiz zaman aşımlı beklemeleri kaldır. Davranış (sınırlı kuyruk, en yeni kazanır, keyframe kapısı, yapılandırma yeniden oynatma, hata yeniden başlatma) **aynı** kalır.
- [ ] Küçük kayıtta 0,6 ms şifre çözme: nedenini ölç (`cipher.init` + `GCMParameterSpec` tahsisi, JNI geçişleri, ayrıştırma). Güvenli bir iyileştirme varsa yap (tel biçimi ve kripto aynı; fixture/crypto vector testleri geçer); yoksa karta yaz.
- [ ] İz (T-069/T-073) çalışmaya devam eder. `./scripts/check.sh` geçiyor.

## Plan

1. **Ölçüm (iz sütunları, sona eklenir):** `open_start_ns, open_init_ns, open_final_ns` (RecordOpener: başlangıç, `cipher.init`+AAD sonrası, `doFinal` sonrası; iz açıkken iş parçacığı-yerel damga, `PaceTrace.onRecv` okur), `taken_ns` (giriş iş parçacığı kareyi kuyruktan aldı = uyanma), `inbuf_ns` (giriş tamponu indeksi elde), `copied_ns` (kopya bitti), `inbuf_pre` (indeks önceden alınmış mıydı). `input_ns` = `queueInputBuffer` dönüşü (aynı).
2. **Uyanma:** `FrameQueue.awaitNext(timeoutNs)`: `wait/notifyAll` yerine `LockSupport.park/unpark` (bekleyen iş parçacığı kayıtlı, `offer` kilidi bıraktıktan sonra `unpark`; kayıp uyanma yok). Kuyruk kuralları aynı; `poll()` testler için kalır. Giriş iş parçacığı `THREAD_PRIORITY_DISPLAY`.
3. **Giriş tamponu:** `InputBufferSlot` (saf Kotlin): döngü başında `dequeueInputBuffer(0)` ile boş indeks önceden alınır (kare beklenirken), kare gelince doğrudan kullanılır; yoksa eskisi gibi 4 ms zaman aşımlı dequeue.
4. **Küçük kayıt şifre çözme:** ~~sabit SPI'li `Cipher` alt sınıfı~~ (inceleme sonrası kaldırıldı, aşağıda). Kalan: `RecordDecoder.next` bir kopya az; iz ve `crypto_bench` ile `init` / `doFinal` ayrımı cihazda ölçülür.
5. Testler: `awaitNext` (anında/uyanma/zaman aşımı/kayıp uyanma yok), `InputBufferSlot`, kayıt açma yolu + damgalar, iz sütunları. `./scripts/check.sh`.

## Handoff

- **Commit:** `ef8dbd7` (ilk uygulama) + `{FIX}` (inceleme düzeltmesi: sabit SPI yolu kaldırıldı); plan `091c966`; dal `task/T-077-client-input-path`.
- **Dokunulan dosyalar:** `security/Records.kt`, `video/FrameQueue.kt`, `video/PaceTrace.kt`, `video/VideoRenderer.kt`, `video/InputBufferSlot.kt` (yeni), `test/.../video/PaceTraceTest.kt`, `test/.../video/InputHandoffTest.kt` (yeni), `test/.../security/RecordOpenTest.kt` (yeni), bu kart. `FrameDecoder.kt` değişmedi (şifreli bağlantıda kullanılmıyor).
- **Ne değişti / neden:**
  - *Uyanma:* `FrameQueue.awaitNext(ns)` — `wait/notifyAll` (uyanan iş parçacığı hemen bildirenin tuttuğu monitöre takılabilir) yerine `LockSupport.park/unpark`, `unpark` kilit bırakıldıktan sonra. Kuyruk kuralları (sınır 2, en yeni kazanır, keyframe kapısı, config tekrarı, reset) aynı; `poll()` duruyor (testler).
  - *Giriş tamponu:* `InputBufferSlot` döngü başında `dequeueInputBuffer(0)` ile boş indeksi kare beklenirken alır; senkron modda her `dequeueInputBuffer` codec looper'ına bir gidiş-dönüştür, artık karenin yolunda değil. Boş tampon yoksa eskisi gibi 4 ms zaman aşımlı dequeue. Giriş iş parçacığı `THREAD_PRIORITY_DISPLAY` (çıkış iş parçacığı değişmedi).
  - *Şifre çözme:* `newCipher()` T-076'daki gibi (`AndroidOpenSSL`, yoksa varsayılan). `RecordDecoder.next` artık opener çıktısından doğrudan payload kopyalar (bir kopya az; `openPlain`). Tel biçimi/kripto aynı; fixture + crypto vector testleri geçti.
  - *İz sütunları (sona eklendi, toplam 37):* `open_start_ns, open_init_ns, open_final_ns` (kayıt açma: başlangıç / `init`+AAD / `doFinal`; iş parçacığı-yerel, kontrol bağlantısı karışmaz), `taken_ns` (giriş iş parçacığı kareyi kuyruktan aldı), `inbuf_ns` (indeks elde), `copied_ns` (kopya bitti), `inbuf_pre` (1 = önceden alınmış indeks). `input_ns` hâlâ `queueInputBuffer` dönüşü. Ayrıştırma: uyanma = `taken − queued`, tampon = `inbuf − taken`, kopya = `copied − inbuf`, `queueInputBuffer` = `input − copied`; şifre çözme: `open_init − open_start` (init), `open_final − open_init` (GCM), `decrypted − open_final` (ayrıştırma/kopya), `open_start − recv` (besleme/başlık).
  - `crypto_bench`: 3 KB eklendi; her sağlayıcı ve boyut için `<n>k_init_p50_us` / `<n>k_final_p50_us`.
- **İnceleme bulgusu ve karar (Codex high, P2, Records.kt):** İlk sürümdeki "sabit SPI" şifresi (korumalı `Cipher(CipherSpi, Provider, String)` kurucusu) Android'de `specifiedSpi` ayarlıyor; libcore `Cipher.init` bu durumda SPI'yi `engineInit` çağırmadan döndürüyor → anahtar/nonce hiç ayarlanmaz. AndroidOpenSSL'de öz test başarısız olup hep standart yola düşecekti: kazanç yok, yalnız karmaşıklık; JVM (SunJCE) testleri bunu yakalayamıyor. **Karar (orkestratör):** sabit SPI yolu, öz test ve `mode=direct|standard` tamamen kaldırıldı. Bir-kopya-az, giriş yolu değişiklikleri, iz sütunları (init/final ayrımı dahil) ve bench init/final ayrımı kaldı. `Cipher.init` maliyeti cihazda iz (`open_init − open_start`) ve `crypto_bench` (`3k_init_p50_us`) ile ölçülecek; büyükse ayrı kartta güvenli bir yol aranır.
- **Varsayımlar:** Hedef ≤ 0,3 ms p95 cihazda ölçülmedi. `THREAD_PRIORITY_DISPLAY` yalnız `mb-decoder` (giriş) iş parçacığında. Ağ (video bağlantı) iş parçacığının önceliği değişmedi (`SessionController` kapsam dışı). `Codec.decodePayload` VIDEO_FRAME verisini bir kez daha kopyalıyor (Codec.kt kapsam dışı) — 3 KB'de ihmal edilebilir.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  1. `am start ... --ez crypto_bench true` → `MB/session ev=crypto_bench provider=AndroidOpenSSL ...` satırında `3k_init_p50_us` ve `3k_final_p50_us` (küçük kayıtta sabit maliyetin init'te mi olduğunu gösterir); `432k_mbps` ~700+ kalmalı.
  2. trace6 koşullarında (60 fps, USB, `--ez pace_trace true`, ~90 sn) iz çek: `adb exec-out run-as dev.matebridge.client cat cache/pace_trace.csv > trace7.csv`; 37 sütun; `input_ns − queued_ns` p50/p95 (önce 1,16 / 2,72 ms) ve `decrypted_ns − recv_ns` (önce 0,62 ms p50); `inbuf_pre` çoğunlukla 1 olmalı; yukarıdaki ayrıştırmayla kalan maliyet nerede.
  3. Akış normal: görüntü donmuyor, keyframe isteği/yeniden başlatma (yüzey arka plan/ön plan) eskisi gibi; kalem/klavye çalışıyor.
- **Açık sorular:** Kalan pay `queueInputBuffer` (senkron modda looper gidiş-dönüşü) ise sonraki adım `MediaCodec` asenkron mod olabilir (çıkış iş parçacığı da yeniden yazılır; ayrı kart). `Cipher.init` cihazda büyük çıkarsa güvenli alternatif ayrı kartta. Ağ iş parçacığı önceliği (`SessionController`) ayrı kartta denenebilir.
