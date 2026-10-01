---
id: T-091
title: Mac — video bağlantısını çekirdek TCP soketine taşı (NWConnection kullanıcı alanı yığını Wi-Fi'de %4 yeniden gönderim) + TCP_NOTSENT_LOWAT
status: todo
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

(ajan doldurur, commit eder, sonra uygular)

## Handoff

