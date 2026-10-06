---
id: T-267
title: Host Core — Wi-Fi dosyaları (0035): kodekler, dosya anahtarları, planner ağ dalı, FilesRateCap
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-265]
decisions: [0035, 0015, 0028]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Tests/MateBridgeCoreTests/
  - backlog/tasks/T-267-host-core-files-net.md
---

## Amaç

Karar 0035 (+ 2026-10-06 eki) için host'un saf (Core) parçaları. Tel biçimi: `docs/PROTOCOL.md` (T-265 dalı `task/T-265-files-net-protocol`): HELLO bit12, `FILES_INFO.state = 2`, 0x0A `FILES_NET`, §4 "Dosya bağlantısı", 0x50–0x52, §5 dosya kuyrukları, §9 dosya anahtarları. Tasarım: `docs/research/2026-10-05-wifi-files.md` §1–§4 (Host Core); **büyük dosya sınırı yok** (0035 eki). **Bu dalı `task/T-265-files-net-protocol` üzerine kur** (fixture'lar orada).

## Kabul

1. Kodekler: `FILES_NET`, `FILES_HELLO`, `FILES_HELLO_ACK`, `FILES_DATA` (encode/decode), `FILES_INFO` STANDBY; bilinmeyen `FILES_NET.state` = CLOSE, bilinmeyen ACK status = REJECTED; `FILES_DATA.size = 0` ve kısa `FILES_HELLO` protokol hatası. Bütün yeni fixture'lar `FixtureTests`'te (her dosyanın testi olmalı).
2. `KeySchedule`: `filesKeys(clientNonce:hostNonce:)` → `kf_c2h`, `kf_h2c`; `CryptoVectorTests` yeni anahtarları ve kayıtları doğrular. Kayıt katmanı dosya bağlantısında 65 536 payload sınırıyla çalışır.
3. Oturum: etkin oturumun `prk`'sinden dosya anahtarları alınabilir (dar sorgu ya da `filesHello`/`filesProven` deseni, video gibi); oturum bitince erişilemez. `FILES_HELLO` yalnız güncel `session_id` ile kabul edilir.
4. `TabletFilesPlanner`: upstream `.adbForward` / `.netProxy`; Wi-Fi oturumunda (istemci bit12) STANDBY/READY → "aç" sunulur, kullanıcı açınca `FILES_NET(OPEN)` kararı, READY'de yerel vekile bağlama, OFF/ayırma/oturum sonu → `FILES_NET(CLOSE)` + teardown (önce birimi ayır, sonra upstream'i kaldır). Otomatik yeniden bağlama (T-206) Wi-Fi dalında da çalışır. USB davranışı bayt bayt aynı (mevcut testler geçer).
5. `WebDavMount`: vekil portu 47012; `isOurs` port ile ayırt eder.
6. Saf `FilesRateCap`: `clamp((48 − video_Mbps)/8, 0,5, 3,0)` MB/s, `bitrate_kbps = 0` → 2 MB/s; token kovası (değişebilir hız) + ≤ 32 KiB küçük şerit (~256 KB/s); Kotlin `TokenBucket` (T-266) ile aynı sayılar.
7. Saf dosya bağlantısı durum makinesi (kabul denetimi: eş adres, sürüm, oturum, kanıtsız ≤ 2, toplam < max; 5 sn kanıt; 30 sn boşta kapanma; havuz/eşleme; ilk `FILES_DATA` yalnız host'tan) testlerle.
8. Log: yalnız sayaçlar/durumlar; jeton, yol, HTTP içeriği asla.

## Plan

(ajan doldurur)

## Handoff

## Open questions
