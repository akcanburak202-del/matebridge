---
id: T-106
title: Mac — STREAM_PREFS.bitrate_kbps uygulaması ve menüde "Tablette ayarları aç" (SETTINGS_OPEN)
status: in-progress
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

1. **Bit hızı politikası (Core, `Video/StreamPrefsPolicy.swift`, `TransportBitrate.swift`, `VideoSettings.swift`, `EncoderKnobs.swift`):**
   - `BitrateSource.user = "user"`.
   - `VideoSettings.userBitrateKbps: Int?` (yeni alan): tabletin sıkıştırılmış tercihi; env/wifi_env geçersiz kılma varken `nil` tutulur (böylece env altında yalnızca bit hızı değişen tercih "değişiklik yok" sayılır).
   - `VideoSettings.clampedUserBitrateKbps(_ raw: UInt32) -> Int?`: `0` → `nil`, değilse `5000…150000`.
   - `applying(_:)`: `bitrateKbps = bitrateOverrideKbps ?? userBitrateKbps ?? defaultBitrateKbps(...)`.
   - `bitrateSource`: override → `env`/`wifi_env`; yoksa `userBitrateKbps != nil` → `user`; yoksa `prefs`.
2. **Yeniden yapılandırma:** mevcut yol aynen kullanılır (`StreamCoordinator.applyPrefs` → yeni `config_id`, `STREAM_CONFIG`, gate saniyede bir, aynı tercih = değişiklik yok). Yalnızca bit hızı değişince `displayRefreshHz` aynı kaldığı için `DisplayLease.reconfigure` → `.reconfigure` ve `restartPipeline` sanal ekranı korur; yalnızca yakalama + kodlayıcı yeniden kurulur. Canlı VT özellik değişikliği seçilmedi: yeni `config_id` video bağlantısını zaten kapatıp açtırıyor (PROTOCOL 3.7), yeniden kurulum temiz anahtar kare/parametre setiyle başlar ve `STREAM_CONFIG` ile tutarlılık garanti. `stream_prefs` log'una `requested_bitrate_kbps=` eklenir.
3. **Hatırlama (T-049):** saklama biçimi Core'da `StreamPrefsStorageCodec` (`[fps, scale, bitrate]`; eski `[fps, scale]` kayıtları `bitrate=0` olarak okunur). `UserDefaultsStreamPrefsStore` bunu kullanır. `InMemoryStreamPrefsStore` zaten tüm `StreamPrefs`'i saklar.
4. **SETTINGS_OPEN (Core `SessionMachine`):** `Session`'a `capabilities` eklenir. `settingsPanelAvailable: Bool` (aktif oturum + bit9) ve `openSettingsPanel() -> [SessionAction]`: uygunsa `.send(cid, .settingsOpen)` + `log ev=settings_open_sent`; değilse yalnızca `log ev=settings_open_skipped reason=no_session|no_capability` (gönderim yok).
5. **Host/App:** `SessionServer.openSettingsPanel()` (kuyrukta `machine.openSettingsPanel()` uygular), yeni handler `settingsPanelAvailable(Bool)` `refreshState` içinde değişince çağrılır. Menüde "Tablette ayarları aç" öğesi; uygun değilken gizli.
6. **Testler (Core):** öncelik tablosu (env / wifi_env / kullanıcı / mod) ve sıkıştırma; yalnızca bit hızı değişince lease `.reconfigure` + aynı refresh; aynı tercih tekrarında değişiklik yok; env altında bit hızı tercihi değişiklik yaratmaz; saklama codec'i (yeni + eski biçim); `SessionMachine` capability yokken/oturum yokken `SETTINGS_OPEN` göndermez, varken gönderir.

## Handoff
