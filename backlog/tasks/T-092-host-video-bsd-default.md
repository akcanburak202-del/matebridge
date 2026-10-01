---
id: T-092
title: Mac — video soketi varsayılanı `bsd` (T-091 ölçümü: Wi-Fi 372 → ~40 ms, yeniden gönderim 0)
status: review
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

- [x] `MATEBRIDGE_VIDEO_SOCKET` yoksa `bsd`. `nw` açıkça verilirse eski yol. Geçersiz değer → `bsd`.
- [x] `TCP_NOTSENT_LOWAT` varsayılanı 128 KB kalır.
- [x] Testler yeni varsayılana göre güncellenir.
- [ ] (uygun bölüm yok, atlandı — bkz. Handoff) Varsa `docs/LOGGING.md`'de `video_socket` alanı belgelenir.
- [x] `./scripts/check.sh` geçiyor.

## Plan

Tek satırlık varsayılan değişikliği ve test güncellemesi.

## Handoff

- **Commit:** `9f10188` (branch `task/T-092-bsd-default`, base `main` 1c798dc).
- **Dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift`: `VideoSocketKnob.parse` artık nil/boş/geçersiz → `.bsd`; yalnızca açık `nw` (büyük/küçük harf ve boşluk duyarsız) eski Network.framework yolunu seçer. Doc yorumları T-091 ölçümüyle güncellendi. `NotSentLowatKnob.defaultKB` 128 olarak değişmedi.
  - `host-mac/Tests/MateBridgeCoreTests/Session/SocketWriteBufferTests.swift`: `testVideoSocketKnob` (varsayılan/nil/boş/geçersiz → bsd, `nw`/` NW ` → nw), `testVideoSocketSettingsLogFields` (varsayılan `video_socket=bsd notsent_lowat_kb=128`, 131072 bayt; açık `nw` → `notsent_lowat_kb=na`).
- **`docs/LOGGING.md`:** dokunulmadı. Dosyada olay/alan başına belge bölümü yok (yalnızca satır formatı, gizlilik, sayaçlar). `video_socket`/`notsent_lowat_kb` için yeni bir bölüm açmak kapsam kararı olduğundan orkestratöre bırakıldı.
- **`./scripts/check.sh`:** ALL OK.
- **Varsayımlar:** `SessionServer` zaten `Self.videoSocket.socket == .bsd` ile dallanıyor, Host tarafında değişiklik gerekmedi. `SessionServer.swift:253` yorumu (`nw|bsd`) kapsam dışı ama hâlâ doğru.
- **Test EDİLMEDİ (cihaz):** host uygulaması başlatılmadı, `bundle-host.sh` çalıştırılmadı. Orkestratör doğrulamalı: env değişkeni olmadan başlatınca `ev=listening ... video_socket=bsd notsent_lowat_kb=128`; Wi-Fi'de gecikme ~40 ms / 50+ fps; USB yolu (24 ms) ve `MATEBRIDGE_VIDEO_SOCKET=nw` geri dönüşü hâlâ çalışıyor; bağlantı kopma/yeniden bağlanma bsd varsayılanıyla temiz.
- **Açık sorular:** yok.
