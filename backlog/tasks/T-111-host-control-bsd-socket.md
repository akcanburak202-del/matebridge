---
id: T-111
title: Mac — kontrol bağlantısını (girdi, ses, kontrol mesajları) çekirdek TCP soketine taşı (T-091'in kontrol karşılığı)
status: review
phase: 5
owner: mac-host-dev
depends_on: [T-091, T-092]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeApp/main.swift
  - host-mac/Tests/
  - backlog/tasks/T-111-host-control-bsd-socket.md
---

## Amaç

T-091/T-092 video bağlantısını NWConnection'dan (kullanıcı alanı TCP, Wi-Fi'de %4 yeniden gönderim) çekirdek BSD soketine taşıdı. Wi-Fi gecikmesi 372 ms'den ~40 ms'ye indi.

Kontrol bağlantısı hâlâ NWConnection. Bu bağlantıda şunlar var:
- C→H tüm girdi (kalem, klavye, touchpad);
- H→C ses paketleri (karar 0011, 100 paket/sn);
- kontrol mesajları.

Açık gözlemler:
- Wi-Fi'de kalem örnekleri bazen toplu geliyor (NOTES, memory).
- Oyun modunda ses paketlerinde 25–30 ms'lik gecikmeler var (T-110 analizi).

Aynı yığına geçmek iki tarafa da tutarlılık getirir.

## Kabul kriterleri

- [ ] Kontrol dinleyici ve bağlantıları çekirdek TCP soketiyle çalışır. T-091'deki video BSD soket yapısı yeniden kullanılır; kopya kod olmaz, ortak katman çıkarılabilir.
  - `TCP_NODELAY` açık.
  - Uygun `SO_SNDBUF`/`TCP_NOTSENT_LOWAT`, Plan'da gerekçesiyle. Ses ve küçük mesajlar için düşük gecikme öncelikli.
  - `SO_KEEPALIVE`/zaman aşımı davranışı NWConnection'dakiyle eşdeğer.
- [ ] `MATEBRIDGE_CONTROL_SOCKET=bsd|nw` ayarı (varsayılan `bsd`), video ayarıyla aynı kalıpta. `nw` eski yolu birebir korur. Seçilen yol `ev=` loglarında görünür.
- [ ] Davranış birebir aynı:
  - çerçeveleme, şifreleme, devralma (SUPERSEDED), BYE;
  - 5 sn HELLO zaman aşımı;
  - bağlantı kopunca release-all (§7);
  - USB tüneli (127.0.0.1) ve Wi-Fi;
  - `transport=` tespiti;
  - `TcpSocketProbe`/`ev=sendq` (gerekirse kontrol için de).
- [ ] Girdi asla takılı kalmaz: soket hatası, yarım kapanma ve EOF yolları release-all'u tetikler. Testlerle gösterilir.
- [ ] Ses gönderimi bloklanmaz; sınırlı kuyruk kuralı (§5, ses ≤100 ms) korunur.
- [ ] Testler: loopback üzerinde gerçek soketle HELLO→ACCEPTED→girdi→kopma→release-all; büyük ve küçük mesaj sırası; `nw` geri dönüşü.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde (USB ve Wi-Fi, kalem ve ses).

## Plan

T-091 soket katmanı (`BsdTcpListener`/`BsdTcpConnection`/`SocketWriteBuffer`, Core) aynen kullanılır; kopya yok. Eksik
iki parça eklenir: zarif kapanış (BYE flush + FIN) ve Bonjour yayını (bugün `NWListener.service` yapıyor).

**Core**

1. `TransportKnobs.swift`: `ControlSocketKnob` (`MATEBRIDGE_CONTROL_SOCKET=bsd|nw`, yok/boş/geçersiz → `bsd`, yalnız açık
   `nw` eski yol) + `logFields` (`control_socket=bsd|nw`).
2. `BsdTcpSocket.swift` → `BsdTcpConnection.finish(timeout:completion:)`: NW'deki `.finalMessage` + `cancel` karşılığı.
   Yeni yazma kabul edilmez; kuyruktaki kayıtlar yazılır, sonra `shutdown(SHUT_WR)` (FIN) ve `cancel()`. Bu sırada gelen
   baytlar atılır (NW'de alım döngüsü durur); EOF/hata → hemen `cancel`. `timeout` (2 sn) dolarsa yine `cancel`
   (NW'de okumayan eş bağlantıyı sonsuza dek tutabiliyordu). `completion` bir kez, kapanıştan sonra.
3. Yeni `BonjourAdvertiser.swift` (dns_sd `DNSServiceRegister`, sistem kütüphanesi, bağımlılık değil): `NWListener.Service`
   ile aynı ad (`hostName`, 63 bayta UTF-8 sınırında kısaltılır), tür `_matebridge._tcp`, TXT `v=1`, gerçek bağlı port.
   Ad çakışmasında dns_sd kendisi yeniden adlandırır (NW ile aynı). Saf yardımcılar (TXT kodlama, ad kısaltma) birim
   testli. Geri çağrılar sahibin kuyruğunda; `cancel` idempotent.

**Host (`SessionServer`)**

4. `ControlListener` (`network(NWListener)` | `socket(BsdTcpListener, BonjourAdvertiser?)`) ve `ControlConnection`
   (`network(NWConnection)` | `socket(BsdTcpConnection)`), video ile aynı kalıp. `bsd` dinleyici aynı port planını
   (tercih → sistem portu, `port_fallback`) kullanır. `ev=listening`'e `control_socket=…` eklenir.
5. Bağlantı başına mantık ortak kalır: `accept` sınırı (`maxUnauthenticated`), `ConnectionID`, `ControlInbound`,
   `receiveControlBytes`, `machine.connectionOpened/received/connectionClosed`, şifreleme, devralma, BYE, 5 sn HELLO
   zaman aşımı (`tick`). Yalnız bayt taşıma değişir:
   - okuma: `start(queue: queue, onBytes:onClosed:)`; `onClosed` → `transportClosed` → `machine.connectionClosed` →
     release-all (EOF, yarım kapanma, soket hatası, kendi `cancel`'ımız);
   - yazma: `write` + completion `queue`'ya atlar ve `inflightBytes`'ı düşürür (NW'deki `.contentProcessed` gibi);
     reddedilen yazma → `send_backlog` yolu (kapat + release);
   - `closeControl` → `finish(timeout: 2 sn)` + `flushGroup` (stop'taki 200 ms bekleme aynen);
   - `transport=`: `SessionTransport.classify(peerHost:)` (v4-mapped `::ffff:127.0.0.1` → usb).
   - `onBytes` false dönerse (bağlantı makine tarafından kapatıldıysa) zarif kapanış bozulmasın diye `cancel`
     istenmez; kapatılmadıysa (NW'de alım döngüsünün durduğu durum) `cancel` → release.

**Soket seçenekleri (kontrol) ve gerekçe**

- `TCP_NODELAY=1`: girdi/ses küçük kayıtlar, Nagle gecikmesi istemiyoruz (NW'de de açık).
- `SO_KEEPALIVE=0`: NW varsayılanı kapalı; canlılık protokol düzeyinde (PING + `heartbeat_timeout`, `SessionMachine`).
  Davranış eşdeğer kalsın diye değişmiyor. `SO_NOSIGPIPE=1`, `O_NONBLOCK`, `FD_CLOEXEC` (T-091 ile aynı).
- `TCP_NOTSENT_LOWAT` = `audioBacklogBytes − sealedAudioFrameBytes` (≈ 9 ses paketi, ~17,7 KB): ses kapısı.
  `drainAudio` bir AUDIO_FRAME'i, çekirdekte bu kadar gönderilmemiş bayt varsa (`!isWritableForNewRecord`, `poll`) atar.
  Böylece çekirdekte bekleyen ses ≤ eşik + 1 paket ≈ 100 ms (§5). NW'de yalnız kullanıcı alanı sayılabiliyordu; bsd'de
  kullanıcı alanı kontrolü (`inflightBytes + size ≤ audioBacklogBytes`) de aynen kalır. Eşik `write`'ı engellemez
  (T-091 ön deneyi): BYE, CLIPBOARD, PONG her zaman kuyruğa girer.
- `SO_SNDBUF`/`SO_RCVBUF`: çekirdek varsayılanı (otomatik ayar). Gecikmeyi belirleyen gönderilmemiş bayt eşiği
  zaten ayarlı; küçük `SO_SNDBUF` büyük CLIPBOARD'da gereksiz `send_backlog` kapanışı riski getirir. Okumayan eş
  yine `maxInflightBytes` (256 KiB, kullanıcı alanı) ile kapanır.
- `SO_NET_SERVICE_TYPE`: `MATEBRIDGE_SERVICE_CLASS` → `controlClass` (video ile aynı eşleme).
- Kullanıcı alanı kuyruk sınırı: `maxPendingBytes = maxInflightBytes`; asıl sınır `SessionServer`'daki sayaç.

**Testler (Core, loopback, gerçek soket)**

6. `ControlSocketKnob` ayrıştırma ve log alanı; `nw` geri dönüşü (açık `nw` → nw).
7. `finish`: kuyruktaki kayıtlar + FIN istemciye ulaşır (istemci EOF görür), sonra yeni `write` reddedilir;
   `completion` bir kez; zaman aşımında `cancel`; okuma atılır.
8. Uçtan uca: `BsdTcpListener` + test yapıştırıcısı (`SessionServer`'ın yönlendirmesiyle aynı) + gerçek
   `SessionMachine` + `TestClient`: HELLO → ACCEPTED (şifreli) → şifreli girdi `.deliver` → (a) istemci kapatır (EOF),
   (b) `shutdown(SHUT_WR)` yarım kapanma, (c) RST (`SO_LINGER 0`) → her birinde `releaseInput`.
9. Büyük + küçük kayıt sırası: küçük alım tamponlu istemciye büyük CLIPBOARD benzeri kayıt + ardından küçük kayıtlar;
   kısmi yazmalara rağmen sıra ve bütünlük korunur. Ses kapısı: istemci okumazken eşik dolunca
   `isWritableForNewRecord` false olur, okuyunca geri döner.
10. `BonjourAdvertiser`: TXT/ad yardımcıları; mümkünse yalnız yerel (`kDNSServiceInterfaceIndexLocalOnly`, test türü)
    kayıt + `DNSServiceBrowse` ile görünürlük.

Test edilemeyen: `SessionServer` Host hedefinde (test hedefi yalnız Core'a bağlı, `Package.swift` kart dışında); cihazda
USB/Wi-Fi, kalem, ses, Bonjour keşfi orkestratörde.

## Handoff

- **Commit:** `65a49e7` (uygulama), plan `dd061e3`; dal `task/T-111-host-control-bsd-socket` (taban `main` 8ff0d4a).
  `./scripts/check.sh` → ALL OK (host-mac XCTest 266, swift-testing 609; yeni 13 test). Yeni testler + T-091 soket
  testleri 5 kez art arda ve `--sanitize=thread` ile temiz geçti.
- **Dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift`: `ControlSocketKnob` (`MATEBRIDGE_CONTROL_SOCKET`,
    yok/boş/geçersiz → `bsd`, yalnız açık `nw` → eski yol; `logFields` `control_socket=bsd|nw`).
  - `host-mac/Sources/MateBridgeCore/Session/BsdTcpSocket.swift`: `BsdTcpConnection.finish(timeout:completion:)` (zarif
    kapanış: yeni yazma reddedilir, kuyruk yazılır → `shutdown(SHUT_WR)` → `cancel`; bu sırada okunan bayt atılır;
    zaman aşımında `cancel`; completion bir kez). Video yolu davranışı değişmedi (yalnız `finishing` bayrağı eklendi).
  - yeni `host-mac/Sources/MateBridgeCore/Session/BonjourAdvertiser.swift`: dns_sd `DNSServiceRegister` (sistem
    kütüphanesi, yeni bağımlılık değil). Ad 63 bayta UTF-8 sınırında kısaltılır, TXT `v=1`, ad çakışmasında
    mDNSResponder kendisi yeniden adlandırır. `cancel` idempotent, ref sahibin kuyruğunda serbest bırakılır.
  - `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`: `ControlListener`/`ControlConnection` enum'ları
    (video kalıbı), `startSocketControlListener` (aynı port planı + `port_fallback`), `acceptControl`, Bonjour
    kaydı/yeniden deneme, `closeControl` → `finish(2 sn)` + `flushGroup`, `sendControlBytes` → `write` (completion
    `queue`'ya atlar, `inflightBytes`), ses kapısı `kernelAudioBacklog`, `transport(of:)` → `peerHost`,
    `ev=listening … control_socket=…`.
  - yeni `host-mac/Tests/MateBridgeCoreTests/Session/ControlSocketTests.swift`.
  - `main.swift` değişmedi (düğme `SessionServer` içinde bir kez okunuyor, video düğmesi gibi).
- **Seçilen soket seçenekleri (kontrol):** `TCP_NODELAY=1`; `SO_KEEPALIVE=0` (NW varsayılanı; canlılık protokol
  heartbeat'i); `SO_NOSIGPIPE`, `O_NONBLOCK`, `FD_CLOEXEC`; `TCP_NOTSENT_LOWAT = audioBacklogBytes − sealedAudioFrameBytes`
  = 17 721 B (9 mühürlü 10 ms ses paketi) → çekirdekte gönderilmemiş ses ≤ ~100 ms (§5), `write`'ı hiç engellemez
  (BYE/CLIPBOARD/PONG her zaman gider; testte gösterildi); `SO_SNDBUF`/`SO_RCVBUF` çekirdek varsayılanı (gecikmeyi
  belirleyen gönderilmemiş bayt eşiği zaten ayarlı; küçük SNDBUF büyük CLIPBOARD'da gereksiz `send_backlog` kapanışı
  getirirdi); `SO_NET_SERVICE_TYPE` ← `MATEBRIDGE_SERVICE_CLASS` `controlClass`; kullanıcı alanı sınırı
  `maxInflightBytes` (256 KiB, bugünkü `send_backlog` yolu).
- **Kabul kriterleri:**
  - Ortak katman: T-091 `BsdTcpListener`/`BsdTcpConnection`/`SocketWriteBuffer` aynen; kopya yok.
  - Davranış: çerçeveleme/şifreleme/devralma/HELLO zaman aşımı/BYE `SessionMachine` + `receiveControlBytes` +
    `apply` üzerinden iki tel için ortak, değişmedi. `accept` sınırı aynı. USB: dual-stack `[::]` dinleyici,
    `::ffff:127.0.0.1` → `transport=usb` (testli).
  - Release-all: EOF, yarım kapanma (`SHUT_WR`), RST (`SO_LINGER 0`) ve sahte kayıt yollarının hepsinde
    `releaseInput` (testli, gerçek `SessionMachine` ile). Host kapanışında BYE(SHUTTING_DOWN) EOF'tan önce ulaşır.
  - `ev=sendq`/`TcpSocketProbe` kontrol için **eklenmedi** (kart "gerekirse" diyor; ölçüm ihtiyacı doğarsa
    `SendQueueSampler(socket:)` hazır).
- **Varsayımlar / davranış farkları (`bsd`):**
  - `onBytes` false (makine bağlantıyı kapatmadıysa) → `cancel` → release. NW'de bu durumda alım döngüsü sadece
    duruyordu; burada bağlantı kapanıyor (daha güvenli, "takılı girdi yok").
  - Zarif kapanış 2 sn içinde bitmezse kesilir; NW'de okumayan eş bağlantıyı süresiz tutabiliyordu. Kapanış
    sırasında eş EOF/hata verirse kalan kullanıcı alanı baytları atılır.
  - Bonjour hatası (kayıt anında veya sonradan, ör. mDNSResponder yeniden başlarsa) dinleyiciyi düşürmez, oturumları
    kesmez: `ev=bonjour_failed code=… retry_s=…`, 1…30 sn geri çekilmeyle yeniden kayıt. Başarıda
    `ev=bonjour_registered port=…` (ad loglanmaz). NW'nin bu durumdaki davranışı bilinmiyor.
  - Ses kapısı: `poll(POLLOUT)` her ses paketinde bir sistem çağrısı (100/sn), ihmal edilebilir.
- **Test EDİLMEDİ (cihaz/izin gerekir; host uygulaması başlatılmadı, çalışan oturuma dokunulmadı):**
  - `SessionServer` `bsd` kontrol yolu uçtan uca (Host hedefi testten erişilemez; testteki `ControlHost` aynı
    yönlendirmenin kopyası). `ev=listening … control_socket=bsd` satırı.
  - Tabletin Bonjour ile Mac'i bulması (`_matebridge._tcp`, ad, TXT `v=1`, port); yalnız yerel (LocalOnly) kayıt +
    browse testte doğrulandı. `nw` ile aynı adla görünmeli; port 47001 doluysa sistem portu yayınlanmalı.
  - USB (`adb reverse`, IPv4 loopback) ve Wi-Fi'de bağlanma, onay/eşleme, devralma (ikinci tablet bağlantısı),
    5 sn HELLO zaman aşımı, kablo/Wi-Fi kopunca release-all (kalem basılıyken), STREAM_PREFS sonrası video yeniden açma.
  - Wi-Fi'de kalem öbeklenmesinin ve oyun modundaki 25–30 ms ses boşluklarının değişip değişmediği; `nettop -x`'te
    kontrol bağlantısının `arch=so` görünmesi; ses düşme sayısı (`takeAudioWireDrops`) yük altında.
  - `MATEBRIDGE_CONTROL_SOCKET=nw` geri dönüşünün cihazda eski gibi çalışması.

### Open questions

- `docs/LOGGING.md`'de `control_socket` / `bonjour_*` olayları belgelenmedi (dosya kart dışında; T-092'deki gibi).
- Kalem öbeklenmesi bsd'de sürerse: Darwin'in ACK davranışı (`TCP_SENDMOREACKS`) ya da istemci tarafı ölçüm ayrı kart.
