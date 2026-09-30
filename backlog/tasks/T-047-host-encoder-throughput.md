---
id: T-047
title: Mac — HEVC kodlayıcı hız ölçümü (2800×1840'ta 120 fps mümkün mü?) ve ayar denemeleri
status: todo
phase: 5
owner: mac-host-dev
depends_on: [T-045]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - backlog/tasks/T-047-host-encoder-throughput.md
---

## Amaç

NOTES 2026-10-01 "120 fps ölçümü": yakalama 120,0 fps, ama VideoToolbox HEVC kodlayıcısı 2800×1840'ta bugünkü ayarlarla (RealTime, frame reordering kapalı, PrioritizeEncodingSpeedOverQuality, 30 Mbps) ~99 fps'te kalıyor (kodlama 20 ms, `enc_behind` ≈ 21/sn). 120 fps için kodlayıcının saniyede 120 kareye yetişmesi gerekiyor.

## Kabul kriterleri

- [ ] **Tezgâh modu:** `MateBridgeApp --encode-bench [--fps N] [--seconds S] [--config NAME]...`: ekran/SCK olmadan, 2800×1840 BGRA sentetik IOSurface kareler (her karede değişen, gerçekçi içerik: kayan desen + metin) üretip **olabildiğince hızlı** (ve ayrıca `--fps` hızında) kodlar; kodlayıcı çıkış hızını, kare başına süreyi (p50/p95/p99), bit hızını yazar. Kullanıcının ekranına dokunmaz, olay göndermez.
- [ ] **Denenecek yapılandırmalar** (her biri tezgâhta ölçülür, sonuç tablosu Handoff'ta): bugünkü; `RealTime=false`; `MaximizePowerEfficiency=false`; düşük gecikmeli hız denetimi (`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`); `ExpectedFrameRate` 120; farklı `ProfileLevel` (Main/Main10 AutoLevel); 20/30/50 Mbps; ve varsa **iki eşzamanlı oturum** (kareler sırayla iki oturuma, çıktı birleştirme gerekmeden ölçüm için) ya da donanım kodlayıcı sayısı (`VTCopyVideoEncoderList`, `kVTVideoEncoderList_…`).
- [ ] Tezgâhın en iyi yapılandırması 120 fps'e yetişiyorsa `HEVCEncoder`'da bu yapılandırma `MATEBRIDGE_FPS=120` iken kullanılır (60 fps varsayılanı değişmez). Yetişmiyorsa kod değişmez; bulgular Handoff'ta.
- [ ] `./scripts/check.sh` geçiyor. Tezgâh saf olmayan kısım; parametre ayrıştırma testli.

## Kapsam dışı

- Tablet (T-046). Canlı deney orkestratörde.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
