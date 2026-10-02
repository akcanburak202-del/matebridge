---
id: T-126
title: Host — kontrol (ses) ve video soketlerinin TCP durumunu saniyelik logla (yeniden gönderim, RTO, srtt, gönderilmemiş/onaylanmamış bayt)
status: todo
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

_(Ajan kodlamadan önce doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
