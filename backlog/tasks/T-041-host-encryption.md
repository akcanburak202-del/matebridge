---
id: T-041
title: Mac — protokol v1 şifreleme (el sıkışma, eşleşme kodu, AES-GCM kayıtları, Anahtar Zinciri)
status: todo
phase: 4
owner: mac-host-dev
depends_on: [T-039]
decisions: [0010]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Security/
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Tests/
  - backlog/tasks/T-041-host-encryption.md
---

## Amaç

PROTOCOL.md v1 (§2, §3, §4 HELLO/HELLO_ACK/VIDEO_HELLO, **§9**) ve karar 0010. Protokol, fixture'lar ve kripto test vektörleri **`proto/crypto` dalında** (`5319fff`): kart dalı `main`'den açılır ve `proto/crypto` merge edilir. Tablet tarafı T-042 paralel yürür; ikisi birlikte merge edilir.

## Kabul kriterleri

- [ ] **Kodek:** HELLO/HELLO_ACK/VIDEO_HELLO yeni alanlarla; `protocol_version` önce okunur, 1 değilse kalan alanlar okunmadan `VERSION_MISMATCH` (şifresiz, `key_mode = NONE`); `key_mode` bilinmeyen değer protokol hatası. Bütün fixture testleri geçer.
- [ ] **Kripto çekirdeği** (`MateBridgeCore`, saf, CryptoKit): el sıkışma durumu, HKDF (Extract/Expand), anahtar türetme, `sas`, `new_pair_key`, kayıt şifreleme/çözme (nonce = sayaç, AAD = uzunluk, sayaç taşmasında hata), geçersiz açık anahtar → hata. **`crypto_vectors.json`'daki her değer** testlerde yeniden üretilir; bozulmuş kayıt reddedilir; iki yönün sayaçları bağımsız.
- [ ] **Çerçeveleme:** ilk HELLO_ACK'ten sonra kontrol bağlantısında, VIDEO_HELLO'dan sonra video bağlantısında okuma/yazma şifreli kayıtla (sınır = payload sınırı + 17, başlık okunur okunmaz denetlenir). Doğrulama hatası → BYE göndermeden kapat, kontrol bağlantısında release-all yolu (§7) aynen çalışır. Video yolu kare başına tek kayıt; kopyalama sayısı makul (80 Mbps'de sorun olmamalı: basit bir mikro ölçüm testi ya da Handoff'ta ölçüm).
- [ ] **Eşleşme:** kalıcı `host_id` (bir kez üretilir, saklanır). Onaylı cihaz + Anahtar Zinciri'nde anahtar varsa PAIRED, yoksa PAIRING. Onay penceresi 6 haneli kodu büyük yazıyla gösterir ("Tabletteki kodla aynı mı?"). Kabulde `new_pair_key` Anahtar Zinciri'ne (hizmet `dev.matebridge.host.pair`, hesap = device_id hex) yazılır, sonra şifreli `HELLO_ACK(ACCEPTED)`. Anahtar Zinciri erişimi tek bir tipte (`MateBridgeHost/Security/`), test için sahte uygulaması. "Onaylı cihazları unut" anahtarları da siler. Eski (v0) onay kayıtları anahtarsız olduğu için PAIRING'e düşer.
- [ ] **Video anahtarları:** oturumun `prk`'si bellekte tutulur, VIDEO_HELLO'daki `video_nonce` ile bağlantı anahtarları türetilir; oturum bitince `prk` sıfırlanır.
- [ ] **Gizlilik:** anahtarlar, `prk`, `ecdh`, `sas` **loglanmaz** (kod yalnızca pencerede). Log: `ev=handshake mode=paired|pairing`, `ev=record_auth_failed conn=…` (sayaç/durum).
- [ ] Bonjour TXT `v=1`.
- [ ] `./scripts/check.sh` (T-042 ile birlikte) geçiyor. Kendi dalında Kotlin tarafı kırmızı olabilir; Swift ve kripto vektör denetimi yeşil olmalı.

## Kapsam dışı

- Tablet (T-042). UDP video. Birden çok tablet.
- Gerçek bağlantı/cihaz testi orkestratörde (eşleşme kodu, yeniden bağlanma, Wi-Fi'de şifreli akış, performans).

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
