---
id: T-292
title: İstemci — video kaydı şifre çözmede Conscrypt kopyalarını ve kayıt başına SPI yeniden kurulumunu azalt
status: review
phase: 6
owner: android-client-dev
depends_on: [T-285]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/Records.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/security/
  - client-android/app/src/test/kotlin/dev/matebridge/client/bench/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt            # knob wiring (orkestratör talimatı: mevcut knob kalıbı)
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/DevKnobsTest.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt                # tek satır: Records.aeadPath = devKnobs.aeadPath
  - backlog/tasks/T-292-aead-decrypt-copies.md
---

## Amaç

T-285 cihaz ölçümü (kart Handoff'u, 2026-10-06): Oyun 60'ta GC hâlâ %12,8, 5 066 minor fault/s, `mb-video` %15. `openPlain` iş parçacığının %43'ü. Dağılım:
- `Cipher.init` her kayıtta sağlayıcı seçimini yeniden yapıyor ve yeni `OpenSSLAeadCipherAES$GCM` oluşturuyor: %11;
- Conscrypt AEAD şifre çözmede girdiyi iç tamponuna kopyalıyor (`updateInternal` %12,5, `expand`);
- `doFinalInternal` %19.

Hedef, kare başına bu kopyaları ve ayırmaları kaldırmak. Protokol ve şifreleme biçimi değişmez (AES-256-GCM, aynı nonce/AAD).

## Kabul

1. Önce cihazda küçük bir deney (`bench` ya da `androidTest` olmadan, uygulama içi geliştirici bayrağıyla ya da ayrı bir JVM kıyaslamasıyla), ve sonucu Plan'a yazılır:
   - (a) doğrudan `ByteBuffer`'larla `cipher.doFinal(ByteBuffer, ByteBuffer)` Conscrypt'te kopyasız yolu kullanıyor mu (API 31 platform Conscrypt'i);
   - (b) `Cipher.getInstance(TRANSFORMATION, Provider nesnesi)` ya da başka bir yol, kayıt başına SPI yeniden oluşturmayı önlüyor mu.
2. Ölçülen kazanç varsa uygulanır. Kimlik doğrulama hatası (`AEADBadTagException`) ve sayaç/nonce davranışı aynı kalır. Mevcut `security` testleri ve crypto vektörleri geçer.
3. Cihaz ölçümü (orkestratör, Oyun 60): GC ≤ %6, minor fault/s ≤ 2 500, `mb-video` ≤ %10. Gecikme değişmez.
4. Deney kazanç göstermezse kart "değmez" diye kapanır, ölçüm yazılır.

## Plan

Kabul 1'in cihaz deneyi bu ajanda yapılamadı (tablete dokunmak yasak); yerine API 31 platform kaynağı okundu
(`android-12.0.0_r1`: `libcore/.../javax/crypto/Cipher.java`, `external/conscrypt/.../OpenSSLAeadCipher.java`, `OpenSSLCipher.java`).
Bulgular, T-285 profilindeki üç kalemi satır satır açıklıyor:

1. **SPI yeniden kurulumu (%11).** `Cipher.init(...)` her çağrıda `SpiAndProviderUpdater.updateAndGetSpiAndProvider(initParams, ...)`
   çalıştırır. `initParams != null` olduğundan kısa yol (`spiImpl != null && initParams == null`) devreye girmez; `tryCombinations`
   yeniden çalışır ve her seferinde yeni `OpenSSLAeadCipherAES$GCM` oluşturur. `Cipher.getInstance(T, Provider)` bunu ÖNLEMEZ
   (yalnız sağlayıcı aramasını daraltır, `specifiedProvider` olarak saklar). Önleyen tek genel API yolu: korumalı
   `Cipher(CipherSpi, Provider, String)` yapıcısı; o `specifiedSpi` set eder ve `init` hep aynı SPI'yı döner. SPI'yı
   `provider.getService("Cipher", "AES/GCM/NoPadding").newInstance(null)` ile bir kez alıyoruz (hepsi SDK'daki genel/korumalı API,
   yansıtma ya da gizli API yok). Yeni SPI'nın `reset()`'i ayrıca `lastGlobalMessageSize` (~kare boyutu) kadar bir `byte[]`
   ayırır: bu da her kayıttaki LOS ayırmalarından biri.
2. **Girdi kopyası (`updateInternal`/`expand`, %12,5).** `doFinal(byte[]...)` → `OpenSSLCipher.engineDoFinal` → `updateInternal`
   girdiyi SPI'nın iç `buf`'ına kopyalar (`expand` gerekirse büyütür), sonra JNI `EVP_AEAD_CTX_open` bunu bir kez daha
   kopyalayabilir. Üstüne `reset()` kayıt boyutu `lastGlobalMessageSize`'tan farklıysa `buf = new byte[bufCount]` ayırır
   (kare boyutları değiştiği için neredeyse her kayıtta).
3. **`doFinal(ByteBuffer, ByteBuffer)` (a): EVET, kopyasız yol var.** `OpenSSLAeadCipher.engineDoFinal(ByteBuffer, ByteBuffer)`
   `ENABLE_BYTEBUFFER_OPTIMIZATIONS = true` iken, `bufCount == 0` ve iki tampon da direct ise doğrudan
   `NativeCrypto.EVP_AEAD_CTX_open_buf`'a gider: iç tampon yok, kopya yok, ayırma yok. Heap tamponda geçici direct tampon
   ayırıp kopyalar (daha kötü), bu yüzden tamponlar direct olmalı. `init` `bufCount`'u sıfırladığı ve `updateAAD` onu
   değiştirmediği için `bufCount == 0` kalır.

Uygulama (`Records.kt`), `enum AeadPath` ile çalışma zamanında seçilir (varsayılan **legacy** = bugünkü davranış, karar 0026 §2):
- `legacy`: bugünkü `Cipher.getInstance` + `doFinal(byte[])`.
- `spi`: bağlantı ömrü boyunca tek SPI (`ReusableCipher`), `doFinal(byte[])`. (b) maddesinin cevabı bu.
- `direct`: `spi` + yeniden kullanılan direct girdi/çıktı tamponları, `doFinal(ByteBuffer, ByteBuffer)`. Girdi bir kez direct
  tampona kopyalanır (`ByteBuffer.put`, memcpy), düz metin bir kez `scratch`'e kopyalanır (Codec `ByteArray` bekliyor ve
  `Codec.kt` kapsam dışı). Bu yol Conscrypt'in iç `buf` kopyasını, JNI girdi/çıktı kopyalarını ve kayıt başı ayırmaları kaldırır.
`ReusableCipher` kurulamazsa (hizmet yok, örnekleme hatası) `newCipher()`'e düşer: yavaşlar, bozulmaz. İlk kullanımda
`crypto_provider provider=… spi_reused=0|1` loglanır.
Şifreleme biçimi, nonce, AAD, sayaç ve `AEADBadTagException` → `ProtocolException(AUTH_FAILED)` davranışı aynı. `RecordSealer`
dokunulmadı (kabloda yalnız küçük girdi olayları şifreliyor).

Bayrak: `--ez dev true --es aead_path legacy|spi|direct` (`DevKnobs`, `ev=profile knobs=` alanında `aead_path:<id>` görünür).
`Records.aeadPath` açılışta `MainActivity.parseDevKnobs` ile set edilir; `RecordOpener` oluşturulurken (bağlantı başına) okunur.

Testler: `RecordAeadPathTest` (üç yol aynı kayıtları açar, bozulmuş gövde/etiket/AAD/sayaç/kısa kayıt aynı hatayı verir, sayaç
yalnız başarıda ilerler, `startCounter`, `openAt` ofsetleri, `RecordDecoder` çıktısı eşit), `AeadDecryptBenchTest` (JVM ayırma/
verim, `RecordReceiveAllocTest` üslubunda), `DevKnobsTest` (yeni anahtar).

## Handoff

- Commit: `a0ce35df` (kod + Plan), bu kartın Handoff'u ayrı commit. Dal `task/T-292-aead-decrypt-copies`.
- `./scripts/check.sh`: ALL OK (host, android, probes, protocol).
- Dokunulan dosyalar: `client-android/.../security/Records.kt`; yeni testler `.../security/RecordAeadPathTest.kt`,
  `.../bench/AeadDecryptBenchTest.kt`; knob bağlantısı `.../session/DevKnobs.kt`, `.../session/DevKnobsTest.kt`,
  `.../MainActivity.kt` (tek satır). Son üçü kartın `files:` listesinde yoktu: orkestratörün "mevcut knob kalıbını izle"
  talimatı bunları gerektirdiği için eklendi ve listeye yazıldı. Gerekirse geri alınabilir (knob olmadan A/B yapılamaz).
- Cihazda bayrak: yalnız bu iki yol, geri kalan `legacy`.
  - A (taban): bayraksız ya da `--ez dev true --es aead_path legacy`.
  - B: `--ez dev true --es aead_path spi` (tek SPI, `byte[]` doFinal).
  - C: `--ez dev true --es aead_path direct` (tek SPI + direct tamponlar).
  - Doğrulama: logcat `crypto_provider provider=AndroidOpenSSL spi_reused=1` (spi_reused=0 ise yedek yola düştü, ölçüm
    geçersiz) ve `ev=profile ... knobs=...aead_path:direct`. Bayrak her açılışta verilmeli (Records.aeadPath süreç içinde
    açılışta set edilir; bir sonraki bağlantıdan itibaren geçerli).
- Varsayımlar: Android 12 Conscrypt kaynağı (`android-12.0.0_r1`) HarmonyOS 4.3'ün platform Conscrypt'iyle aynı davranıyor.
  HarmonyOS kendi Conscrypt sürümünü taşıyorsa (HMS/ArkCompiler) bulgular değişebilir: bu yüzden A/B şart.
- Ölçülmedi: Conscrypt'e özgü her şey (JVM testi SunJCE kullanır: orada `direct` yolu daha yavaş ve kayıt başı ~1,6 KB fazla
  ayırıyor, çünkü SunJCE direct tamponu iç heap dizisine kopyalar; Conscrypt'te tersi beklenir). Kabul 3 (GC ≤ %6, minor fault ≤ 2 500/s,
  `mb-video` ≤ %10) cihaz ölçümü orkestratörde: Oyun 60, aynı simpleperf yöntemi; iki bayrak değerini ayrı koş.
- Cihazda bakılacaklar: (1) üç yolda da görüntü/giriş normal, `AUTH_FAILED`/bağlantı kopması yok; (2) `HeapTaskDaemon`, minor fault/s, `mb-video`
  yolundaki `Cipher.init`/`updateInternal`/`expand` payları (spi: init ve SPI ayırma kaybolmalı; direct: ayrıca updateInternal/expand
  ve LOS ayırmaları kaybolmalı); (3) `latency_ms`/`decode_ms` değişmemeli. Kazanç yoksa Kabul 4: kart "değmez".
- Güvenlik: kripto biçimi/nonce/AAD aynı; `RecordSealer` dokunulmadı; log yalnız sağlayıcı adı ve 0/1. Güvenlik koduna dokunduğu için codex
  incelemesi önerilir (özellikle `doFinalDirect` tampon yaşam döngüsü).
- Kabul 2'ye ek: yeni yol seçilirse, sonraki adım varsayılanı değiştirmek (`Records.aeadPath` varsayılanı) ve `legacy`'yi silmek.

## Open questions

- `docs/KNOBS.md` girdisi eklenmedi (kural 0026 §2 "aynı commit'te güncelle" diyor, ama dosya bu kartın kapsamında değildi). Önerilen satır:
  `--es aead_path legacy|spi|direct` (varsayılan `legacy`; yalnızca geliştirici; T-292; `DevKnobs.kt`, `Records.kt`); benimsenince ya da
  "değmez" çıkınca silinir. `ev=profile knobs=` alanında `aead_path:<id>`.
- `docs/LOGGING.md`: `crypto_provider` olayına `spi_reused=0|1` alanı eklendi (yalnız `spi`/`direct` yollarında), belgelenmedi.
- `RecordDecoder.feed` girdiyi `ByteArray` tamponuna kopyalıyor; `direct` yolu bunu bir kez daha direct tampona kopyalıyor.
  Karar `direct` lehine çıkarsa sonraki adım: decoder'ın tamponunu doğrudan direct yapmak (tek kopya daha az) ve `Codec`'in
  `ByteBuffer`'dan okuması: `Codec.kt` kapsam dışı olduğu için yapılmadı.
- Ayrı konu (kapsam dışı): `worktree`te `client-android/local.properties` yok; `check.sh` onsuz Android'i atlamıyor mu diye bakmadım,
  ben `sdk.dir` ile (gitignore'lu) çalıştırdım.
