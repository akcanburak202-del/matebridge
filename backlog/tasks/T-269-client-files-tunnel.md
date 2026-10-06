---
id: T-269
title: Client — Wi-Fi dosyaları (0035): kodekler, dosya anahtarları, FILES_NET, FilesTunnel havuzu, STANDBY
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-265, T-266]
decisions: [0035]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/files/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-269-client-files-tunnel.md
---

## Amaç

Karar 0035 (+ 2026-10-06 eki) istemci oturum tarafı. Tel biçimi: `docs/PROTOCOL.md` (T-265). Tasarım: araştırma §4 "İstemci". **Bu dalı `task/T-265-files-net-protocol` üzerine kur ve T-266 birleşmişse onu da al** (main'de değilse T-266 dalını birleştir; `files/` ortak).

## Kabul

1. Kodekler: `FILES_NET`, `FILES_HELLO`, `FILES_HELLO_ACK`, `FILES_DATA`, `FILES_INFO` STANDBY; bilinmeyenler PROTOCOL'deki gibi; bütün yeni fixture'lar `FixtureTest`'te. HELLO bit12 `FILES_NET` gönderilir.
2. `Crypto`/`Handshake`: `filesKeys` (KDF), `CryptoVectorsTest` yeni anahtar ve kayıtları doğrular; `prk` oturum boyunca `SessionSecrets`'ta, oturum bitince silinir.
3. `FILES_INFO`: Wi-Fi oturumunda paylaşım izinliyse STANDBY; `FILES_NET(OPEN)` → sunucu Wi-Fi köküyle (`MateBridge/Wi-Fi/`, T-266) ve Wi-Fi profiliyle başlar → READY → havuz açılır. CLOSE → havuz kapanır, sunucu durur, STANDBY. İzin yoksa OFF. USB davranışı değişmez (USB'de STANDBY yok). Ayrı "Wi-Fi'da paylaş" ayarı **yok** (0035 §2).
4. `files/FilesTunnel.kt`: `VideoConn` kalıbı (trafik sınıfı 0x20, keepalive); kontrol bağlantısının host adresine `FILES_NET.port`; `FILES_HELLO` → ACK (5 sn) → anahtarlar → kanıt PING; boşta `pool`, toplam ≤ `max`; ilk `FILES_DATA`'da `127.0.0.1:<dav>`'a bağlan, iki yönde aktar (bağlantı/yön ≤ 64 KiB, geri basınç), `FILES_DATA` ≤ 16 KiB; boştayken 10 sn'de bir PING; kapanma 1:1 mesajsız; host'tan veri almamış bağlantıda istemci `FILES_DATA` göndermez. C→H hız `TokenBucket` (T-266 formülü, `STREAM_CONFIG.bitrate_kbps` değişince `setRate`).
5. Oturum sonu, arka plan, USB'ye geçiş, Mac uykusu (`BYE(HOST_SLEEP)`): bütün dosya bağlantıları kapanır, sunucu durur.
6. Durum satırı (Türkçe): Wi-Fi'da "Mac'ten açılmayı bekliyor" / "Mac'e açık (Wi-Fi, MateBridge/Wi-Fi)".
7. Log: sayaçlar/durumlar; jeton, yol, HTTP içeriği asla.

## Plan

(ajan doldurur)

## Handoff

## Open questions
