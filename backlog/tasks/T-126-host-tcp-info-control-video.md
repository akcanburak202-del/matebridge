---
id: T-126
title: Host — kontrol (ses) ve video soketlerinin TCP durumunu saniyelik logla (yeniden gönderim, RTO, srtt, gönderilmemiş/onaylanmamış bayt)
status: done
phase: 5
owner: mac-host-dev
depends_on: [T-124]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeCore/Video/SendQueueStats.swift
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-126-host-tcp-info-control-video.md
---

## Amaç

NOTES 2026-10-02 ~12:45 ve ~13:00. Wi-Fi'de ses paketleri (kontrol bağlantısı) zaman zaman 60–100 ms, bazen 250–340 ms geç varıyor. Aynı sırada Mac'ten 100 ms aralıklı ping (AP ve tablet):
- 11 800 pakette **kayıp 0**;
- en çok 29 ms (`signaling` testi sırasında).

Yani bağlantı kopmuyor. Gecikme TCP akışlarımızın içinde oluşuyor: gönderim kuyruğu, TCP yeniden gönderimi/RTO ya da tıkanıklık penceresi.

`TcpSocketProbe` (T-088) yalnız video için ve yalnız `MATEBRIDGE_SENDQ_LOG=1` ile çalışıyor. Ses yolu için hiç ölçüm yok.

## Kapsam dışı

- Düzeltme (UDP'ye geçiş, FEC vb. ölçüme göre ayrı karar).
- Tablet tarafı.

## Kabul kriterleri

- [x] Wi-Fi (`transport=wifi`) oturumunda varsayılan olarak, saniyede bir `ev=tcp` satırı her soket için (`conn=control|video`) yazılır. USB'de de çalışabilir ama gürültüyse `MATEBRIDGE_SENDQ_LOG` ile açılır; Plan'da karar. Alanlar `TCP_CONNECTION_INFO`'dan:
  - pencere başına artışlar: `retx_pkts_delta`, `rxmit_bytes_delta`, `ooo_pkts_delta`;
  - `srtt_ms`, `rttvar_ms`, `rto_ms`;
  - `snd_cwnd`, `snd_wnd`;
  - `unacked_bytes`, `notsent_bytes` (`tcpi_snd_sbbytes` vb.).
- [x] Bir ses yazımında (T-116 `send_gap`) ya da saniyede `retx` > 0 olduğunda debug satırında anlık kontrol soketi durumu.
- [x] Mevcut video `ev=sendq` satırıyla çakışmaz; mümkünse aynı örnekleyici kullanılır.
- [x] Maliyet: saniyede soket başına bir `getsockopt`.
- [x] Biçimlendirme Core'da, birim testli.
- [x] `docs/LOGGING.md` güncellenir. `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

1. **Core `Session/TcpInfoLog.swift`** (yeni):
   - `TcpConnectionSnapshot`: `tcp_connection_info`'dan alınan alanlar (`rto`, `srtt`, `rttvar`, `rttcur`, `snd_cwnd`, `snd_wnd`, `snd_ssthresh`, `snd_sbbytes`, `txpackets`, `txretransmitpackets`, `txretransmitbytes`, `rxoutoforderbytes`, `TCPCI_FLAG_LOSSRECOVERY`). Ayrıca host'un eklediği `userPendingBytes` (bsd kullanıcı alanı kuyruğu).
   - `TcpInfoMeter`: kümülatif sayaçlardan pencere başına artış. Bağlantının ilk penceresi 0 tabanlıdır, sayaç azalırsa artış 0 sayılır. `take` tabanı ilerletir. `peek` ilerletmez; debug anlık satırında son saniyelik örnekten bu yana artışı verir.
   - `TcpInfoLogKnob` (`MATEBRIDGE_TCP_LOG`): `0` kapalı, `1` her yerde. Ayarsız ya da başka değer `auto` olur: Wi-Fi'de açık, USB'de yalnız `MATEBRIDGE_SENDQ_LOG=1`/`MATEBRIDGE_LAT_TRACE=1` ile. **Karar:** USB loopback'te retx/RTT anlamsız, satır gürültü olur.
   - Biçim (yalnız sayı): `conn=control|video conn_id=<n> retx_pkts_delta= rxmit_bytes_delta= ooo_bytes_delta= tx_pkts_delta= srtt_ms= rttvar_ms= rttcur_ms= rto_ms= snd_cwnd= snd_wnd= ssthresh= sndbuf_bytes= unacked_bytes= notsent_bytes= user_pending_bytes=<n>|na loss_recovery=0|1`.
2. **Sapmalar (API sınırı):**
   - `tcp_connection_info` paket olarak sıra dışı sayaç vermez, yalnız alınan sıra dışı baytı (`tcpi_rxoutoforderbytes`) verir. Bu yüzden `ooo_pkts_delta` yerine `ooo_bytes_delta` yazılır. Bu sayaç tablet→Mac yönündedir.
   - Herkese açık API onaylanmamış ve gönderilmemiş baytı ayırmaz. `snd_sbbytes` ikisinin toplamıdır (`sndbuf_bytes`). Tahmin: `unacked_bytes = min(sbbytes, cwnd, snd_wnd)`, `notsent_bytes = sbbytes − unacked_bytes`. Nagle kapalı olduğundan pencere yetiyorsa her şey gönderilmiş sayılır. LOGGING.md'de tahmin olduğu yazılır.
3. **Host `TcpSocketProbe.swift`:** probe ham `tcp_connection_info` döndüren `connectionInfo()` kazanır, `sample()` (ev=sendq) bunun üstüne kurulur ve davranışı aynı kalır. Arama aralığı parametre olur, 1 Hz örnekleyicide 5 örnek. Yeni `TcpInfoSampler` (probe + meter) oturum kuyruğunda kullanılır, kilit yoktur. Aynı probe tipi kullanılır ama ayrı örnek: `ev=sendq` kare başına, `ev=tcp` saniyede bir; birbirine dokunmazlar.
4. **`SessionServer`:**
   - `.sessionStarted` kontrol bağlantısı için, `.videoAttached` video bağlantısı için örnekleyici açar. `transportClosed`/`closeControl` siler.
   - 100 ms tik'in her 10'unda bir (1 sn), etkinse her örnekleyiciden tam bir `getsockopt` alınır ve `I net ev=tcp …` yazılır. Okunamazsa bağlantı başına bir kez `W net ev=tcp_unavailable conn=… reason=…` yazılır (`nw` + Skywalk'ta tanımlayıcı olmayabilir).
   - `ev=send_gap` olduğunda (zaten saniyede ≤ 5) kontrol soketinden bir `getsockopt` daha alınır ve `D net ev=tcp_snap conn=control trigger=send_gap …` yazılır. Artışlar son saniyelik örnekten bu yanadır.
   - "Saniyede retx > 0" durumu: o saniyenin `ev=tcp` satırı zaten anlık durumu taşır. Ek `getsockopt` yapılmaz; maliyet kuralı (soket başına saniyede bir) bunu gerektirir.
   - `ev=listening` sonuna `tcp_log=auto|on|off` eklenir.
5. **Testler (`Session/TcpInfoLogTests.swift`):** snapshot eşlemesi, artışlar ve sayaç sıfırlanması, `peek` tabanı ilerletmez, tahmin sınırları, biçim, knob ayrıştırma ve transport kararı.
6. `docs/LOGGING.md`, `./scripts/check.sh`, Handoff.

## Handoff

- **Commit:** `749869f` (uygulama), plan `5b16eec`. Bu Handoff ayrı bir commit.
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Session/TcpInfoLog.swift` (yeni): `TcpConnectionSnapshot`, `TcpInfoMeter`, `TcpInfoReport`, `TcpConnectionRole`, `TcpInfoLogKnob`.
  - `host-mac/Sources/MateBridgeHost/Session/TcpSocketProbe.swift`: probe'a `connectionInfo()`, `userPendingBytes` ve arama aralığı parametresi eklendi. Yeni `TcpInfoSampler`. `sample()` (`ev=sendq`) davranışı aynı.
  - `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`: örnekleyici yaşam döngüsü, 1 sn tik, `send_gap` anlık satırı, `ev=listening tcp_log=`.
  - `host-mac/Tests/MateBridgeCoreTests/Session/TcpInfoLogTests.swift` (yeni, 9 test).
  - `docs/LOGGING.md`.
- **Varsayımlar:**
  - **USB kararı:** `auto` (varsayılan) USB'de kapalıdır. `MATEBRIDGE_SENDQ_LOG=1` ya da `MATEBRIDGE_LAT_TRACE=1` ile açılır. `MATEBRIDGE_TCP_LOG=1` her yerde açar, `0` her yerde kapatır. Transport, oturum başındaki `activeTransport`'tan alınır.
  - **`ooo_pkts_delta` yerine `ooo_bytes_delta`:** `tcp_connection_info` yalnız `tcpi_rxoutoforderbytes` veriyor. Bu sayaç tablet→Mac yönündedir.
  - **`unacked_bytes` / `notsent_bytes` tahmindir:** herkese açık API ikisini ayırmıyor. Tahmin `min(sbbytes, cwnd, snd_wnd)` ve kalan. Ham toplam `sndbuf_bytes` alanında da yazılıyor.
  - **"Saniyede retx > 0" kriteri:** ek `getsockopt` yapılmadı (maliyet kuralı). O saniyenin `ev=tcp` satırı okuma anının durumunu zaten taşıyor. `send_gap` anlık satırındaki (`D net ev=tcp_snap`) `retx_pkts_delta`, son saniyelik satırdan beri olan yeniden gönderimi gösteriyor.
  - Örnekleme oturum kuyruğundaki mevcut 100 ms tik'ten yapılıyor (her 10 tikte bir), ayrı bir zamanlayıcı yok. Örnekleyiciler oturum kuyruğuna ait, kilit yok.
  - `nw` bağlantılarında (`MATEBRIDGE_*_SOCKET=nw`) tanımlayıcı aranır, arama başarısızsa 5 örnekte bir yeniden denenir. Bulunamazsa bağlantı başına bir kez `W net ev=tcp_unavailable` yazılır. Varsayılan `bsd` soketlerde doğrudan okunur.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Host uygulaması yeniden başlatılmadı, cihaz testi yapılmadı. Doğrulanacaklar:
  1. Wi-Fi oturumunda `ev=listening ... tcp_log=auto` görülür. Ardından saniyede bir `I net ev=tcp conn=control` ve (video bağlıyken) `conn=video` satırı gelir, `transport=wifi` ile. `srtt_ms`, `snd_cwnd` gibi değerler makul olmalı (sıfır değil).
  2. USB oturumunda varsayılan olarak `ev=tcp` görülmez, `MATEBRIDGE_SENDQ_LOG=1` ile görülür.
  3. Debug açıkken (`log stream --level debug --predicate 'subsystem == "dev.matebridge.host"'`) her `audio ev=send_gap` satırının ardından `net ev=tcp_snap conn=control trigger=send_gap` gelir.
  4. Ses boşluğu anlarında `retx_pkts_delta`, `rto_ms`, `notsent_bytes` ve `user_pending_bytes` karşılaştırılır (asıl amaç).
  5. `MATEBRIDGE_SENDQ_LOG=1` ile video `ev=sendq` satırı eskisi gibi gelir (probe yeniden düzenlendi).
- **Açık sorular:** Yok.
