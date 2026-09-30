---
id: T-041
title: Mac — protokol v1 şifreleme (el sıkışma, eşleşme kodu, AES-GCM kayıtları, Anahtar Zinciri)
status: done
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

1. **Kodek** (`Messages.swift`, `Message.swift`, `ProtocolConstants`): sürüm 1; `Hello` (+`client_nonce`, `client_eph_pub`, telden gelen ham payload = transkript), `HelloAck` (+`KeyMode`, `host_id`, `host_nonce`, `host_eph_pub`), `VideoHello` (+`video_nonce`). `Hello.read` önce sürümü okur; sürüm 1 değilse kalan alanlara bakmadan döner (makine `VERSION_MISMATCH` yanıtlar).
2. **Kripto çekirdeği** (`MateBridgeCore/Crypto/`, saf, yalnızca CryptoKit): `EphemeralKeyPair` (ECDH, geçersiz anahtar -> hata), `SessionKeySchedule` (HKDF Extract/Expand, kontrol/video anahtarları, `sas`, `new_pair_key`, sıfırlanabilir `prk`), `RecordSealer` / `RecordDecoder` (nonce = sayaç, AAD = uzunluk, taşma + sınır + etiket hataları), `ControlInbound` (düz -> şifreli geçiş), `SecretBytes`/`PairingCode` (loglarda/dump'ta gizli), `PairKeyStore` protokolü + bellek içi sahte, `HostIdentityStore`.
3. **Oturum makinesi**: HELLO'da sürüm -> meşgul/devralma -> ECDH doğrulama -> PAIRED (onaylı + anahtar var) ya da PAIRING; ilk ACK düz gider, sonra `startEncryption`. Eşleşme kabulü iki adım: `persistPairing` (Anahtar Zinciri + JSON yazılır) -> `pairingPersisted` -> şifreli ACCEPTED. `prk` oturumda tutulur, video anahtarları `video_nonce` ile türetilir (aynı nonce tekrar kullanılırsa video bağlantısı reddedilir: GCM nonce yeniden kullanımını önler), oturum bitince silinir.
4. **Host**: `Security/KeychainPairKeyStore`, `SessionServer` (bağlantı başına mühürleyici/çözücü, VideoLink kare başına tek kayıt, doğrulama hatası -> BYE'sız kapat + release-all, `forget` anahtarları da siler, TXT `v=1`), onay penceresinde büyük 6 hane kod.
5. **Testler**: `crypto_vectors.json` her değer + bozulmuş kayıt + bağımsız sayaçlar; fixture testleri; makine testleri (sahte anahtar zinciri, test istemcisi ile uçtan uca); video mikro ölçümü.

## Handoff

- **Commit:** `b17bf3f` (kod + testler; bu Handoff ayrı commit). Dal `task/T-041-host-encryption` = `main` + `proto/crypto` merge.
- **Dokunulan dosyalar:** `MateBridgeCore/`: `Messages.swift`, `Message.swift`, `ProtocolConstants.swift` (v1), yeni `Crypto/{CryptoTypes,KeySchedule,Records}.swift`, `Session/SessionMachine.swift`, yeni `Session/HostIdentityStore.swift`. `MateBridgeHost/`: yeni `Security/KeychainPairKeyStore.swift`, `Session/SessionServer.swift`. `MateBridgeApp/`: `ApprovalPanel.swift` (büyük kod), `main.swift` (1 satır). Testler: yeni `Tests/.../Crypto/*` (vektörler, makine uçtan uca, gizlilik, host kimliği), güncellenen `FixtureTests`, `CodecTests`, `SessionMachineTests`, `SessionInputWiringTests`.
- **check.sh:** Swift (host + probe'lar) ve `crypto vectors up to date` / `protocol fixtures up to date` yeşil; 440 Swift testi geçiyor. `gradle (client-android)` kırmızı (435 testten 4'ü): beklenen, T-042 bekliyor (Kotlin fixture testleri yeni HELLO/HELLO_ACK/VIDEO_HELLO alanlarını henüz okumuyor).
- **Kripto çekirdeği:** `crypto_vectors.json`'daki her değer yeniden üretiliyor (ecdh, transcript, prk, bütün anahtarlar, sas, new_pair_key, 4 kayıt). Bozulmuş kayıt (her bayt), yanlış anahtar, tekrar/sıra bozma, sayaç taşması, uzunluk sınırları (yalnızca 4 baytla), geçersiz/eğri dışı/sıkıştırılmış açık anahtar, `prk` silme, loglarda/`print`te gizlilik test edildi. Mikro ölçüm (yalnız mühürle+aç, `swift test` debug): 200 x 256 KiB kare, binlerce Mbit/s; kare başına tek kayıt, 80 Mbps için sorun yok (gerçek ağ/encoder darboğaz olur).
- **Varsayımlar / tasarım notları:**
  - `Hello.wirePayload`: transkript HELLO'nun **telden gelen** baytlarını hashler (yeniden kodlama değil; sona eklenen alanlar/kanonik olmayan UTF-8 hash'i bozmasın). `Hello ==` bu alanı yok sayar.
  - `Hello.read` sürüm 1 değilse kalan alanları okumaz (yer tutucu döner), makine `VERSION_MISMATCH` (şifresiz, key_mode NONE) gönderir.
  - PAIRED = onaylı cihaz listesinde **ve** Anahtar Zinciri'nde anahtar var. Yalnız anahtar ya da yalnız kayıt varsa PAIRING (anahtar tek başına güvenilmez).
  - Kabul iki adımlı: makine `persistPairing` üretir, sunucu Anahtar Zinciri + cihaz listesini yazar, `pairingPersisted(stored:)` ile şifreli ACCEPTED gider; yazım hatasında REJECTED (tablet, host'ta olmayan anahtarı tutmasın).
  - **Geçersiz `client_eph_pub` kontrolü devralmadan/meşgul kararından ÖNCE** yapılır: çöp anahtarla gelen HELLO yaşayan oturumu düşürmez.
  - **`video_nonce` tekrarı reddedilir** (oturumun son 1024 kanıtlanmış nonce'u; eskisi unutulur, kilitlenme yok). Yalnızca kanıtlanmış bağlantılar nonce tüketir.
  - Video bağlantısında VIDEO_HELLO'dan sonra istemciden gelen her bayt bağlantıyı kapatır (protokolde C->H başka mesaj yok).
  - `HELLO` ardında düz metin baytı kalırsa protokol hatası (istemci ACK'ten önce şifreli yazamaz).
  - Kayıt doğrulama/uzunluk hatası: BYE yok, release-all yolu aynı (`recordAuthFailed`), log `ev=record_auth_failed conn=.. counter=N reason=tag|length|counter`. `ev=handshake mode=paired|pairing`.
  - Anahtar Zinciri: eski dosya tabanlı anahtar zinciri, `SecItemAdd/Update`, hesap = device_id hex; `removeAll` hesapları sayıp tek tek siler. `host_id`: `~/Library/Application Support/MateBridge/host-id` (0600).
  - Bonjour TXT `v=1`.
- **Test edilmeyenler / gerçek cihaz ve Mac'te doğrulanacaklar:**
  - `KeychainPairKeyStore` hiç çalıştırılmadı (testlerde sahte): ilk yazma/okuma, imza kimliği değişince erişim istemi çıkıp çıkmadığı, login item ile açılışta okuma, "Onaylı cihazları unut" sonrası anahtarların gerçekten silinmesi (`security find-generic-password -s dev.matebridge.host.pair`).
  - `SessionServer` ağ yolu (çerçeveleme geçişi, `VideoLink` kilit altında mühürleme+yazma sırası, send backlog) birim testlenemiyor (Network.framework); yalnızca derlendi. Gerçek Wi-Fi/USB akışı, eşleşme kodu penceresi (büyük kod + "Tabletteki kodla aynı mı?"), yeniden bağlanma, 80 Mbps video performansı orkestratörde.
  - Kotlin ile bayt bayt uyum T-042 birleşince (vektörler + fixture'lar).
- **Tur 1 (PROTOCOL 0129117 + Codex):**
  - Devralma: aynı `device_id` + yaşayan oturum + anahtar varsa `HELLO_ACK(ACCEPTED, PAIRED)` ve "proving" durumu; ilk doğrulanmış kayıtta release-all -> BYE(SUPERSEDED) -> kapat -> yeni oturumu etkinleştir -> o kayıt işlenir. 5 sn kanıt yoksa yeni bağlantı kapanır, eski oturuma dokunulmaz. PAIRING gerekecekse (anahtar yok ya da onay bekleyen oturum) `BUSY`. Proving bağlantı "doğrulanmamış" sayısına dahil.
  - Video: VIDEO_HELLO geçerliyse yalnız `videoProve(c2h)` (durum değişmez); sunucu 64 baytlık tavanlı `RecordDecoder` ile tek şifreli PING bekler, `videoProven` ile bağlanır (eskisini o zaman kapatır, nonce o zaman kaydedilir). 5 sn kanıt yoksa yalnız yeni video bağlantısı kapanır. Video'da PING'e PONG yok; PING sonrası her bayt bağlantıyı kapatır. Codex P1 için testler: kanıtsız deneme hiçbir şeyi değiştirmez, kanıtlı olan eskisini değiştirir, 300 kanıtsız + 200 kanıtlı yeniden bağlanma kilitlemez.
  - Codex P2 (forget): oturum önce bitirilir (`machine.shutdown()`: release, BYE, kapat), Anahtar Zinciri `removeAll()` oturum kuyruğu dışında (utility kuyruk) çalışır, sonuç kuyruğa loglanır. Not: bu sırada biten yeni bir eşleşmenin anahtarı silinebilir; sonuç yalnızca yeniden eşleşmedir.
  - Codex P2 (host-id): `HostIdentityStore.resolve()` -> `.loaded` / `.created` / `.unpersisted`. `.created` (yok ya da bozuk dosya) ve onaylı cihaz kaydı varsa tüm onaylar ve anahtarlar silinir (log `host_identity_replaced`); `.unpersisted` ise `allowPaired = false` (hiç PAIRED cevaplanmaz, her cihaz yeniden eşleşir) ve bir kez `host_identity_unpersisted` loglanır. Anahtar Zinciri, kayıt dosyası boşken (ilk çalıştırma) sorgulanmaz.
- **Tur 2 (Codex, ortak dal):**
  1. `video_nonce`: tüm kontrol oturumu boyunca hatırlanır (pencere/eviction kaldırıldı), sınır 4096 (`maxVideoNonces`). Sınıra gelince kanıtlanmış yeni bir attach kabul edilmez; oturum release-all + `BYE(SHUTTING_DOWN)` + kapat ile biter, log `video_nonce_budget_exhausted`; tablet yeni el sıkışma + yeni `prk` ile döner. Test: 8'lik sınırda ilk nonce hâlâ reddediliyor, dokuzuncu oturumu bitiriyor, yeniden bağlanınca aynı nonce'lar geçerli.
  2. Anahtar Zinciri: tek seri kuyruk `PairKeyService` (Core), her işlem asenkron + completion. Makine `lookupPairKey(id, device)` üretir (uygulamada `Configuration.pairKeys = nil`), bağlantı `lookingUp` durumunda hiçbir şey göndermez, cevap `pairKeyResolved(id, key:, now:)`; 5 sn içinde cevap yoksa yalnız o bağlantı kapanır. Başka cihazın BUSY kararı ve onaysız cihazın PAIRING'i arama gerektirmez; cevap gelince yuva yeniden denetlenir. Mevcut oturumun release yolları aramayı beklemez (testli). Test için `pairKeys` dolu verilirse eski satır içi yol kullanılır (bellek içi sahte).
  3. Ayarlar bağlanması: `StreamCoordinator.streamConfig(for:)` artık saf (paylaşılan `pendingHello` kaldırıldı); `.sessionStarted` eylemi etkinleşen bağlantının `Hello`'sunu taşır ve koordinatör ayarları yalnız o anda (kanıttan sonra) türetir. Test: kanıtsız B hiçbir `sessionStarted` üretmez, kanıtlı olan kendi HELLO'sunu taşır.
  4. forget/eşleşme yarışı: forget'in `removeAll`'ı kuyruğa hemen girer; sonraki eşleşme kaydı kuyrukta ondan sonra çalışır; `ACCEPTED` yalnız `save` tamamlanınca (`finishPairing`, oturum kuyruğunda). Bağlantı bu arada bittiyse (ör. forget oturumu bitirdi) kaydedilen anahtar silinir. Test: `BlockingStore` ile sıra `removeAll, save, lookup`, taze anahtar korunur.
- **Test edilmeyen (Tur 2):** `SessionServer` tarafındaki kuyruk köprüleri (`lookupPairKey` -> `pairKeyResolved`, `finishPairing`) yalnız derlendi; Network/Keychain gerektirir.
- **Açık sorular (orkestratör için):**
  1. Eski video bağlantısı yarış durumunda: kanıtlı ama çok eski (1024'ten eski) bir nonce ve yakalanmış PING kaydı tekrarlanabilir; pratikte 1024 yeniden bağlanma bir oturumda gerçekçi değil.
  2. Video PING'inin `seq`/zamanına bakılmıyor (kayıt sayacı 0 olmak zorunda, yani tekrar aynı anahtar/nonce ile zaten nonce kontrolüne takılır).

## Orkestratör notu (merge, 2026-09-30)

- İnceleme: Codex (`gpt-6.1-sol`, high) dört tur (tek başına, T-042 ile birlikte iki kez). Bulunan P1'ler (video kimliği doğrulanmadan ekleme bütçesinin tükenmesi, video nonce tekrarı ile GCM nonce yeniden kullanımı, oturum kuyruğunda eşzamanlı Anahtar Zinciri) ve P2'ler düzeltildi; protokol ekine (kanıtla devralma, kanıtla video ekleme) göre uygulandı. Son turda kalan iki P2 (terk edilen eşleşme temizliğinin yeni anahtarı silmesi, Anahtar Zinciri işlerinin sınırsız birikmesi) T-043'e taşındı.
- Cihazda: eşleşme kodu iki tarafta aynı, onay (orkestratör, AX) → anahtar Anahtar Zinciri'nde, şifreli görüntü `dec=9/9`, yeniden bağlanma `mode=paired`, eşzamansız anahtar araması ile de çalışıyor.
