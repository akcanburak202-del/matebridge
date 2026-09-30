---
id: T-049
title: Mac — STREAM_PREFS: fps (60/120/144) ve küçültülmüş kodlama boyutu (performans modu)
status: review
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

- **Commit:** son commit `T-049: STREAM_PREFS on the host ...` (SHA orkestratöre raporda)
- **Dokunulan dosyalar:** Core: `Messages.swift` (`StreamPrefs`), `Message.swift`, `ProtocolConstants.swift` (0x05), `Video/StreamPrefsPolicy.swift` (yeni: kodlanan boyut, `applying(prefs)`, bit hızı, `nextConfigID`, `StreamPrefsGate`), `Video/VideoSettings.swift` (`scalePermille`, `sameDisplay`), `Video/DisplayLease.swift` (`.reconfigure`), `Session/SessionMachine.swift` (`reconfigure(sessionID:config:)`, STREAM_PREFS teslimi), `Input/InputStateMachine.swift` (exhaustive switch'e `.streamPrefs`). Host: `StreamCoordinator`, `SessionServer` (`reconfigureStream`), `VideoPipeline` (ekranı devralma), `VirtualDisplay`, `ScreenCapture`, `HEVCEncoder`. Testler: `FixtureTests`, `StreamPrefsTests` (yeni), `SessionMachineTests`. **Kart dışı 1 satır:** `MateBridgeApp/main.swift` (`coordinator.onReconfigure` bağlantısı; başka yolu yok).
- **Davranış:** STREAM_PREFS -> coordinator olayı (coalesced) -> kapı (1/sn, en sonuncusu tick'te) -> `base.applying(prefs)`; ayar değiştiyse yeni `config_id`, `onReconfigure` -> `SessionMachine.reconfigure` (STREAM_CONFIG + video kapat), ardından işlem hattı yeniden kurulur ve **sanal ekran korunur**. Yeniden bağlanmada aynı cihaz/boyut ama farklı ayar -> `lease` `.reconfigure` (ekran yıkılmaz). Başlangıç ayarı (env düğmeleri) oturum başında `base`; prefs `base`'in üzerine biner. Loglar: `stream_prefs`, `stream_reconfigure`, `stream_config_changed`, `display_reused restart=true`.
- **Sanal ekran yenileme hızı (gerçek cihazda ölçüldü, atılabilir sonda):** ekran 60/120/144 Hz modlarıyla yaratılıyor; `CGDisplaySetDisplayMode` ile **yeniden yaratmadan** 60<->120<->144 geçiş çalıştı (displayID aynı, nokta boyutu 1400x920 aynı, ~0,3 s). **144 Hz modu var** ve seçilebiliyor (`applied: 2800x1840px 1400x920pt 144Hz`). Mod değişmezse `VideoPipeline` eski ekranı bırakıp yenisini yaratır (yedek yol; bekleme eklenmedi, pencere taşınması bu yedekte olabilir).
- **Bit hızı gerekçesi:** `30 Mbps x fps/60 x scale^2`, 20–80 Mbps. 120/1000 -> 60, 144/1000 -> 72, 120/750 -> 33,75, 60/500 -> 20 (taban). Kare başına bit sabit tutuluyor, piksel sayısı scale^2 ile azalıyor. `MATEBRIDGE_BITRATE_KBPS` yalnızca başlangıç; prefs gelince formül geçerli.
- **Varsayımlar:** fps 60 için sanal ekran hızı `MATEBRIDGE_REFRESH` ya da 60. Kodlanan boyut: genişlik çift yuvarlanır, yükseklik genişliğe göre çift yuvarlanır (2100x1380, 1400x920). 1380 gibi 16'nın katı olmayan yükseklikte HEVC SPS kırpması (`HEVCSPS.swift` conformance window okuyor mu) doğrulanmadı.
- **Test edilmeyenler / cihazda doğrulanacaklar:** uçtan uca (tablet STREAM_PREFS gönderir, video yeniden açılır, yeni boyutta çözülür) T-050 ile; 144 fps'te kodlayıcı (`highRate` >= 120 yolu, 144'te ölçülmedi); SCK ölçekleme ve HEVC SPS ara boyutlarda; mod değişiminde Mac pencerelerinin yerinde kalması; reconfigure sırasında video açığı süresi. Uygulama çalıştırılmadı, olay gönderilmedi.
- **check.sh:** Swift tarafı tamam (488 test). Gradle (client-android) **1 başarısız**: `FixtureTest.everyFixtureFileHasATestCase`, yalnızca `stream_prefs` fixture'ının Kotlin karşılığı yok (T-050'de kapanır). Başka hata yok.
- **Açık sorular:** `main.swift` (kart `files` dışı) tek satır eklendi; reddedilirse bağlantı başka yerden kurulmalı.
