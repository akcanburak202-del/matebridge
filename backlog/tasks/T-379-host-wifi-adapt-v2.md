---
id: T-379
title: Host — WIFI_ADAPT v2: yalnız bit hızı, doğrulanmış tıkanıklık kanıtı, IDR'sız (astra öneri 1)
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-378]
decisions: [0023]
files:
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - docs/KNOBS.md
  - tools/measure/
  - backlog/tasks/T-379-host-wifi-adapt-v2.md
---

## Amaç

`docs/reviews/2026-10-25/astra-wifi-game.md` öneri 1. Başlamadan önce orkestratör 0023'e kontrol yasası ekini yazar (sabitler, taban 30 / acil 20, artış hızı); bu kartın Plan'ı o eke dayanır. Kart o ek yazılana kadar başlamaz.

## Kabul

(0023 eki yazılınca doldurulur.) Taslak: ek kabul kapısı kaldırılır; yalnız canlı kodlayıcı bit hızı değişir (akış yeniden başlamaz, IDR yok); kanıt = srtt fazlası kalıcılık + birikim boşalmıyor, ya da 1 sn penceresinde yeniden gönderim oranı; tabanda kapı sıkılaşmaz; `sent_kbps` `bitrate_set`'i izliyor mu doğrulanır; `game_ab.py`'ye gösterim boşluğu sayımı. Varsayılan kapalı; cihaz A/B'sinden sonra karar.

## Plan

## Handoff

## Open questions
