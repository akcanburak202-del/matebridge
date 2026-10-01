---
id: T-106
title: Mac — STREAM_PREFS.bitrate_kbps uygulaması ve menüde "Tablette ayarları aç" (SETTINGS_OPEN)
status: review
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

- **Commit:** `e02da1e` (kod + testler), plan `c76d1a6`; dal `task/T-106-host-bitrate-pref-settings-menu` (main `0a329b5` üstünde).
- **check.sh:** geçti (host-mac build + 588 Swift Testing testi + XCTest, probes, client-android, fixtures `--check`, crypto vectors).
- **Dokunulan dosyalar:**
  - Core: `Video/{StreamPrefsPolicy,StreamPrefsStore,TransportBitrate,VideoSettings,EncoderKnobs}.swift`, `Session/SessionMachine.swift`.
  - Host: `Session/{StreamCoordinator,SessionServer,UserDefaultsStreamPrefsStore}.swift`.
  - App: `main.swift`.
  - Testler: yeni `Tests/MateBridgeCoreTests/Video/BitratePrefsTests.swift` (12 test), `Session/SessionMachineTests.swift`'e 4 test.
  - `Input/` dizinlerine dokunulmadı.
- **Davranış:**
  - **Bit hızı:** `applying(_:)` önceliği env (`MATEBRIDGE_BITRATE_KBPS`, Wi-Fi'de `MATEBRIDGE_WIFI_BITRATE_KBPS`) > `bitrate_kbps ≠ 0` (5000–150000'e sıkıştırılır) > mod varsayılanı. `bitrate_source=user` yeni değer. `STREAM_CONFIG.bitrate_kbps` her zaman uygulanan değer.
  - **Yeniden yapılandırma:** mevcut `applyPrefs` yolu (yeni `config_id`, gate saniyede bir, aynı tercih = değişiklik yok). Yalnızca bit hızı değişince refresh aynı kalır: `DisplayLease` → `.reconfigure`, `restartPipeline` sanal ekranı korur, yalnızca yakalama + kodlayıcı yeniden kurulur. Canlı VT özellik değişikliği yapılmadı (gerekçe Plan 2'de).
  - **Loglar:** `stream_prefs` artık `bitrate_kbps=<sıkıştırılmış|default> requested_bitrate_kbps=<ham>` yazar. `stream_reconfigure` `bitrate_kbps=old->new` yazar.
  - **Hatırlama:** UserDefaults kaydı `[fps, scale, bitrate]` biçiminde. Eski `[fps, scale]` kayıtları bit hızı 0 (mod varsayılanı) olarak okunur. Bit hızı ham saklanır, uygulanırken sıkıştırılır.
  - **Menü:** "Tablette ayarları aç" öğesi video satırının altında. Yalnızca ACCEPTED oturum varsa ve HELLO bit9 bildirildiyse görünür, aksi halde gizli. Tıklanınca `SessionServer.openSettingsPanel()` → `SessionMachine.openSettingsPanel()`. Makine durumu yeniden kontrol eder: uygunsa `SETTINGS_OPEN` + `ev=settings_open_sent`; değilse gönderim yok, yalnızca `ev=settings_open_skipped reason=no_session|no_capability`.
- **Varsayımlar:**
  - Env geçersiz kılması varken tabletin bit hızı `userBitrateKbps`'e hiç yazılmaz. Bu yüzden env altında yalnızca bit hızı değişen bir tercih yeniden yapılandırma yapmaz.
  - Kullanıcı mod varsayılanına eşit bir değer seçerse (ör. Netlik'te Otomatik → 30 Mbps) ayarlar yine "değişti" sayılır, çünkü kaynak `prefs` → `user` oluyor. Sonuç: aynı bit hızıyla bir yeniden yapılandırma (yeni `config_id`, kısa video kesintisi). Bilinçli kabul edildi: kullanıcı değeri sonraki mod değişikliklerinde sabit kalır, varsayılan ise değişir.
  - `MATEBRIDGE_QUALITY` açıkken (deney) kodlayıcı `AverageBitRate` koymaz, bit hızı yalnızca `DataRateLimits` tavanını (2×) belirler. Bu davranış değişmedi.
  - Menü görünürlüğü `DispatchQueue.main.async` ile FIFO güncellenir. `stateChanged` ile arada kısa bir sıra farkı olabilir; zararsızdır, çünkü gönderim kararını makine verir.
- **Test edilmeyenler (orkestratörde, gerçek cihazla):**
  - Gerçek oturumda tablet bit hızı seçimi (T-105 paneli gelince): log'da `bitrate_source=user`, `STREAM_CONFIG`'te değer, video kesintisi kısa ve `display_recreate` yok.
  - Bağlantı kesilip tekrar bağlanınca hatırlanan bit hızı (`stream_session ... bitrate_source=user`).
  - Mevcut UserDefaults kaydı (`[fps, scale]`) olan bir Mac'te ilk açılış.
  - Menü öğesi: eski istemciyle gizli; bit9 gönderen istemciyle (T-105) görünür; tıklayınca tablette panel açılıyor ve `settings_open_sent` log'u yazılıyor.
  - Uygulama başlatılmadı, gerçek oturum açılmadı (talimat gereği).

### Open questions

- Yok.
