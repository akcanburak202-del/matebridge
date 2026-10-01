---
id: T-075
title: Mac — periyodik anahtar kare aralığı 10 s → isteğe bağlı (uzun güvenlik aralığı)
status: todo
phase: 5
owner: mac-host-dev
depends_on: [T-072]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/
  - backlog/tasks/T-075-host-keyframe-interval.md
---

## Amaç

Kare izi (2026-10-01 12:45): her **10,0 s**'de bir ~432 KB anahtar kare (`MaxKeyFrameIntervalDuration = 10`). Tablette alma ~15 ms gecikiyor (aktarım + ~11 ms şifre çözme), çözme de uzun → 10 saniyede bir küçük takılma. Taşıma TCP (güvenilir); kayıpta/çözücü hatasında tablet `KEYFRAME_REQUEST` gönderiyor, host T-030 ile yapılandırmayı da yeniden gönderiyor. Periyodik anahtar kareye gerek yok.

## Kabul kriterleri

- [ ] Varsayılan `MaxKeyFrameIntervalDuration` uzun (öneri: 300 s; gerekçelendir) ya da kapalı; `MATEBRIDGE_KEYFRAME_INTERVAL_S` ortam değişkeniyle geçersiz kılınabilir (0 = yalnız istek üzerine).
- [ ] İstek üzerine anahtar kare yolu (STARTUP, DECODE_ERROR, kuyruk düşürmesi sonrası) aynen çalışır; testlerle doğrula (`BoundedFrameQueue` delta düşürünce keyframe isteği, T-058).
- [ ] `ev=cadence_setup` satırında etkin aralık.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
