---
id: T-268
title: Host App — Wi-Fi dosyaları (0035): dosya dinleyicisi + kanıt, FilesNetProxy (127.0.0.1:47012), menü
status: review
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

1. `MateBridgeHost/Files/FilesSocket.swift`: küçük ham-fd TCP sarmalayıcı (durdurulabilir okuma, sınırlı yazma tamponu, "önce bekleyen baytlar" ile kapanma, FIN sonra EOF'a kadar okuyup atma). `BsdTcpConnection` Core'da ve `files:` dışında; okuma durdurma, `SO_SNDBUF` ve `NET_SERVICE_TYPE_BK` da yok, o yüzden Host'ta kendi sarmalayıcı.
2. `MateBridgeHost/Files/FilesNetService.swift`: Core `FilesConnectionMachine` + `FilesRateLimiter`'ı sürer. Tek seri kuyruk. Dosya dinleyicisi (tercih 47003, doluysa sistem portu; `[::]` çift yığın), vekil dinleyici (127.0.0.1:47012 tercih, sonra sistem portu). Kabul → `FILES_HELLO` (düz, elle ayrıştırma, ≤ 64 bayt yük) → ACK → `startRecords` (anahtarlar oturumdan, `keys` kapanışı) → kanıt PING → havuz. Vekil bağlantısı → `localOpened` → `bind`; Finder→tablet yönü `FilesRateLimiter` ile (tek parça bekletme, okuma durur), tablet→Finder yönü geri basınçlı (yerel yazma tamponu ≥ 64 KiB ise dosya okuması durur). Saniyelik sayaç logu, 200 ms `tick`.
3. `TabletFilesBridge`: `FilesNetLink` (SessionServer'dan: eş adres, anahtarlar, `FILES_NET` gönderimi); `.startProxy/.stopProxy/.sendFilesNet` gerçek yürütme; `sessionStarted(sessionID:transport:capabilities:)` `netCapable` geçirir; `drainUnmountedPaths` sonrası `takeQueuedActions()`; oturum bitişi/kapanışta servis her zaman durur (CLOSE mesajı yok).
4. `SessionServer`: `controlPeerHost(sessionID:)`, `filesKeys(...)` (senkron, oturum kuyruğunda), `STREAM_CONFIG` gönderiminde `handlers.streamBitrate`. `main.swift`: bağlama + bitrate. Menü Wi-Fi'da planner'dan geliyor (menü durumları yeniden kullanılıyor), yalnız başlık metinleri.
5. Test: Core testleri değişmez; Host kodu için `--files-net-selftest` komut satırı yolu (`MateBridgeApp/FilesNetSelfTest.swift`): sahte tablet istemcisi (gerçek kayıt şifrelemesi) + sahte HTTP sunucu ile uçtan uca bayt, geri basınç, kısıtlama ve 1:1 kapanma. Pencere/Finder yok.


## Handoff

- **Dal:** `task/T-268-host-app-files-proxy` (entegrasyon dalı `task/0035-files-integration` + `task/T-267-host-core-files-net` 4870504f birleştirildi: kapanış/boşaltma sözleşmesi). Commit SHA: `git log -1` (son commit `T-268: ...`). `./scripts/check.sh`: ALL OK (host-mac, probes, gradle, protokol, ölçüm kiti).
- **Dosyalar:** yeni `MateBridgeHost/Files/FilesSocket.swift` (ham fd soketi: durdurulabilir okuma, yazma tamponu, "önce bekleyen baytlar" kapanışı; dinleyici), yeni `Files/FilesNetService.swift` (dosya dinleyicisi 47003 + vekil 127.0.0.1:47012, `FilesConnectionMachine` + `FilesRateLimiter` sürücüsü, kayıt katmanı, bayt pompaları, sayaç logu); `Files/TabletFilesBridge.swift` (`FilesNetLink`, gerçek `startProxy/stopProxy/sendFilesNet`, `netCapable`, `takeQueuedActions()`); `Session/SessionServer.swift` (`controlPeerHost`, `filesKeys`, `handlers.streamBitrate`); `MateBridgeApp/main.swift` (bağlama) ve yeni `MateBridgeApp/FilesNetSelfTest.swift`.
- **Davranış:** `sessionStarted(sessionID:transport:capabilities:)` `netCapable = bit12 && transport != .usb` geçirir. "Tablet dosyalarını aç" menüsü Wi-Fi'da planner'ın `.ready/.preparing/.mounting/.enableOnTablet` durumlarını kullanır (STANDBY/READY'de etkin), USB menüsü değişmedi. `FILES_NET(CLOSE)` yalnız Finder çıkarması (`takeQueuedActions`); tablet OFF/STANDBY ve oturum sonunda mesaj yok, yalnız teardown (önce birim ayrılır, sonra vekil/dinleyici kapanır; oturum bitince dosya dinleyicisi hemen kapanır, yeni bağlantı kabul edilmez). Her `.close`: kuyruk boşaltılır, soket gerçekten kapanınca `fileClosed(id)`; `.abort` anında kapatır; soket kendiliğinden kapanırsa da `fileClosed`. Dosya soketi: `NET_SERVICE_TYPE_BK`, `SO_SNDBUF` 128 KiB, `TCP_NOTSENT_LOWAT` 16 KiB, keepalive 30/10/3, `TCP_NODELAY`; reddedilen seçenek varsa tek uyarı (`socket_options_refused`; denemede hiçbiri reddedilmedi). Finder→tablet yönü `FilesRateLimiter` ile (tek 16 KiB'lık parça tutulur, okuma durur, bayt atılmaz; şerit sıfırlama tablet cevabı sonrası ilk Finder parçasında); tablet→Finder yönü geri basınçlı (yerel yazma ≥ 64 KiB ise dosya okuması durur, < 32 KiB'ta sürer). Video hedefi `STREAM_CONFIG.bitrate_kbps` `SessionServer` hook'u ile (aktif bağlantıya her `STREAM_CONFIG` gönderiminde ve oturum başlangıcında).
- **Loglar** (`component=files`): `ev=files_net` (listening/open/close/stopped, portlar, `send=open|close`), `ev=files_conn` (makineden: kabul/red nedeni, proven), `ev=files_stats` saniyede bir ve yalnız hareket varsa (bağlantı sayıları, `to_tablet_bytes`, `from_tablet_bytes`, `throttled_ms`, `cap_bps`). İçerik/jeton/yol/nonce yok.
- **Sınama (komut satırı, GUI yok, Finder yok):** `MateBridgeApp --files-net-selftest` (~30 sn): gerçek soketlerle sahte tablet (gerçek kayıt şifrelemesi) + sahte "tablet sunucusu"; 1 MB bayt bayt aynı, 3 eşzamanlı bağlantı, 1:1 kapanış iki yönde, hız tavanı (0,5 MB/s'de 1 MB 1,8 sn; 2 MB/s'de 0,46 sn), yanlış oturum REJECTED, 3. kanıtsız bağlantı hemen kapanır, 5 sn kanıt süresi, bozuk kayıt, boştaki bağlantı yokken 5 sn sonra kapanış, `stopAll` dinleyicileri kapatır, yabancı eş adresi cevapsız kapanır; hepsi geçti (arka arkaya birkaç koşu). `--files-net-hold <üst port> <sn>` yardımcı kipi: servis + sahte tablet, `proxy=<port>` basar. Bununla gerçek `mount_webdav -S http://127.0.0.1:47012/MatePad/ <dizin>` (komut satırı, scratchpad dizinine) küçük Python WebDAV sunucusuna karşı bağlandı, `ls`/`cat` doğru, 3 MiB dosyanın `cksum`'ı birebir, `umount` temiz.
- **Tur 2 (Codex --high P2'leri + T-267 r3, d407b94f birleştirildi):** (A) makineye monoton `now` (tick ile aynı saat, `HostClock`) `open`, `close`, `protocolError`, `recordAuthFailed`, `keysUnavailable`, `localClosed` çağrılarında geçiriliyor. (B1) `stopAll`/durdurma artık `closingFiles` içindeki soketleri de hemen kapatır (eski çalıştırmanın soketi yeniden başlatmadan sonra yaşayamaz). (B2) Geri basınç artık kuyruğa eklemeden ÖNCE denetlenir: Finder→tablet yönünde `hasRoom` (bekleyen + parça + 64 bayt çerçeve ≤ 64 KiB, aksi halde parça tutulur, okuma durur, ≤ 32 KiB'ta sürer; Finder kapanırken tutulan son parça tek istisna, bayt atılmaz); tablet→Finder yönünde çözücüden kayıt çekme (`pumpRecords`) Finder yazma tamponu ≥ 64 KiB iken durur ve dosya soketi okunmaz (< 32 KiB'ta ikisi de sürer): bağlantı ve yön başına en çok 64 KiB + çözülmekte olan tek kayıt. (B3) Özel 64 bayt `FILES_HELLO` sınırı kaldırıldı; 65 536 yük sınırına kadar uzantı baytlı HELLO kabul (kanıtsız bağlantı sınırı 2 belleği bağlar). Selftest'e eklendi: 4 MB'lık geç okuyan Finder ve 2 sn duran tablet (bayt bayt aynı), `peakBuffers` ile tamponların sınırı (denemede Finder→tablet 49 480 bayt, tablet→Finder 66 056 bayt), 65 baytlık HELLO kabulü. check.sh ALL OK, selftest birkaç koşuda geçti.
- **Varsayımlar:** (1) Host için Core dışında test hedefi yok (Package.swift kapsam dışı), o yüzden uçtan uca sınama komut satırı kipinde; Core testleri değişmedi. (2) `BsdTcpConnection` Core'da ve kapsam dışı olduğundan (okuma durdurma/`SO_SNDBUF`/BK yok) Host'ta kendi `FilesSocket` yazıldı. (3) `tick` 200 ms sabit zamanlayıcı (kapanış son tarihleri dahil `nextDeadline` en çok 200 ms gecikmeyle işlenir; sözleşme (3)'ten küçük sapma). (4) Selftest `host.log`'a (`~/Library/Logs/MateBridge/`) `component=files sid=7` satırları yazar (çalışan host'un günlüğüne karışır, zararsız).
- **Cihazda/gerçek ortamda doğrulanmadı:** gerçek tablet istemcisi (T-269) ile dosya bağlantıları ve kanıt; Wi-Fi'da gerçek NetFS bağlama + Finder; `FILES_NET(OPEN/CLOSE)` kontrol mesajının gerçekten gönderilmesi ve istemcinin STANDBY/READY akışı; `controlPeerHost`'un gerçek Wi-Fi bağlantısında eş adresi vermesi ve eşleşmesi (IPv4-mapped biçim); gerçek hız tavanının görüntüyü koruması; Finder çıkarması sonrası `FILES_NET(CLOSE)` + vekil kapanışı; uyku/uyanma ve devralmada dinleyici kapanışı; menü metinleri (Wi-Fi'da `.enableOnTablet` başlığı USB metnini kullanıyor).

## Open questions

- Kapsam sorusu yok. Orkestratör notu için: yukarıdaki varsayım (3) (sabit 200 ms tick) ve (4) (selftest günlük satırları).
