---
id: T-092
title: Mac — video soketi varsayılanı `bsd` (T-091 ölçümü: Wi-Fi 372 → ~40 ms, yeniden gönderim 0)
status: todo
phase: 5
owner: mac-host-dev
depends_on: [T-091]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift
  - host-mac/Tests/
  - docs/LOGGING.md
  - backlog/tasks/T-092-host-video-bsd-default.md
---

## Amaç

T-091 cihaz A/B (orkestratör, 2026-10-01 ~18:35, Wi-Fi, kayan metin; NOTES aynı tarih):

| yol | fps | gecikme | durum |
|---|---|---|---|
| `nw` | 13 | 372 ms | ~28 Mbps tavanı |
| `bsd` | 52–54 | 37–49 ms | yeniden gönderim 0 |
| `bsd`, 60 Mbps yük | — | ~52 ms | 60 Mbps'i taşıdı |
| `bsd`, USB | — | 24 ms | normal |

`nw` yalnızca geri dönüş anahtarı olarak kalır.

## Kabul kriterleri

- [ ] `MATEBRIDGE_VIDEO_SOCKET` yoksa `bsd`. `nw` açıkça verilirse eski yol. Geçersiz değer → `bsd`.
- [ ] `TCP_NOTSENT_LOWAT` varsayılanı 128 KB kalır.
- [ ] Testler yeni varsayılana göre güncellenir.
- [ ] Varsa `docs/LOGGING.md`'de `video_socket` alanı belgelenir.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

Tek satırlık varsayılan değişikliği ve test güncellemesi.

## Handoff

