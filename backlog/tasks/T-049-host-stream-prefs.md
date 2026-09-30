---
id: T-049
title: Mac — STREAM_PREFS: fps (60/120/144) ve küçültülmüş kodlama boyutu (performans modu)
status: done
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
- **Tur 1 düzeltmeleri (cihaz geri bildirimi):**
  1. **Kök neden (atılabilir sondayla ölçüldü, AppKit animasyon penceresi + SCStream, 2800x1840):** yerinde mod değiştirme (`CGDisplaySetDisplayMode` 60->120) CVDisplayLink vsync'ini 120'ye çeker ama **SCK 60 fps'te kalır** (yeni SCStream ile bile: 63 fps; ara mod/144 dolaşımı da işe yaramadı). Doğrudan 120 Hz yaratılan ekranda 120-126 fps. Yani SCK, ekranın yaratıldığı yenileme hızına bağlı. Düzeltme: yenileme hızı değişince ekran **yeniden yaratılır**; `VirtualDisplay` tek moda döndürüldü (çoklu mod ve `setRefreshRate` kaldırıldı). Hız aynıysa (yalnızca scale/fps aynı Hz'de) ekran korunur, yalnızca yakalama+kodlayıcı yeniden kurulur. Not: önceki "yeniden yaratmadan geçiş çalışıyor" bulgum yalnızca mod/vsync'i ölçmüştü, SCK'yı değil; yanlıştı.
  2. Oturum kimliği: `STREAM_PREFS` olayı girişte canlı oturum kimliğiyle damgalanır (`sessionStarted/Ended` ile aynı kuyruktan sırayla), birleştirme anahtarı kimliği içerir (oturumlar arası birleşme yok), işleyici mevcut oturum değilse atar (`stream_prefs_dropped`).
  3. Yenileme hızı değişmediyse mod/ekran işi yok. Hız değişince yedek yerine asıl yol: eski ekran önce bırakılır, 0,7 s beklenip yenisi yaratılır, log `display_recreate reason=refresh_change`. **Yeni ekranı eskisi ayakta yaratmak mümkün değil:** aynı vendor/product/serial ile ikinci `CGVirtualDisplay` `nil` döndü (ölçüldü). Bu yüzden Mac pencereleri 60<->120/144 geçişinde ekrandan kaybolup yeniden görünebilir (mevcut yeniden yaratma yoluyla aynı).
  4. Aynı Hz'de (örn. 120 Hz'de scale 1000<->750) ekran korunur.
- **Tur 2 (hatırlanan tercih):** host cihaz başına son uygulanan prefs'i UserDefaults'ta (`streamPrefsByDevice`, en çok 16 cihaz, `UserDefaultsStreamPrefsStore`) tutar; oturum başında hem `STREAM_CONFIG` (`streamConfig(for:)`) hem `sessionStarted` ayarı `base + kayıtlı prefs` ile türetilir (`VideoSettings.initialSettings`, Core). Bilinmeyen cihaz ve env düğmeleri: `base` (varsayılan) aynen; kayıtlı prefs env'in üstüne biner. Kayıt `applyPrefs` başında (değişim olmasa da) yazılır. Sonuç: tablet varsayılanı Smooth(120) ise ilk bağlantıda bir kez yeniden yaratma olur, sonraki bağlantılarda ilk STREAM_PREFS kayıtlıyla aynı, ekran (grace'te de) aynen korunur, yeniden yapılandırma yok. Log: `stream_session device=<4 bayt hex> from_stored=...`. Testler: kayıtlı kullanılır / bilinmeyen cihaz varsayılan / env varsayılanı + kayıtlı üstte / grace'te `.reuse` / `shortHex`. Kalan: ilk HELLO'dan sonra ilk bağlantıda (kayıt yok) 60'tan 120'ye bir kez yeniden yaratma kaçınılmaz; `STREAM_CONFIG` ile oturum başlangıcı ayarı aynı kayıttan okunur (araya başka oturumun kaydı girerse tutarsızlık olası, pratikte aynı değer).
- **144 Hz:** çoklu-mod denemesinde 144 Hz modu sanal ekranda listelendi ve seçilebildi; 144'te SCK/kodlayıcı fps'i ölçülmedi. Şimdiki kod 144 Hz'i `displayRefreshHz=144` ile doğrudan yaratır (mod listesi yalnızca o hızı içerir).
- **Bit hızı gerekçesi:** `30 Mbps x fps/60 x scale^2`, 20–80 Mbps. 120/1000 -> 60, 144/1000 -> 72, 120/750 -> 33,75, 60/500 -> 20 (taban). Kare başına bit sabit tutuluyor, piksel sayısı scale^2 ile azalıyor. `MATEBRIDGE_BITRATE_KBPS` yalnızca başlangıç; prefs gelince formül geçerli.
- **Varsayımlar:** fps 60 için sanal ekran hızı `MATEBRIDGE_REFRESH` ya da 60. Kodlanan boyut: genişlik çift yuvarlanır, yükseklik genişliğe göre çift yuvarlanır (2100x1380, 1400x920). 1380 gibi 16'nın katı olmayan yükseklikte HEVC SPS kırpması (`HEVCSPS.swift` conformance window okuyor mu) doğrulanmadı.
- **Test edilmeyenler / cihazda doğrulanacaklar:** uçtan uca (tablet STREAM_PREFS gönderir, video yeniden açılır, yeni boyutta çözülür) T-050 ile; 144 fps'te kodlayıcı (`highRate` >= 120 yolu, 144'te ölçülmedi); SCK ölçekleme ve HEVC SPS ara boyutlarda; mod değişiminde Mac pencerelerinin yerinde kalması; reconfigure sırasında video açığı süresi. Uygulama çalıştırılmadı, olay gönderilmedi.
- **check.sh:** Swift tarafı tamam (488 test). Gradle (client-android) **1 başarısız**: `FixtureTest.everyFixtureFileHasATestCase`, yalnızca `stream_prefs` fixture'ının Kotlin karşılığı yok (T-050'de kapanır). Başka hata yok.
- **Açık sorular:** `main.swift` (kart `files` dışı) tek satır eklendi; reddedilirse bağlantı başka yerden kurulmalı.

## Orkestratör notu (merge, 2026-10-01)

- Codex (medium) bir tur: iki P2 (tercihlerin oturum sınırını aşması, ekran yeniden yaratma yedeği) düzeltildi. Cihazda bulunan: yenileme değişiminden sonra SCK 60'ta kalıyordu → ekran yeniden yaratma; cihaz başına tercih hafızası. Ölçümler NOTES 2026-10-01 "Performans modu cihazda". `MateBridgeApp/main.swift` tek satır (kapsam dışı, onaylandı).
