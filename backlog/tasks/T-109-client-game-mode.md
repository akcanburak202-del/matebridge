---
id: T-109
title: Tablet — "Oyun" görüntü modu (120 fps, %66, jitter 0) ve geçici oyun varsayılanları
status: in_progress
phase: 5
owner: android-client-dev
depends_on: [T-105, T-107]
decisions: [0014, 0013]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/test/
  - backlog/tasks/T-109-client-game-mode.md
---

## Amaç

Karar 0014: oyunlara özel görüntü modu ve oyun moduyla gelen ama kalıcı olmayan varsayılan ayarlar.

## Kabul kriterleri

- [ ] `StreamMode` içine `GAME("game", "Oyun", 120, 660)` eklenir.
  - Mod döngüsüne (Ctrl+Shift+7), bağlantı paneline ve yan panele girer.
  - Kayıtlı mod olarak saklanabilir.
  - Bilinmeyen değerlerde mevcut geri düşüş kuralı korunur.
- [ ] **Gecikme:** oyun modunda video jitter tamponu 0'dır (`VideoRenderer.bufferFrames = 0`, çalışırken değişir). Moddan çıkınca önceki değer geri gelir (varsayılan `BUFFER_ADAPTIVE`). Başlatma parametresiyle (`--ei jitter`) verilmiş bir değer varsa o geçerlidir ve log'da yazar.
- [ ] **Geçici oyun varsayılanları** (karar 0014 §3). Oyun moduna girince:
  - bit hızı: kayıtlı değer Otomatik ise 60 Mbps;
  - ses çıkışı: Düşük gecikme;
  - kalem izi ve kalem noktası: kapalı.

  Kurallar:
  - Bunlar kayıtlı ayarların üstüne binen bir **katmandır**. `Settings`'e yazılmaz; uygulama mantığı (STREAM_PREFS, AUDIO tercihi, kalem katmanı) etkin değeri kullanır.
  - Oyun modu açıkken bu ayarlardan biri panelden değiştirilirse yalnızca katman değişir.
  - Moddan çıkınca katman atılır ve kayıtlı değerler anında uygulanır.
  - Bir sonraki girişte katman oyun varsayılanlarıyla yeniden kurulur.
  - Uygulama kayıtlı mod Oyun ile açılırsa katman baştan kurulur.
- [ ] Panellerde oyun modu açıkken katmandaki ayarlar "(oyun modu)" işaretiyle gösterilir. Bölüm sırası ve stil T-105/T-107 ile aynıdır.
- [ ] Mod geçişi tek bir `STREAM_PREFS` ile gider (fps, ölçek ve bit hızı birlikte). Ses tercihi değişirse mevcut yolla uygulanır. Gereksiz yeniden yapılandırma olmaz.
- [ ] Log: `ev=game_mode action=enter|exit overrides=bitrate,audio,pen jitter=0`.
- [ ] Testler:
  - katman mantığı (giriş, değiştirme, çıkış, yeniden giriş, açılışta Oyun);
  - kayıtlı ayarların hiç değişmemesi;
  - etkin `StreamPrefs` (120/660/60000 ve Otomatik dışı kayıtlı bit hızının korunması);
  - jitter değerinin giriş ve çıkışta değişmesi.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde (Witcher 2, USB ve Wi-Fi).

## Notlar

- Ses ile ilgili kodun içi (audio/) T-108'de paralel değişiyor; bu kart yalnızca mevcut ses çıkışı tercihini değiştirme API'sini çağırır, `audio/` paketine dokunmaz.

## Plan

**Saf mantık (JVM testli):**
1. `stream/StreamMode.kt`: `GAME("game", "Oyun", 120, 660)` döngünün sonuna (Netlik → Akıcı → Performans → Oyun → Netlik). `parse` geri düşüşü aynı.
2. `stream/GameMode.kt` (yeni):
   - `GameModeSettings(settings: Settings)`: kayıtlı `Settings`'in üstünde oturum katmanı. Etkin değer okuyucuları (`bitrateKbps`, `audioOut`, `penTrail`, `penDot`) ve yazıcıları: katman açıkken yalnız katman değişir, kapalıyken `Settings`'e yazılır.
   - `onModeChanged(mode)`: Oyun'a girişte katmanı oyun varsayılanlarıyla kurar (bit hızı: kayıtlı Otomatik ise 60000, değilse kayıtlı değer; ses AUTO = "Düşük gecikme"; iz/nokta kapalı), çıkışta atar. `ENTER` / `EXIT` / `null` döner. Açılışta kayıtlı mod Oyun ise aynı çağrıyla kurulur.
   - `prefs(mode)`: tek `STREAM_PREFS` (fps, ölçek, etkin bit hızı).
   - `GameJitter.bufferFrames(base, fromExtra, game)`: oyunda 0; `--ei jitter` (ya da GL yolu) verilmişse o değer; değilse `base` (varsayılan `BUFFER_ADAPTIVE`).
   - Log satırı: `ev=game_mode action=enter|exit overrides=bitrate,audio,pen jitter=N`.
3. `settings/SettingsCatalog.kt`: `SettingsHost.gameDefaultsActive`; bit hızı, ses çıkışı, kalem izi ve kalem noktası başlıklarına açıkken " (oyun modu)" eki (Choice/Toggle'a `marker`). `SettingsViews` Choice başlığını refresh'te yeniden yazar. Bölüm sırası/stil aynı.

**Android (MainActivity):**
4. `settings` yerine etkin değerler `GameModeSettings` üzerinden: `selectBitrate`, `setAudioOut`, `setPenTrail`, `setPenDot`, başlangıç `STREAM_PREFS`, `AudioPlayout` başlangıç tercihi, kalem katmanı başlangıcı.
5. `setStreamMode`: `Settings.setStreamMode` + `onModeChanged`; değişiklik olursa etkin değerler yalnız farklıysa uygulanır (ses `setOutPref` yalnız farklıysa, kalem izi yalnız değiştiyse temizlenir); jitter `renderer.bufferFrames` çalışırken güncellenir; sonra **tek** `setStreamPrefs`.
6. `--es audio_out` başlatma ayarı varken (panelden değiştirilene dek) oyun modu ses çıkışına dokunmaz; `--ei jitter` varken jitter'a dokunmaz ve log'da `jitter=extra:N` yazar.

**Testler:** `stream/GameModeTest.kt` (giriş/değiştirme/çıkış/yeniden giriş/açılışta Oyun, kayıtlı ayarların hiç değişmemesi, etkin `StreamPrefs` 120/660/60000 ve Otomatik dışı bit hızının korunması, jitter giriş/çıkış ve extra önceliği, log); `StreamModeTest` döngü/etiket güncellemesi; `SettingsCatalogTest` "(oyun modu)" işaretleri.

## Handoff
