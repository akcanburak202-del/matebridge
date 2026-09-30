---
id: T-044
title: Tablet — eşleşme anahtarını PAIRING başında sakla (bağlantı koptuktan sonra onay için)
status: done
phase: 4
owner: android-client-dev
depends_on: [T-042]
decisions: [0010]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-044-client-store-key-on-pairing.md
---

## Amaç

PROTOCOL §9 "Bağlantı koptuktan sonra onay" (T-043 ile birlikte). Kullanıcı eşleşme kodunu görünce Parsec'e geçip Mac'te onaylıyor; bu sırada MateBridge arka plana düşüp bağlantıyı kapatıyor. Host o el sıkışmanın anahtarını onayla saklayacak (T-043); tablet de aynı anahtarı **baştan** saklamalı ki geri dönünce PAIRED bağlantı kurulabilsin.

## Kabul kriterleri

- [ ] PAIRING'deki ilk HELLO_ACK doğrulanıp anahtarlar türetilince `new_pair_key` o `host_id` için **hemen** saklanır (varsa eskisinin yerine). ACCEPTED geldiğinde ayrıca bir şey yapılmaz (anahtar zaten saklı; kayıt başarısızsa T-042'deki hata yolu bu ana taşınır: oturum kapanır, mesaj gösterilir).
- [ ] "Mac bu tableti tanımıyor, yeniden eşleşiliyor" uyarısı ve kod ekranı aynen kalır. Ekrana bir satır eklenir: "Mac'i göremiyorsan: Parsec'te kodu karşılaştırıp İzin ver de, sonra buraya dön."
- [ ] Arka plana geçip dönünce yeniden bağlanma: host PAIRED seçerse saklı anahtarla bağlanır (mevcut yol).
- [ ] Birim testleri: PAIRING'de anahtar ilk ACK'te saklanır; ACCEPTED'dan önce bağlantı koparsa anahtar kalır; sonraki PAIRED el sıkışması o anahtarla tamamlanır; eski anahtar yenisiyle değiştirilir. `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Host (T-043). Tel biçimi değişmez. Cihaz testi orkestratörde.

## Plan

1. `SecureSession.onMessage` (ACCEPTED'da saklar) yerine `storePairKey(store)` (idempotent, yalnız PAIRING).
2. `SessionController`: ilk HELLO_ACK doğrulanıp `Secure` çıkınca, `Secured` olayından önce `storePairKey`; hata -> `KeyStoreFailed` (mevcut yol), oturum kapanır. `readRecords`'taki ACCEPTED'da saklama kaldırılır.
3. MainActivity kod ekranına ek satır.
4. Testler: ilk ACK'te saklama (host'un türettiği anahtarla aynı), ACCEPTED'dan önce kopunca anahtar kalır ve PAIRED el sıkışması tamamlanır, eski anahtar değişir, PAIRED oturum yazmaz, saklama hatası yüzeye çıkar.

## Handoff

- **Commit:** kod son commit'ten önceki "T-044: plan" + "store pairing key at the first HELLO_ACK" commitleri; SHA orkestratöre mesajla bildirildi (HEAD).
- **Dokunulan dosyalar:** security/Handshake.kt (`onMessage` -> `storePairKey`), session/SessionController.kt (ilk ACK'te sakla, hata -> KeyStoreFailed), MainActivity.kt (kod ekranına Parsec satırı), test/security/CryptoVectorsTest.kt + SecureChannelTest.kt, bu kart.
- **Varsayımlar:** Saklama `Secured` olayından önce, reader thread'inde yapılır; `rePairing` uyarısı ve kod ekranı aynı. Golden `new_pair_key` vektörü ilk ACK sonrası saklanan anahtarla eşleşiyor.
- **Test edilmeyenler / cihazda doğrulanacaklar:** (1) Mac yeni cihazken bağlan, kod görününce tableti arka plana at (bağlantı kopsun), Mac'te onayla (T-043 ile), geri dön: PAIRED bağlanmalı. (2) Mac'te "unut" sonrası yeniden eşleşmede uyarı + yeni Parsec satırı görünmeli. (3) Normal akış (kodu tabletten görüp onaylama) bozulmamış olmalı.
- **Açık sorular:** Yok. Not: worktree'de `client-android/local.properties` yoktu; gradle için ANDROID_HOME=~/Library/Android/sdk export edildi.

## Orkestratör notu (merge, 2026-09-30)

- Orkestratör okudu (küçük değişiklik), T-043 ile birlikte merge edildi; cihazda yukarıdaki akışta doğrulandı.
