---
id: T-042
title: Tablet — protokol v1 şifreleme (el sıkışma, eşleşme kodu ekranı, AES-GCM kayıtları, Keystore)
status: todo
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

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
