---
id: T-122
title: Host — art arda gelen KEYFRAME_REQUEST'leri birleştir (bir IDR yoldayken yenisini zorlama); IDR boyutunu logla
status: todo
phase: 5
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-122-host-keyframe-request-coalesce.md
---

## Amaç

Cihaz (2026-10-02 ~11:00), T-121 ile aynı olay. Ses kesintilerinden önce host 100–300 ms içinde 4–6 `keyframe_request` alıyor (`reason=2`, arada `reason=0` + `codec_config_resent`) ve her birinde `requestKeyframe(resubmitNow: true)` çağırıyor. Sonuç: birden çok büyük IDR. O saniye `sent_kbps` 38 879 oldu (normalde 2–5 Mbps). Bağlantı doluyor ve ses 30–250 ms gecikiyor.

Bir IDR zaten kodlanmış ya da gönderilmekteyken gelen yeni istek, istemcinin henüz o IDR'yi görmemesinden kaynaklanır. Yeni bir IDR bunu çözmez, yükü katlar.

## Kapsam dışı

- Tablet tarafı kuyruk/istek politikası (T-121, paralel).
- IDR boyutunu düşürmek (QP/oran sınırı, intra refresh): ayrı karar. Bu kart yalnız ölçer.
- Protokol değişikliği.

## Kabul kriterleri

- [ ] **Birleştirme:** bir istekle zorlanan IDR'nin kodlanması ve sokete yazılması bitene kadar, ve yazımdan sonra kısa bir pencere boyunca (RTT + istemcinin çözme süresi; varsayılan 250 ms, Plan'da gerekçe) gelen `FRAMES_DROPPED` istekleri yeni IDR zorlamaz; yalnız sayılır.
  - `STARTUP` / `DECODE_ERROR` codec config gerektirdiği için config yeniden gönderilir.
  - Hemen önce gönderilmiş bir IDR varsa ikinci IDR zorlanmaz. Config + mevcut IDR'nin yeniden gönderilmesinin mümkün olup olmadığı Plan'da değerlendirilir.
  - Kural: istemci bir keyframe'i en geç pencere sonunda görür; birleştirme bir isteği asla sonsuza kadar yutmaz.
- [ ] Log: `ev=keyframe_request reason= action=forced|coalesced|config_resent since_idr_ms=`. Saniyelik `net ev=stats` satırına `idr=` (gönderilen IDR sayısı) ve `idr_bytes_max=` eklenir.
- [ ] `docs/LOGGING.md` güncellenir.
- [ ] Birleştirme mantığı Core'da, birim testli (sahte saat): tek istek → IDR; 4 istek / 200 ms → 1 IDR; pencere sonrası istek → yeni IDR; STARTUP → config yeniden gönderimi.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
