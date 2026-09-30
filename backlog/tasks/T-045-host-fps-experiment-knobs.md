---
id: T-045
title: Mac — 120 fps deneyi için ayar düğmeleri (MATEBRIDGE_FPS, MATEBRIDGE_BITRATE_KBPS) ve kodlama süresi ölçümü
status: todo
phase: 5
owner: mac-host-dev
depends_on: [T-017]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - backlog/tasks/T-045-host-fps-experiment-knobs.md
---

## Amaç

Faz 5, kullanıcının sorusu (2026-10-01): "USB ile daha akıcı ve daha yüksek yenileme hızı sağlanabilir mi?" Yeni ölçüm: tablet paneli MateBridge ön plandayken artık **120 Hz**'te çalışıyor (`dumpsys SurfaceFlinger`: aktif mod 120 fps, video katmanının vsync periyodu 8,33 ms; 29 Eylül'de 60 Hz'e kilitliydi). Uçtan uca 120 fps'in mümkün olup olmadığını ölçmek için host'ta akış fps'ini ve bit hızını ortam değişkeniyle değiştirebilmek gerekiyor. Bugün `VideoSettings.forTablet` fps'i 60'a sabitliyor; `MATEBRIDGE_REFRESH=120` yalnızca sanal ekranı 120 Hz yapıyor (T-017).

## Kabul kriterleri

- [ ] `MATEBRIDGE_FPS` = 60 | 90 | 120 (başka değer ya da yok → 60) akışın fps'ini belirler: `STREAM_CONFIG.fps`, SCK `minimumFrameInterval` (= 1/(2×fps), T-017 kuralı), `FrameGate`, `CadenceMeter` hedefi, kodlayıcının beklenen kare hızı / anahtar kare aralığı (ne varsa, saniye cinsinden aynı kalacak şekilde). `MATEBRIDGE_FPS=120` iken `MATEBRIDGE_REFRESH` verilmemişse sanal ekran 120 Hz olur.
- [ ] `MATEBRIDGE_BITRATE_KBPS` (5 000–150 000; dışı/yok → bugünkü varsayılan) hedef bit hızını belirler.
- [ ] Kodlama süresi ölçümü: `cadence` satırında kodlayıcıya giriş → çıkış süresi p50/p95/p99 (ms) zaten yoksa eklenir; yetişemeyen kodlayıcıda (giriş > çıkış) sayaç.
- [ ] `stream_session` log satırı fps, refresh ve bit hızını yazar.
- [ ] Saf ayrıştırma ve fps'e bağlı hesaplar birim testli. Varsayılan davranış (değişken yokken) birebir aynı kalır. `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Tablet tarafı, ayar arayüzü, kalıcı ayar. Deneyi orkestratör yürütür (host'u değişkenlerle başlatır, tablet çözücü istatistiklerini ve SurfaceFlinger ölçümlerini okur).

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
