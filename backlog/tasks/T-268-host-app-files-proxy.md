---
id: T-268
title: Host App — Wi-Fi dosyaları (0035): dosya dinleyicisi + kanıt, FilesNetProxy (127.0.0.1:47012), menü
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-267]
decisions: [0035]
files:
  - host-mac/Sources/MateBridgeHost/
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Tests/
  - backlog/tasks/T-268-host-app-files-proxy.md
---

## Amaç

T-267'nin Core parçalarını uygulamaya bağla. Tasarım: araştırma §4 "Host (App)", PROTOCOL §0x0A ve §4 "Dosya bağlantısı". **T-267 dalının üzerine kur.**

## Kabul

1. `SessionServer`: istek üzerine dosya dinleyicisi (tercih 47003, doluysa sistem portu), yalnız kontrol bağlantısının eş adresi; `FILES_HELLO` kabul/red, 5 sn kanıt, kanıtsız ≤ 2; dosya soketi `NET_SERVICE_TYPE_BK`, `SO_SNDBUF` ~128 KiB, `TCP_NOTSENT_LOWAT` 16 KiB, TCP keepalive. "Yalnız USB" profilinde açılmaz. Oturum sonunda (BYE, HOST_SLEEP, devralma, kopma) bütün dosya bağlantıları ve dinleyici kapanır.
2. `FilesNetProxy`: `127.0.0.1:47012` yerel dinleyici; her Finder bağlantısı bir boştaki kanıtlanmış dosya bağlantısıyla 1:1; boşta yoksa en çok 5 sn bekletip kapatır; bağlantı/yön başına ≤ 64 KiB tampon (geri basınç, bayt atılmaz); H→C gönderim `FilesRateCap` ile (video hedefi `STREAM_CONFIG.bitrate_kbps`'ten, değişince güncellenir); kapanma 1:1 ve mesajsız (önce bekleyen baytlar).
3. `TabletFilesBridge`: yeni eylemler (vekil başlat/durdur, `FILES_NET` gönder); NetFS bağlama vekil URL'sine (`AllowLoopback`, `SoftMount`) aynen.
4. Menü (`MateBridgeApp/main.swift`): Wi-Fi oturumunda STANDBY/READY iken "Tablet dosyalarını aç" etkin (tıklama onaydır); USB menüsü değişmez.
5. Uyarı: Mac'te pencere açma; testlerde Finder açma. Bağlama testi için `mount`/`tools/dav-repro/mount.swift` gibi komut satırı yolları.
6. Log (LOGGING.md biçimi): `ev=files_net` (open/close, port), `ev=files_conn` (kabul/red nedeni, kanıt süresi), saniyelik sayaçlar (bağlantı, bayt, kısıtlanan süre); içerik/jeton/yol asla.

## Plan

(ajan doldurur)

## Handoff

## Open questions
