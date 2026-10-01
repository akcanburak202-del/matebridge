---
id: T-076
title: Tablet — AES-GCM kayıt şifre çözme hızı (432 KB'de ~11 ms, 3 KB'de ~0,8 ms)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-073]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/Records.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/FrameDecoder.kt
  - client-android/app/src/test/
  - backlog/tasks/T-076-client-decrypt-speed.md
---

## Amaç

Kare izi (T-073, 2026-10-01 12:45): `decrypted_ns - recv_ns` 432 KB anahtar karede ~11 ms (~40 MB/s), 3 KB karede p50 0,8 ms (sabit maliyet). Şifre çözme ağ okuma iş parçacığında; bu süre sonraki karelerin okunmasını da geciktiriyor. Donanım AES (ARMv8 Crypto Extensions, Conscrypt/BoringSSL) ile 432 KB < 1 ms olmalı. Olası nedenler: varsayılan sağlayıcı (HarmonyOS'ta BouncyCastle?), `cipher.init` + `GCMParameterSpec` + `doFinal` her kayıtta yeni dizi tahsisi, gereksiz kopyalar.

## Kabul kriterleri

- [ ] Oturum başında seçilen `Cipher` sağlayıcısını logla (`provider=…`). Cihazda ölçmek için: `--ez crypto_bench true` ile açılışta bir kerelik mini ölçüm (64 KB / 432 KB, her sağlayıcı için: varsayılan, `AndroidOpenSSL`, varsa diğerleri), sonuç `MB/session ev=crypto_bench …` satırında.
- [ ] Hızlı yol: en hızlı güvenilir sağlayıcıyı açıkça iste (ör. `Cipher.getInstance("AES/GCM/NoPadding", "AndroidOpenSSL")`, yoksa varsayılana düş); çıkış tamponunu yeniden kullan (`doFinal(input, off, len, output, outOff)`), gereksiz kopyaları kaldır. Kriptografik davranış ve tel biçimi **aynı** (fixture/crypto vector testleri geçer).
- [ ] Hata yolları (etiket hatası → oturum kapanır) değişmez.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
