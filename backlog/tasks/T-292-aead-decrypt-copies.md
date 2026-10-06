---
id: T-292
title: İstemci — video kaydı şifre çözmede Conscrypt kopyalarını ve kayıt başına SPI yeniden kurulumunu azalt
status: done
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

1. **SPI yeniden kurulumu (%11) önlenemiyor (b: HAYIR, güvenli bir yolla).** `Cipher.init` her çağrıda `tryCombinations` çalıştırır
   ve yeni `OpenSSLAeadCipherAES$GCM` oluşturur; `Cipher.getInstance(T, Provider)` bunu önlemez. İlk sürümde korumalı
   `Cipher(CipherSpi, Provider, String)` yapıcısıyla sabit SPI denendi, **ama bu yanlıştı**: `specifiedSpi != null` iken
   `updateAndGetSpiAndProvider` `engineInit`'i hiç çağırmadan SPI'yı döner, yani anahtar/mod/nonce Conscrypt'e hiç verilmez ve ilk
   kayıt `IllegalStateException("Cipher not initialized")` atar (codex incelemesi P1, SDK kaynağıyla doğrulandı; SunJCE JVM testleri
   bunu yakalayamaz). `spi` modu tamamen kaldırıldı. `CipherSpi.engineInit` yansıtması **yapılmayacak**; SPI yeniden
   kurulum maliyeti (`mb-video`'nun ~%11'i, ≈tek çekirdeğin %1,6'sı) kabul edildi.
2. **Girdi kopyası (`updateInternal`/`expand`, %12,5) (a: EVET, kaldırılabilir).** `doFinal(byte[]...)` girdiyi SPI'nın iç `buf`'ına
   kopyalar, JNI bir kez daha kopyalayabilir, ve `reset()` kayıt boyutu değişince `buf = new byte[bufCount]` ayırır.
   `OpenSSLAeadCipher.engineDoFinal(ByteBuffer, ByteBuffer)` (`ENABLE_BYTEBUFFER_OPTIMIZATIONS = true`), `bufCount == 0` ve iki
   tampon direct ise doğrudan `EVP_AEAD_CTX_open_buf`'a gider: iç tampon, kopya ve ayırma yok. Heap tamponda daha kötü
   (geçici direct tampon), bu yüzden tamponlar direct.

Uygulama (`Records.kt`), `enum AeadPath` ile çalışma zamanında seçilir (varsayılan **legacy** = bugünkü davranış, karar 0026 §2):
- `legacy`: bugünkü `Records.newCipher()` + `doFinal(byte[])`.
- `direct`: aynı `Records.newCipher()`, her kayıtta bugünkü gibi `init` + `updateAAD`; çözme `doFinal(ByteBuffer, ByteBuffer)` ile
  yeniden kullanılan direct girdi/çıktı tamponları üzerinde. Girdi bir kez direct tampona (`ByteBuffer.put`), düz metin bir kez
  `scratch`'e kopyalanır (Codec `ByteArray` bekliyor, `Codec.kt` kapsam dışı).
- Dayanıklılık (codex P1 dersi): `openPlain` içinde sağlayıcıdan gelen beklenmedik `RuntimeException` (örn. `IllegalStateException`,
  `ReadOnlyBufferException`) da `GeneralSecurityException` ile aynı yoldan `ProtocolException(AUTH_FAILED)` olur; okuma iş
  parçacığından kaçıp oturum temizliğini atlayamaz. Mesaj sabit, sağlayıcı metni dışarı çıkmaz. Bu iki yolun ikisi ve
  `RecordOpener` kullanan her bağlantı (kontrol bağlantısı dahil) için geçerli.
Şifreleme biçimi, nonce, AAD, sayaç ve `AEADBadTagException` davranışı aynı. `RecordSealer` dokunulmadı.

Bayrak: `--ez dev true --es aead_path legacy|direct` (`DevKnobs`, `ev=profile knobs=` alanında `aead_path:<id>`). `Records.aeadPath`
açılışta `MainActivity.parseDevKnobs` ile set edilir; `RecordOpener` oluşturulurken (bağlantı başına) okunur.

Testler: `RecordAeadPathTest` (iki yol aynı kayıtları açar, bozulmuş gövde/etiket/AAD/sayaç/kısa kayıt aynı hatayı verir, sayaç yalnız
başarıda ilerler, `startCounter`, `openAt` ofsetleri, decoder çıktısı eşit; **`init`/`aad`/`final` aşamasında `IllegalStateException`
atan şifre kuklasıyla** iki yol da AUTH_FAILED verir ve decoder terminal kalır), `AeadDecryptBenchTest` (JVM ayırma/verim),
`DevKnobsTest` (yeni anahtar).

## Handoff

- Commit: ilk uygulama `a0ce35df`; P1 düzeltmesi (spi kaldırıldı, direct korundu, RuntimeException yolu) bu kartı güncelleyen
  commit'te (`git log task/T-292-aead-decrypt-copies`). Dal `task/T-292-aead-decrypt-copies`.
- `./scripts/check.sh`: ALL OK.
- Dokunulan dosyalar: `client-android/.../security/Records.kt`; yeni testler `.../security/RecordAeadPathTest.kt`,
  `.../bench/AeadDecryptBenchTest.kt`; knob bağlantısı `.../session/DevKnobs.kt`, `.../session/DevKnobsTest.kt`,
  `.../MainActivity.kt` (tek satır). Son üçü kartın ilk `files:` listesinde yoktu; orkestratörün "mevcut knob kalıbını izle"
  talimatı bunları gerektirdiği için eklendi ve listeye yazıldı.
- Cihazda A/B: yalnız iki değer.
  - A (taban): bayraksız ya da `--ez dev true --es aead_path legacy`.
  - B: `--ez dev true --es aead_path direct`.
  - Doğrulama: `ev=profile ... knobs=...aead_path:direct`. Bayrak her açılışta verilmeli; bir sonraki bağlantıdan itibaren geçerli.
    Eski `spi` değeri artık tanınmaz (`legacy`'ye düşer, `knobs=` içinde `aead_path:other`).
- Ölçülmedi: Conscrypt'e özgü her şey. JVM testi SunJCE kullanır: orada `direct` biraz yavaş ve kayıt başı ~1,6 KB fazla ayırıyor
  (SunJCE direct tamponu iç heap dizisine kopyalar); Conscrypt'te tersi beklenir. Kabul 3 (GC ≤ %6, minor fault ≤ 2 500/s,
  `mb-video` ≤ %10) cihaz ölçümü orkestratörde. SPI yeniden kurulum payı (`Cipher.init`, ~%11) bilerek kalıyor: hedef değerlere
  yalnız `direct` ile ulaşılırsa yeter, ulaşılmazsa kart "değmez" ya da yeni bir kart.
- Cihazda bakılacaklar: (1) iki yolda da görüntü/giriş normal, `AUTH_FAILED`/bağlantı kopması yok (özellikle ilk kayıt: direct yolun
  Conscrypt'te gerçekten çalıştığının kanıtı); (2) `HeapTaskDaemon`, minor fault/s, `mb-video` içindeki `updateInternal`/`expand` payı
  ve LOS ayırmaları; (3) `latency_ms`/`decode_ms` değişmemeli.
- Güvenlik: kripto biçimi/nonce/AAD aynı; `RecordSealer` dokunulmadı. Güvenlik koduna dokunduğu için codex incelemesi (tekrar) önerilir,
  özellikle `doFinalDirect` tampon yaşam döngüsü ve yeni `RuntimeException` yakalama.

## Handoff — varsayılan `direct` (takip, dal `task/T-292-direct-default`)

Cihaz A/B geçti (docs/NOTES.md, "2026-10-07 ~00:30–01:05"). Oyun 60, `aead_path=direct`: GC %11,2 -> %2,8; minor fault 5 038 -> 2 362/s;
AUTH_FAILED yok; gecikme 3 kolda da değişmedi (10 fps). Karar: `direct` benimsendi.
- `AeadPath.DEFAULT = DIRECT`; `Records.aeadPath`, `DevKnobs.aeadPath` ve `AeadPath.parse` (yok/bilinmeyen) bunu kullanır.
- `legacy` `--es aead_path legacy` ile bir döngü boyunca geri dönüş olarak seçilebilir; kod yorumunda "daha sonra kaldırılacak" yazar.
- Güncellenen testler: `RecordAeadPathTest` (varsayılan DIRECT, `legacy` ayrıştırma, opener), `DevKnobsTest` (varsayılan DIRECT, `legacy` knob).
- Cihazda bakılacak: bayraksız açılışta `ev=profile` `knobs=` içinde `aead_path` yok ama video/giriş normal (varsayılan artık direct); `--ez dev true --es aead_path legacy` ile `aead_path:legacy`.
- `docs/KNOBS.md` satırı 23f hâlâ "yok = legacy" diyor (dosya kapsam dışı): orkestratör "yok = `direct`; `legacy` geri dönüş, sonra kaldırılacak" olarak güncellemeli.

## Open questions

- `docs/KNOBS.md` girdisi eklenmedi (dosya kapsam dışı; kural 0026 §2 "aynı commit'te" diyor). Önerilen satır:
  `--es aead_path legacy|direct` (varsayılan `legacy`; yalnızca geliştirici; T-292; `DevKnobs.kt`, `Records.kt`); benimsenince ya da
  "değmez" çıkınca silinir. `ev=profile knobs=` alanında `aead_path:<id>`.
- `RecordDecoder.feed` girdiyi `ByteArray` tamponuna kopyalıyor; `direct` yolu bunu bir kez daha direct tampona kopyalıyor.
  `direct` kazanırsa sonraki adım: decoder tamponunu doğrudan direct yapmak ve `Codec`'in `ByteBuffer`'dan okuması (`Codec.kt` kapsam dışı).
- `openPlain` artık tüm `RuntimeException`'ları AUTH_FAILED'a çeviriyor: bir programlama hatası (örn. dizin dışı) da "kimlik doğrulama"
  hatası gibi görünür. Ayrım gerekirse ayrı bir `ProtocolException.Kind` protokol sahibinin (orkestratör) işi.
