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

## Open questions
