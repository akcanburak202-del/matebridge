# 0010 — Oturum şifrelemesi: eşleşme anahtarı + geçici ECDH, AES-256-GCM kayıtları

- **Durum:** kabul
- **Tarih:** 2026-09-30

## Bağlam
PLAN Aşama 4: "Oturum şifrelemesi (eşleşmede paylaşılan anahtar)". Protokol v0'da kontrol + girdi (klavyeden yazılan şifreler dahil) ve ekran görüntüsü ev ağında şifresiz gidiyordu. Kullanıcı 2026-09-30'da "şimdi yap" dedi. Bağımlılık eklenmemeli (AGENTS.md); Android tarafı API 31 (HarmonyOS 4.3), Python'da kripto kütüphanesi yok.

## Karar
1. Protokol **v1** (PROTOCOL §9): her bağlantıda geçici P-256 ECDH; ilk bağlantıda (eşleşme) iki cihaz aynı 6 haneli kodu gösterir, kullanıcı onaylar ve iki taraf `pair_key` saklar; sonraki bağlantılarda `ikm = pair_key ‖ ecdh` (kimlik doğrulama + ileri gizlilik). HKDF-SHA256 ile yön ve bağlantı başına anahtar; kayıtlar AES-256-GCM, nonce = sayaç, AAD = uzunluk.
2. Yalnızca platform kriptografisi (CryptoKit; Android `javax.crypto`/`java.security`). X25519/ChaCha yerine P-256/AES-GCM: API 31'de kesin var, iki platformda da donanım hızlandırmalı.
3. Test vektörlerinin referansı Swift/CryptoKit betiği (`protocol/fixtures/crypto_vectors.swift`); `check.sh` üretilen JSON'un güncel olduğunu denetler. Python üretecine kripto eklenmez.
4. USB'de de şifreleme açık (tek kod yolu; maliyet ihmal edilebilir).
5. Anahtarlar Anahtar Zinciri'nde (Mac) ve Keystore ile sarılı olarak (tablet) saklanır, asla loglanmaz.

## Sonuçlar
- Ağdaki pasif dinleyici hiçbir şey okuyamaz; eşleşmiş bağlantıya aracı giremez. İlk eşleşmede aracıya karşı koruma, kullanıcının kodu karşılaştırmasına bağlı.
- v0 ile uyumluluk yok (iki taraf birlikte güncellenir; tek kullanıcı).
- Mevcut onaylı cihaz kaydı anahtar taşımadığı için güncellemeden sonra tablet bir kez yeniden eşleşir.
- Tekrar düşünülür: UDP video (kayıt biçimi datagram'a göre değişir), birden çok tablet.
