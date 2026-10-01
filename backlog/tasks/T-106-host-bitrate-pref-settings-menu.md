---
id: T-106
title: Mac — STREAM_PREFS.bitrate_kbps uygulaması ve menüde "Tablette ayarları aç" (SETTINGS_OPEN)
status: todo
phase: 4
owner: mac-host-dev
depends_on: [T-104]
decisions: [0013]
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Tests/
  - backlog/tasks/T-106-host-bitrate-pref-settings-menu.md
---

## Amaç

Karar 0013, iki iş:
- tablet bit hızını `STREAM_PREFS.bitrate_kbps` ile seçer;
- Mac menüsünden tablete ayarlar paneli açtırılabilir (`SETTINGS_OPEN`).

## Kabul kriterleri

- [ ] **Bit hızı tercihi** (PROTOCOL.md §4 0x05 host kuralları):
  - `bitrate_kbps = 0` → mod varsayılanı (`defaultBitrateKbps`, bugünkü davranış).
  - Sıfırdan farklıysa `5000…150000` aralığına sıkıştırılır ve uygulanır.
  - Öncelik: env (`MATEBRIDGE_BITRATE_KBPS`, Wi-Fi'de `MATEBRIDGE_WIFI_BITRATE_KBPS`) > kullanıcı > mod varsayılanı.
  - Log `bitrate_source=` yeni bir değer alır: `user`.
- [ ] Tercih değişimi mevcut yeniden yapılandırma yolunu kullanır: yeni `config_id`, `STREAM_CONFIG.bitrate_kbps` uygulanan değer, saniyede en çok bir kez, aynı tercih tekrar gelirse bir şey olmaz.
  - **Yalnızca bit hızı değiştiyse** sanal ekran yeniden yaratılmaz; yalnızca kodlayıcı ayarı değişir.
  - Kodlayıcıyı yeniden kurmadan canlı değiştirmek (`kVTCompressionPropertyKey_AverageBitRate` / `DataRateLimits`) mümkün ve güvenliyse Plan'da tercih edilebilir, ama `STREAM_CONFIG`'teki değer her zaman uygulanan değerle tutarlı olmalı.
- [ ] Cihaz başına hatırlanan tercih (T-049) bit hızını da içerir.
- [ ] **Menü:** "Tablette ayarları aç" öğesi.
  - Yalnızca `ACCEPTED` bir oturum varsa ve istemci HELLO bit9 `SETTINGS_PANEL` bildirdiyse etkin; yoksa gizli ya da devre dışı.
  - Tıklanınca kontrol bağlantısından `SETTINGS_OPEN` gönderilir.
  - Log: `ev=settings_open_sent`.
- [ ] Testler:
  - öncelik tablosu (env/kullanıcı/mod) ve sıkıştırma;
  - yalnızca bit hızı değişince ekranın yeniden yaratılmaması (policy düzeyinde);
  - tercih hatırlama;
  - capability yokken `SETTINGS_OPEN` gönderilmemesi.
- [ ] `./scripts/check.sh` geçiyor. Gerçek oturum ve cihaz testi orkestratörde.

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff
