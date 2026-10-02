---
id: T-126
title: Host — kontrol (ses) ve video soketlerinin TCP durumunu saniyelik logla (yeniden gönderim, RTO, srtt, gönderilmemiş/onaylanmamış bayt)
status: in-progress
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

- [ ] Wi-Fi (`transport=wifi`) oturumunda varsayılan olarak, saniyede bir `ev=tcp` satırı her soket için (`conn=control|video`) yazılır. USB'de de çalışabilir ama gürültüyse `MATEBRIDGE_SENDQ_LOG` ile açılır; Plan'da karar. Alanlar `TCP_CONNECTION_INFO`'dan:
  - pencere başına artışlar: `retx_pkts_delta`, `rxmit_bytes_delta`, `ooo_pkts_delta`;
  - `srtt_ms`, `rttvar_ms`, `rto_ms`;
  - `snd_cwnd`, `snd_wnd`;
  - `unacked_bytes`, `notsent_bytes` (`tcpi_snd_sbbytes` vb.).
- [ ] Bir ses yazımında (T-116 `send_gap`) ya da saniyede `retx` > 0 olduğunda debug satırında anlık kontrol soketi durumu.
- [ ] Mevcut video `ev=sendq` satırıyla çakışmaz; mümkünse aynı örnekleyici kullanılır.
- [ ] Maliyet: saniyede soket başına bir `getsockopt`.
- [ ] Biçimlendirme Core'da, birim testli.
- [ ] `docs/LOGGING.md` güncellenir. `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

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

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
