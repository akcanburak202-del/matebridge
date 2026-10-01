---
id: T-075
title: Mac — periyodik anahtar kare aralığı 10 s → isteğe bağlı (uzun güvenlik aralığı)
status: review
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

Yeni `KeyframeIntervalPolicy` (Core): `MATEBRIDGE_KEYFRAME_INTERVAL_S` ayrıştırma, varsayılan 300 s (TCP güvenilir, istek yolu var; 300 s oturum boyunca fiilen hiç, ama kaybolmuş istek için üst sınır), 0 = yalnız istek, üst sınır 3600. `HEVCEncoder` ve `EncodeBench` bu değeri kullanır; `cadence_setup` satırına `keyframe_interval_s=` ve encoder_read'e `MaxKeyFrameIntervalDuration` eklenir. İstek yolu değişmedi; `BoundedFrameQueue` testleri (delta düşünce keyframe isteği, T-058) zaten var ve geçiyor.

## Handoff

- **Commit:** tek commit, bkz. `git log task/T-075-host-keyframe-interval`
- **Dokunulan dosyalar:** Core/Video/KeyframeIntervalPolicy.swift (yeni), Tests/.../Video/KeyframeIntervalPolicyTests.swift (yeni), Host/Video/HEVCEncoder.swift, EncodeBench.swift, VideoPipeline.swift
- **Varsayımlar:** VT MaxKeyFrameIntervalDuration=0 "sınırsız" anlamına gelir; üst sınır 3600 s.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Kare izinde 10 s anahtar kare artık yok; cadence_setup satırında keyframe_interval_s=300 ve encoder_read MaxKeyFrameIntervalDuration; env=0 ile de dene.
- **Açık sorular:** yok
