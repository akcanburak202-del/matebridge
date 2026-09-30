---
id: T-042
title: Tablet — protokol v1 şifreleme (el sıkışma, eşleşme kodu ekranı, AES-GCM kayıtları, Keystore)
status: done
phase: 4
owner: android-client-dev
depends_on: [T-038]
decisions: [0010]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-042-client-encryption.md
---

## Amaç

PROTOCOL.md v1 (§2, §3, §4 HELLO/HELLO_ACK/VIDEO_HELLO, **§9**) ve karar 0010. Protokol, fixture'lar ve kripto test vektörleri **`proto/crypto` dalında** (`5319fff`): kart dalı `main`'den açılır ve `proto/crypto` merge edilir. Host tarafı T-041 paralel yürür; ikisi birlikte merge edilir.

## Kabul kriterleri

- [ ] **Kodek:** HELLO (sürüm 1, `client_nonce`, `client_eph_pub`), HELLO_ACK (`key_mode`, `host_id`, `host_nonce`, `host_eph_pub`), VIDEO_HELLO (`video_nonce`). Bütün fixture testleri geçer.
- [ ] **Kripto çekirdeği** (saf Kotlin, yalnızca `java.security`/`javax.crypto`; yeni bağımlılık yok): geçici P-256 anahtar çifti (`KeyPairGenerator("EC")`, secp256r1), sıkıştırılmamış açık anahtar kodlama/çözme (geçersiz nokta → hata), ECDH (`KeyAgreement("ECDH")`), HKDF-SHA256 (`Mac("HmacSHA256")`), anahtar türetme, `sas`, `new_pair_key`, AES-256-GCM kayıtları (`Cipher("AES/GCM/NoPadding")`, 128 bit etiket, nonce = sayaç, AAD = uzunluk). **`crypto_vectors.json`'daki her değer** JVM birim testlerinde yeniden üretilir (sabit özel anahtarlar: ham skaler → `ECPrivateKeySpec`); bozulmuş kayıt reddedilir.
- [ ] **Çerçeveleme:** ilk HELLO_ACK'ten sonra kontrol bağlantısında, VIDEO_HELLO'dan sonra video bağlantısında şifreli kayıt okuma/yazma (sınır + 17). Doğrulama hatası → bağlantıyı kapat (BYE yok), mevcut yeniden bağlanma yolu çalışır. Tek sıralı gönderim (FIFO) korunur: sayaçlar gönderim sırasıyla artar.
- [ ] **Eşleşme:** `key_mode = PAIRING` ise "onay bekleniyor" ekranında 6 haneli kod büyük yazıyla ("Mac'teki kodla aynı mı?"); bu `host_id` için anahtar zaten varsa ek uyarı "Mac bu tableti tanımıyor, yeniden eşleşiliyor". Şifreli `HELLO_ACK(ACCEPTED)` gelince `host_id → new_pair_key` saklanır. `PAIRED` ama anahtar yoksa bağlantı kapanır ve "Mac'te 'Onaylı cihazları unut' deyip yeniden bağlan" gösterilir.
- [ ] **Saklama** (`security/`): eşleşme anahtarları Android Keystore'da üretilen dışa aktarılamaz AES-GCM anahtarıyla şifrelenip SharedPreferences'ta; Keystore erişimi tek bir sınıfta, testte sahte uygulama. Anahtarlar ve `sas` **loglanmaz**.
- [ ] `./scripts/check.sh` (T-041 ile birlikte) geçiyor. Kendi dalında Swift tarafı kırmızı olabilir; Gradle yeşil olmalı.

## Kapsam dışı

- Host (T-041). Cihaz testi orkestratörde.

## Plan

1. **Kodek** (`protocol/`): `Hello` (+`clientNonce`, `clientEphPub`), `HelloAck` (+`keyMode`, `hostId`, `hostNonce`, `hostEphPub`), `VideoHello` (+`videoNonce`); yeni alanlar varsayılanlı (mevcut testler derlenir). Yeni `ProtocolException.Kind.AUTH_FAILED`. Çerçevesiz/şifresiz ilk HELLO_ACK için tam-okuma yardımcısı (`readPlainFrame`).
2. **Kripto çekirdeği** (`security/`, saf `java.security`/`javax.crypto`): `Crypto` (P-256 geçici anahtar, sıkıştırılmamış kodlama/çözme + eğri üstü doğrulama, ECDH), `Hkdf`, `KeySchedule` (transcript_hash, prk, kontrol/video anahtarları, sas, new_pair_key), `RecordSealer`/`RecordOpener` (AES-256-GCM, nonce=sayaç, AAD=length), `RecordDecoder` (feed/next, sınır başlıkta denetlenir). `ClientHandshake`: HELLO kurar, ilk HELLO_ACK'i doğrular (key_mode/status matrisi, NONE'da PENDING/ACCEPTED = protokol hatası, PAIRED+anahtar yok = KeyMissing) ve anahtarları türetir.
3. **Saklama** (`security/`): `PairKeyStore` arayüzü, `KeyWrapper` arayüzü (Android Keystore tek sınıfta: `AndroidKeystoreWrapper`), `EncryptedPairKeyStore` (host_id AAD ile). Testte sahte wrapper.
4. **Oturum** (`session/`): `SessionController` her kontrol bağlantısında yeni `ClientHandshake`; okuyucu iş parçacığı ilk ack'i düz okur, sonra `RecordDecoder`; yazıcı HELLO'yu düz, sonrasını `RecordSealer` ile (FIFO sırasında sayaç). Video: her bağlantıda yeni `video_nonce`, anahtarlar control `prk`'sinden. Doğrulama hatası = BYE'sız kapanış + yeniden bağlanma. `SessionMachine`: `Secured`/`KeyMissing` olayları, AwaitingApproval'a kod + yeniden eşleşme, AWAIT_ACK'te PING yok, ProtocolError'da BYE yok. PENDING sonrası şifreli ACCEPTED gelince anahtar kaydedilir.
5. **UI** (`MainActivity.kt`): protokol sürümü 1; Keystore'lu saklama bağla; eşleşme kodu büyük yazıyla (SpannableString; res dosyaları kapsam dışı olduğundan metinler kodda), yeniden eşleşme uyarısı, KEY_MISSING mesajı.
6. **Testler**: `crypto_vectors.json`'daki her değer (ecdh, transcript_hash, prk, tüm anahtarlar, sas, sas_bytes, new_pair_key, frames, bozuk kayıt reddi), fixture testleri (hello/hello_ack*/video_hello), handshake matrisi, RecordDecoder parçalı besleme/sınırlar, store, makine olayları.

## Handoff

- **Commit:** dalın ucu (`git log -1 task/T-042-client-encryption`), plan commit'i `cbb5c45`.
- **Dokunulan dosyalar:** `protocol/{Messages,Codec}.kt`; yeni `security/{Crypto,Records,Handshake,PairKeyStore,AndroidKeystoreWrapper}.kt`; `session/{SessionController,SessionMachine,SessionUi}.kt`; `MainActivity.kt`; testler `security/{CryptoVectorsTest,SecureChannelTest}.kt` (yeni), `protocol/{FixtureTest,CodecRulesTest}.kt`, `session/SessionMachineTest.kt` (güncellendi/eklendi); bu kart.
- **Sonuç:** Gradle yeşil. `crypto_vectors.json`'daki her değer yeniden üretiliyor (ecdh iki yönden, transcript_hash, ikm, prk, iki moddaki 4'er anahtar, sas_bytes, sas, new_pair_key, 4 şifreli kayıt; her bayt bozma, yanlış sayaç, yanlış anahtar, tekrar oynatma reddi). `check.sh` yalnızca `swift test (host-mac)` nedeniyle kırmızı (beklenen: T-041 host v1 kodeği henüz yok); fixture ve crypto-vector kontrolleri yeşil.
- **Varsayımlar:**
  - İlk HELLO_ACK bayt-tam okunur (`PlainFrames`), sonrası `RecordDecoder`; hemen ardından gelen şifreli kayıtlar tüketilmez.
  - Katı doğrulama: NONE yalnızca REJECTED/VERSION_MISMATCH/BUSY ile (PENDING/ACCEPTED + NONE = downgrade = protokol hatası); PAIRED yalnızca ACCEPTED, PAIRING yalnızca PENDING_APPROVAL ile. Host bu matrise uymazsa bağlantı kapanır.
  - Eski (v0) host'un kısa VERSION_MISMATCH cevabı SHORT_PAYLOAD olarak okunur ("sürüm uyuşmazlığı" yerine "protokol hatası" görünür).
  - ProtocolError'da BYE gönderilmez; BYE yalnızca ilk ack'ten sonra (PENDING/ACCEPTED/STREAMING) gider. AWAIT_ACK'te PING yok (yalnızca HELLO düz gider); ack gelince canlılık sayacı yenilenir.
  - Yazıcı: ilk çerçeve HELLO düz, sonrası kuyruk sırasıyla mühürlenir (sayaç = gönderim sırası). Video: her bağlantıda yeni `video_nonce`, anahtarlar kontrol `prk`'sinden; kontrol bağlantısı kapanınca `prk` silinir.
  - Yeni eşleşme anahtarı, şifreli `HELLO_ACK(ACCEPTED)` okuyucu iş parçacığında çözülünce, UI'ya gitmeden önce yazılır. Yazma hatası oturumu kesmez (loglanır; sonraki bağlantı yeniden eşleşir).
  - Anahtar deposu: `matebridge_pairkeys` SharedPreferences, Keystore alias `matebridge.pairkeys.v1`, AAD = host_id. Keystore anahtarı kaybolursa anahtar "yok" sayılır.
  - Strings kaynak dosyası kapsam dışı olduğundan eşleşme ekranı ve KEY_MISSING metinleri `MainActivity` içinde sabit Türkçe metin.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - AndroidKeystoreWrapper JVM'de test edilemez: ilk eşleşmede anahtar yazılıyor, uygulama yeniden başlayınca PAIRED bağlanıyor mu.
  - Gerçek host ile: yeni cihaz -> "onay bekleniyor" ekranında büyük 6 haneli kod, Mac'tekiyle aynı; İzin ver -> bağlanır; ikinci bağlantı PAIRED (kod yok).
  - Mac'te "Onaylı cihazları unut" -> tablet yeniden bağlanınca "Mac bu tableti tanımıyor, yeniden eşleşiliyor" uyarısı + kod; tablette anahtar yokken host PAIRED derse "Onaylı cihazları unut" mesajı.
  - Görüntü ve girdi (kalem basıncı, klavye) şifreli akışta bozulmadan çalışıyor mu; 60 fps'te gecikme/CPU gözle fark edilir artmadı mı.
  - Ağda bayt bozma: bağlantı BYE'sız kapanıp yeniden bağlanıyor mu.
- **Tur 1 (amendment 0129117 + Codex):** ACCEPTED (ilk ya da ikinci) gelince makine hemen şifreli PING gönderir; video bağlantısında VIDEO_HELLO'dan sonra video c2h anahtarıyla şifreli PING (`VideoChannel`), PONG beklenmez; `video_nonce` her bağlantıda `SecureRandom` (testli). Eşleşme anahtarı yazımı `commit()` başarısızsa `IOException` -> `KeyStoreFailed` olayı -> `Failed(KEY_STORE_FAILED)` ("Eşleşme anahtarı kaydedilemedi — Mac'te 'Onaylı cihazları unut' deyip yeniden bağlan"), `pair_key_stored` loglanmaz. `Failed` durumları `hostReached`'i işaretler, USB ipucu terminal hatanın üstüne yazmaz. Cihazda: USB modunda KEY_MISSING mesajı 3 sn sonra da kalıyor mu; takeover (yeniden bağlanma) sonrası yeni oturum 5 sn içinde etkinleşiyor mu.
- **Açık sorular:** Protokol değişikliği gerekmedi. Eski host'un kısa VERSION_MISMATCH cevabı için Codec'te tolerans istenirse orkestratör karar versin.

## Orkestratör notu (merge, 2026-09-30)

- İnceleme: Codex (`gpt-6.1-sol`, high): iki P2 (anahtar kaydının sessiz başarısızlığı, USB ipucunun hata mesajını ezmesi) düzeltildi; protokol eki (ACCEPTED sonrası PING, video kanıt PING'i, taze video_nonce) uygulandı. T-041 ile birlikte iki birleşik Codex turu. Cihazda eşleşme ve şifreli akış çalışıyor.
