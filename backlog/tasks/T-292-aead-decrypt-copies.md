---
id: T-292
title: İstemci — video kaydı şifre çözmede Conscrypt kopyalarını ve kayıt başına SPI yeniden kurulumunu azalt
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-285]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/Records.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/security/
  - client-android/app/src/test/kotlin/dev/matebridge/client/bench/
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

## Handoff

## Open questions
