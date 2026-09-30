---
id: T-049
title: Mac — STREAM_PREFS: fps (60/120/144) ve küçültülmüş kodlama boyutu (performans modu)
status: todo
phase: 5
owner: mac-host-dev
depends_on: [T-045, T-047]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeHost/VirtualDisplay.swift
  - host-mac/Tests/
  - backlog/tasks/T-049-host-stream-prefs.md
---

## Amaç

Kullanıcı (2026-10-01): "120 çizim sırasında daha akıcı … daha pürüzsüz bir 120 veya hatta 144 için çözünürlüğü düşürebilir miyiz, performans modu gibi." Ölçümler NOTES 2026-10-01: Mac kodlayıcı 2800×1840'ta LLRC'siz 120 fps'e yetişiyor (T-047), darboğaz tablet çözücüsü (~105–110 fps tam boyutta). Protokol `proto/stream-prefs` dalında (`d642157`): `0x05 STREAM_PREFS(fps, scale_permille)`, `STREAM_CONFIG.width_px/height_px` artık kodlanan boyut. Kart dalı `main`'den açılır, `proto/stream-prefs` merge edilir. Tablet tarafı T-050 paralel; ikisi birlikte merge edilir.

## Kabul kriterleri

- [ ] **Kodek:** `StreamPrefs` mesajı; fixture `stream_prefs` bayt bayt.
- [ ] **Uygulama:** oturumda son tercih tutulur; fps ∈ {60, 120, 144} (başka → 60), scale 500–1000'e sıkıştırılır. Kodlanan boyut = sanal ekran piksel boyutu × scale, en-boy korunur, çift sayıya yuvarlanır. Sanal ekranın **boyutu ve nokta ölçüsü değişmez**; yenileme hızı fps'e göre (60 → env/varsayılan, 120 → 120 Hz, 144 → 144 Hz; mod yoksa en yakın, log). SCK `SCStreamConfiguration.width/height` = kodlanan boyut (ölçekleme SCK'da), `minimumFrameInterval` = 1/(2×fps), kodlayıcı boyutu ve ≥120'de T-047 yapılandırması.
- [ ] **Yeniden yapılandırma:** tercih değişince yeni `config_id` ile `STREAM_CONFIG`, video bağlantısı kapatılır (§3 adım 7; bugünkü kod yolu varsa onu kullan, yoksa kur). Aynı tercih → hiçbir şey. Saniyede en çok bir yeniden yapılandırma; arada gelenlerden en sonuncusu uygulanır. Sanal ekran yalnızca yenileme hızı değişirse yeniden yapılandırılır (mümkünse ekranı yıkmadan mod değiştirerek; değilse bugünkü yeniden yaratma yolu, pencerelerin taşınmaması için bekleme süresi dahil).
- [ ] `MATEBRIDGE_FPS` / `MATEBRIDGE_BITRATE_KBPS` ortam değişkenleri başlangıç değeri olarak kalır; STREAM_PREFS gelince tercih geçerli. Bit hızı: scale ve fps'e göre makul varsayılan (ör. taban 30 Mbps × fps/60 × scale², 20–80 Mbps arası) — sayıları Handoff'ta gerekçelendir.
- [ ] Log: `ev=stream_prefs fps=… scale=…`, `ev=stream_reconfigure …`. Testler: ayrıştırma/sıkıştırma, boyut hesabı (çift sayı, en-boy), aynı tercih no-op, hız sınırı, config_id artışı. `./scripts/check.sh` (T-050 ile birlikte) geçiyor.

## Kapsam dışı

- Tablet (T-050). Mac menüsünden seçim (gerekirse sonra). Cihaz testi orkestratörde.

## Plan

1. **Core (test edilir):** `StreamPrefs` mesajı (0x05) + fixture testi; `StreamPrefs.normalized` (fps ∈ {60,120,144} aksi 60, scale 500–1000); `VideoSettings.scalePermille`, kodlanan boyut (çift, en-boy korunur), `applying(prefs:)` (fps, sanal ekran yenileme hızı, bit hızı = 30 Mbps × fps/60 × scale², 20–80 Mbps), `nextConfigID`; `StreamPrefsGate` (saniyede en çok bir uygulama, en sonuncusu bekler); `DisplayLease.reconfigure` (aynı cihaz + aynı ekran boyutu → ekranı yıkmadan `.reconfigure`); `SessionMachine.reconfigure(sessionID:config:)` (yeni `config_id`, `STREAM_CONFIG` gönder, video bağlantısını kapat).
2. **Host:** `StreamCoordinator` STREAM_PREFS olayını (coalesced) işler, kapıdan geçirir, ayarı türetir, `onReconfigure` ile oturum makinesine yeni config bildirir, işlem hattını sanal ekranı koruyarak yeniden kurar (`VideoPipeline` ekranı devralabilir). `VirtualDisplay` 60/120/144 modlarını kaydeder ve modu yıkmadan değiştirir (olmazsa işlem hattı ekranı yeniden yaratır). SCK ve kodlayıcı kodlanan boyutu kullanır.
3. **Bağlantı:** `SessionServer.reconfigureStream`; `main.swift`'te tek satır bağlama (kart `files` listesinde yok, Açık sorulara yazıldı).
4. Sanal ekran değiştirme ve 144 Hz için tek seferlik sonda (scratchpad, depoya girmez).


## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
