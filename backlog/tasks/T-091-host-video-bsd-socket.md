---
id: T-091
title: Mac — video bağlantısını çekirdek TCP soketine taşı (NWConnection kullanıcı alanı yığını Wi-Fi'de %4 yeniden gönderim) + TCP_NOTSENT_LOWAT
status: in-progress
phase: 5
owner: mac-host-dev
depends_on: [T-088]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeApp/main.swift
  - host-mac/Tests/
  - backlog/tasks/T-091-host-video-bsd-socket.md
---

## Amaç

Wi-Fi ölçümü (orkestratör, 2026-10-01 ~18:05; NOTES aynı tarih):
- MateBridge video akışı Wi-Fi'de ~27 Mbps'te doyuyor: 8–11 fps, gecikme 350–390 ms, gönderim kuyruğu 250–360 KB.
- Ham ağ kapasitesi aynı hatta ~410 Mbps (T-090, Python BSD soketi → tablet, iki yön). 250 KB'lık kare patlamaları 33 ms arayla da sorunsuz.
- `nettop -x`, Wi-Fi, aynı tablet:

  | bağlantı | mimari (`arch`) | yeniden gönderim |
  |---|---|---|
  | MateBridge video, `NWConnection` | `ch` (Skywalk, kullanıcı alanı TCP) | **%4,2** (1,22 MB / 29,3 MB) |
  | Python ham soket, aralıklı patlama | `so` (çekirdek TCP) | **0** |
  | Python ham soket, toplu gönderim | `so` | ~0 (7 KB / 355 MB) |

- Tabletteki okunmamış alım kuyruğu 0, yani tablet hemen okuyor. Kayıp Mac'in gönderim yığınından.
- Ayrıca `NWConnection` `TCP_NOTSENT_LOWAT`/`SO_SNDBUF` vermiyor. Gönderim kuyruğu sınırsız; "en yeni kare kazanır" kuralı Wi-Fi'de çalışmıyor (T-088 araştırması).

## Kabul kriterleri

- [ ] Yeni düğme `MATEBRIDGE_VIDEO_SOCKET=nw|bsd` (ilk sürümde varsayılan `nw`; ölçümden sonra orkestratör varsayılanı değiştirir). `bsd`'de video portu (47002) çekirdek BSD soketiyle dinlenir ve kabul edilir: `socket/bind/listen/accept` + `DispatchSource` ya da özel iş parçacığı.
  - `nettop` bu bağlantıyı `so` olarak göstermeli.
  - IPv4 ve IPv6 (bugünkü dinleyici `tcp6 *.47002`, ikisini de kabul ediyor) korunur.
  - `TCP_NODELAY` açık, `SO_KEEPALIVE` bugünkü davranışla uyumlu, `SO_NOSIGPIPE`.
- [ ] Video bağlantısının tüm protokol ve güvenlik davranışı aynen korunur: VIDEO_HELLO/ekleme, anahtar kanıtı (T-041..T-044), şifreli kayıtlar, devralma (takeover), oturum kapanınca kapatma, grace süresi. Mevcut `VideoTransport` soyutlaması (`VideoSender`) kullanılır; protokol ve fikstür değişmez.
- [ ] `bsd`'de `TCP_NOTSENT_LOWAT` (`MATEBRIDGE_NOTSENT_LOWAT_KB`, varsayılan 128). `canSend` soketin yazılabilirliğine bağlanır: gönderilmemiş bayt eşiği aşarsa yeni kare beklemez, **düşürülür** ("en yeni kare kazanır"). Sonra anahtar kare gerekmesin diye mevcut düşürme/anahtar kare mantığıyla uyumlu olmalı: bugün kodlayıcı tarafında `maxInFlight` ile atlanan kare nasıl ele alınıyorsa aynısı. Bunu Plan'da açıkla.
- [ ] Kısmi yazmalar doğru ele alınır (bir kayıt asla yarım kalıp başka kayıtla karışmaz). `EAGAIN` ve `EINTR` ele alınır. Kapanışta okuma/yazma kaynakları iptal edilir, fd tek kez kapatılır.
- [ ] `TcpSocketProbe` `bsd` yolunda fd'yi doğrudan kullanır (tarama yok). `ev=sendq` `source=tcp_info` ve `retx_pkts` verir.
- [ ] Log: `ev=listening ... video_socket=nw|bsd notsent_lowat_kb=…`.
- [ ] Testler: saf parçalar (kayıt çerçeveleme/kısmi yazma tamponu, eşik kararı) birim testli. Mümkünse loopback üzerinde gerçek bir `bsd` video bağlantısı entegrasyon testi (VIDEO_HELLO + birkaç kare + kapanış).
- [ ] `./scripts/check.sh` geçiyor.
- [ ] Kontrol bağlantısı (47001, girdi) bu kartta **değişmez**. Ama tasarım aynı soket katmanının ileride kontrol için de kullanılabileceği şekilde olsun (Wi-Fi'de kalem öbeklenmesi aynı nedenden olabilir; ayrı kart).

## Plan

Ön deney (scratchpad, Python, loopback): `TCP_NOTSENT_LOWAT=16 KB` iken `poll(POLLOUT, 0)` gönderilmemiş veri eşiği
aşınca "yazılamaz" diyor ama `send()` hâlâ kabul ediyor; eşik yokken `poll` ancak `EAGAIN`'de yazılamaz oluyor. Yani
XNU'da hem `poll` hem kqueue (`DispatchSourceWrite`) eşiği uyguluyor. Kapı bu sinyale bağlanır.

**Core (test hedefi yalnız `MateBridgeCore`'a bağlı; Package.swift kart dışında, bu yüzden soket katmanı Core'da)**

1. `Core/Session/TransportKnobs.swift`: `VideoSocketKnob` (`MATEBRIDGE_VIDEO_SOCKET=nw|bsd`, bilinmeyen → `nw`) ve
   `NotSentLowatKnob` (`MATEBRIDGE_NOTSENT_LOWAT_KB`, varsayılan 128, 16…4096 dışı/çöp → 128), `logFields`
   (`video_socket=… notsent_lowat_kb=…`; `nw`'de `notsent_lowat_kb=na`).
2. `Core/Session/SocketWriteBuffer.swift` (saf): kayıt kuyruğu + ofset. `drain(write:)` bir yazma kapanışı alır
   (testte sahte, gerçekte `write(2)`); kısmi yazmada ofset ilerler, `EINTR` → tekrar, `EAGAIN` → dur, diğer hata →
   `failed`. Tamamlanan kayıtların `completion`'ları sırayla döner. Bir kayıt asla başka kayıtla karışmaz (FIFO, tek ofset).
3. `Core/Session/BsdTcpSocket.swift`: `BsdTcpListener` (AF_INET6 + `IPV6_V6ONLY=0` → IPv4 de, `SO_REUSEADDR`,
   non-blocking, `FD_CLOEXEC`, `getsockname` ile port, kabul `DispatchSourceRead` ile oturum kuyruğunda; `EAGAIN/EINTR/
   ECONNABORTED` yok sayılır; `EMFILE/ENFILE/ENOBUFS/ENOMEM` → 1 s kabul duraklatma + log; diğer → `onFailed`) ve
   `BsdTcpConnection` (kabul edilen fd: `O_NONBLOCK`, `FD_CLOEXEC`, `TCP_NODELAY=1`, `SO_NOSIGPIPE=1`, `SO_KEEPALIVE`
   bugünkü gibi kapalı (`NWProtocolTCP.Options` varsayılanı), isteğe bağlı `TCP_NOTSENT_LOWAT`, `SO_NET_SERVICE_TYPE`
   (`MATEBRIDGE_SERVICE_CLASS` aynen eşlenir)). Okuma: `DispatchSourceRead` (sahip kuyruk = oturum kuyruğu), olay başına
   en çok `FrameDecoder.maxReadChunk`; 0 → EOF, `EAGAIN/EINTR` → bekle, diğer → kapan. Yazma: kilit altında
   `SocketWriteBuffer`'a ekle + hemen yaz; kalan varsa ayrı seri kuyruktaki `DispatchSourceWrite` açılır, boşalınca askıya
   alınır. `isWritableForNewRecord`: tampon boş **ve** `poll(POLLOUT,0)`; değilse yazma kaynağı kurulur, yazılabilir olunca
   `writableHandler` çağrılır. `completion`'lar her zaman asenkron (yazma kuyruğunda), asla `send` içinde değil.
   `cancel()`: idempotent; kilit altında `closed`, bekleyen `completion`'lar `false`, iki kaynak iptal (askıdaysa önce
   resume), fd **iki iptal işleyicisi de bittikten sonra tek kez** kapanır; `onClosed` oturum kuyruğunda bir kez.
   `connectionInfo()`: kilit altında, fd açıkken `TCP_CONNECTION_INFO`. Kontrol bağlantısı için de kullanılabilir genellikte.
4. `Core/Video/SocketVideoTransport.swift`: `VideoTransport` + kayıt mühürleme. `send`: kilit altında mühürle → yaz
   (sayaç sırası korunur). `canSend` = bekleyen kayıt yok ∧ soket eşik altında (`SocketVideoGate.canSend`, saf, testli).
   Mühürleme hatası nedeni döner (`VideoLink` bugünkü log/iptal davranışını korur).

**Eşik → düşürme → anahtar kare (bugünkü mantıkla aynı yol):** `VideoSender` kare çekmeden önce `canSend`'e bakar;
yanlışsa `onReady`'yi bekler ve kareler 2'lik `VideoFrameQueue`/`BoundedFrameQueue`'da kalır. Taşmada en eski delta
düşürülür, zincir kırıldığı için anahtar kare istenir ve anahtar kare gelene kadar deltalar reddedilir. Bu, bugün
`maxInFlight` dolunca olan şeyin aynısı; yeni düşürme yolu yok. Fark: `nw`'de kapı "2 gönderim bekliyor" (kullanıcı
alanında sınırsız kuyruk), `bsd`'de "çekirdekte gönderilmemiş bayt ≥ eşik" → kuyruk çekirdekte ~eşik+1 kayıtla sınırlı.

**Host**

5. `TcpSocketProbe`/`SendQueueSampler`: kaynak `nw(NWConnection)` (bugünkü tarama aynen) ya da `bsd(BsdTcpConnection)`
   (fd doğrudan, tarama yok, `source=tcp_info`, `retx_pkts`).
6. `VideoLink`: iç tel `nw` (bugünkü kod değişmeden) | `bsd(SocketVideoTransport)`. Genel API aynı.
7. `SessionServer`: video dinleyicisi ve bağlantıları `nw`/`bsd` sarmalayıcısı; `bsd`'de port planı (tercih → sistem)
   aynı, `listenersFailed`/`stop` ikisini de kapatır. `receiveVideoBytes`/kanıt/`apply` yolu ortak, değişmez.
   `ev=listening` satırına `video_socket=… notsent_lowat_kb=…`. Kontrol (47001) değişmez.
8. Testler: knob ayrıştırma, `SocketWriteBuffer` (kısmi/EINTR/EAGAIN/hata/sıra), kapı kararı; loopback entegrasyon:
   `BsdTcpListener` + istemci soketi: VIDEO_HELLO alınır, `SocketVideoTransport` ile birkaç mühürlü kare → istemci
   `RecordDecoder` ile çözer; düşük eşikte `canSend` yanlışa döner ve okuyunca `onReady` gelir; `cancel` → istemci EOF,
   `onClosed` bir kez; IPv4 (127.0.0.1) bağlantısı da kabul edilir.

## Handoff

