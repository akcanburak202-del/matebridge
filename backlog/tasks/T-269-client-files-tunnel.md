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

1. **Tel biçimi (`protocol/`):** `MsgType` 0x0A/0x50/0x51/0x52, `Capabilities.FILES_NET` (bit12), `FilesInfo.STANDBY`, yeni `FilesNet`, `FilesHello`, `FilesHelloAck`, `FilesData` + `Codec` (FILES_DATA size 0 = INVALID_VALUE, 1..65534; bilinmeyen FILES_NET durumu CLOSE, bilinmeyen ACK durumu REJECTED). `FixtureTest` yeni fixture'ları kapsar.
2. **Kripto (`security/`):** `KeySchedule.filesC2h/filesH2c(prk, clientNonce, hostNonce)`, `SessionSecrets.filesKeys` (wipe sonrası IllegalState), `FilesChannel` (sealer + decoder, anahtar kopyaları silinir). `CryptoVectorsTest` anahtarları ve iki yönde kayıtları doğrular.
3. **Oturum (`session/`):** `SessionMachine` Wi-Fi'da (USB'de değil) kabul edilmiş oturumda `FILES_NET`'i sadeleştirir (pool 1..4, max pool..16, portsuz OPEN yok sayılır, bilinmeyen = CLOSE) ve `Action.FilesNetReceived` verir; ayrıca `desiredTunnel()` (OPEN + kendi `FILES_INFO` READY + Wi-Fi + kabul edilmiş) değişince tek `Action.FilesTunnel(plan?)`. Oturumun her bitişi (`resetSessionFields`, geçiş, BYE, HOST_SLEEP, kopma) plan = null. `SessionController` tüneli açar/kapatır (CloseControl/RetireControl'de de kapatır), `SessionListener.onFilesNet`.
4. **`files/FilesTunnel.kt`:** havuz iş parçacığı (`PoolPlanner`: boşta pool, toplam max, en çok 2 kanıtsız, hata geri çekilmesi 250 ms..5 sn), bağlantı başına: `FILES_HELLO` -> ACK (5 sn) -> anahtarlar -> kanıt PING -> boşta 10 sn PING -> ilk `FILES_DATA`'da `127.0.0.1:<dav>`; iki yönlü aktarma (blok soketler = geri basınç, 16 KiB parça); 1:1 mesajsız kapanma (FIN + 3 sn süre); istemci host veri göndermeden `FILES_DATA` yollamaz. Hız tavanı: tabletin kendi sunucusu (T-266 kovası) `setRate`; tünelde ikinci kova yok (şerit mantığını bozar).
5. **`files/` (STANDBY, Wi-Fi sunucusu):** `FilesSwitch.shouldRun(netOpen)`, `standbyEligible`, yeni durumlar `WIFI_STANDBY`/`WIFI_READY`; `FilesLifecycle` STANDBY'ı bir kez yayınlar, Wi-Fi sunucusunu `Events.wifi` ile başlatır, CLOSE'da OFF yerine STANDBY; `FilesSessionGate` `netOpen`; `FilesController` Wi-Fi'da `WifiFilesRoot` + `FilesConfig.wifi(cap)` + `onStreamBitrate` -> `setRate`.
6. **`MainActivity`:** HELLO bit12, `onFilesNet` -> gate -> `syncFiles`, `installConfig` bit hızını iletir, paylaşım kapalıyken eski OPEN unutulur.
7. **Testler:** FixtureTest, FilesNetCodecTest, CryptoVectorsTest, FilesNetMachineTest, FilesTunnelTest (gerçek loopback Mac + tablet sunucusu), FilesLifecycleTest (STANDBY/gate), PoolPlanner.

## Handoff

## Open questions
