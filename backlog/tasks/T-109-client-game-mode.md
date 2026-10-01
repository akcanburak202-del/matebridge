---
id: T-109
title: Tablet — "Oyun" görüntü modu (120 fps, %66, jitter 0) ve geçici oyun varsayılanları
status: review
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

- [x] `StreamMode` içine `GAME("game", "Oyun", 120, 660)` eklenir.
  - Mod döngüsüne (Ctrl+Shift+7), bağlantı paneline ve yan panele girer.
  - Kayıtlı mod olarak saklanabilir.
  - Bilinmeyen değerlerde mevcut geri düşüş kuralı korunur.
- [x] **Gecikme:** oyun modunda video jitter tamponu 0'dır (`VideoRenderer.bufferFrames = 0`, çalışırken değişir). Moddan çıkınca önceki değer geri gelir (varsayılan `BUFFER_ADAPTIVE`). Başlatma parametresiyle (`--ei jitter`) verilmiş bir değer varsa o geçerlidir ve log'da yazar.
- [x] **Geçici oyun varsayılanları** (karar 0014 §3). Oyun moduna girince:
  - bit hızı: kayıtlı değer Otomatik ise 60 Mbps;
  - ses çıkışı: Düşük gecikme;
  - kalem izi ve kalem noktası: kapalı.

  Kurallar:
  - Bunlar kayıtlı ayarların üstüne binen bir **katmandır**. `Settings`'e yazılmaz; uygulama mantığı (STREAM_PREFS, AUDIO tercihi, kalem katmanı) etkin değeri kullanır.
  - Oyun modu açıkken bu ayarlardan biri panelden değiştirilirse yalnızca katman değişir.
  - Moddan çıkınca katman atılır ve kayıtlı değerler anında uygulanır.
  - Bir sonraki girişte katman oyun varsayılanlarıyla yeniden kurulur.
  - Uygulama kayıtlı mod Oyun ile açılırsa katman baştan kurulur.
- [x] Panellerde oyun modu açıkken katmandaki ayarlar "(oyun modu)" işaretiyle gösterilir. Bölüm sırası ve stil T-105/T-107 ile aynıdır.
- [x] Mod geçişi tek bir `STREAM_PREFS` ile gider (fps, ölçek ve bit hızı birlikte). Ses tercihi değişirse mevcut yolla uygulanır. Gereksiz yeniden yapılandırma olmaz.
- [x] Log: `ev=game_mode action=enter|exit overrides=bitrate,audio,pen jitter=0`.
- [x] Testler:
  - katman mantığı (giriş, değiştirme, çıkış, yeniden giriş, açılışta Oyun);
  - kayıtlı ayarların hiç değişmemesi;
  - etkin `StreamPrefs` (120/660/60000 ve Otomatik dışı kayıtlı bit hızının korunması);
  - jitter değerinin giriş ve çıkışta değişmesi.
- [x] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde (Witcher 2, USB ve Wi-Fi).

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

- **Commit:** `7a3bb5a` (kod + testler), plan `b5cefc4`; dal `task/T-109-client-game-mode` (main `06898e3` üstünde).
- **check.sh:** geçti (`check.sh: ALL OK`). Testler: `GameModeTest` 10, `StreamModeTest` 8, `SettingsCatalogTest` 9; hepsi geçti.
- **Dokunulan dosyalar** (hepsi `client-android/app/src/`):
  - yeni: `main/.../stream/GameMode.kt` (`GameModeSettings`, `GameJitter`), `test/.../stream/GameModeTest.kt`;
  - değişen: `MainActivity.kt`, `stream/StreamMode.kt`, `settings/SettingsCatalog.kt`, `settings/SettingsViews.kt`, `test/.../stream/StreamModeTest.kt`, `test/.../settings/SettingsCatalogTest.kt`.
  - `Settings.kt` ve `VideoRenderer.kt` değişmedi: `bufferFrames` zaten çalışırken ayarlanabiliyordu. `audio/` paketine dokunulmadı; yalnız mevcut `AudioPlayout.setOutPref` çağrılıyor.
- **Yapı:**
  - `StreamMode.GAME("game", "Oyun", 120, 660)` döngünün sonunda: Netlik → Akıcı → Performans → Oyun → Netlik. Panellerde "Oyun (120 fps)", toast "Oyun: 120 fps, %66".
  - `GameModeSettings(settings)`: bit hızı, ses çıkışı, kalem izi ve kalem noktası artık **yalnız** bunun üzerinden okunur ve yazılır.
    - Oyun açıkken yazma yalnız katmana gider; `Settings`'e hiç yazılmaz (testte yazma kaydıyla doğrulandı).
    - Çıkışta katman atılır. Girişte oyun varsayılanlarıyla yeniden kurulur. Açılışta kayıtlı mod Oyun ise katman `onCreate`'te, `STREAM_PREFS` ve `AudioPlayout` kurulmadan önce kurulur.
  - Mod geçişi (`setStreamMode`) şu sırayla çalışır:
    1. `onModeChanged` çağrılır.
    2. Yalnız farklı olan değerler uygulanır: `setOutPref` aynı değerde no-op; kalem izi yalnız değişince temizlenir.
    3. `renderer.bufferFrames` güncellenir.
    4. **Tek** `setStreamPrefs` gönderilir (fps, ölçek ve etkin bit hızı). `SessionMachine` aynı prefs'i zaten tekrar göndermez.
  - Panel işareti: `SettingsHost.gameDefaultsActive`. Bit hızı, Ses çıkışı, Kalem izi ve Kalem noktası başlıklarına " (oyun modu)" eki gelir; Choice başlığı her refresh'te yeniden yazılır.
- **Varsayımlar:**
  - `--ei jitter N` verilmişse oyun modu jitter'a dokunmaz; log `jitter=N jitter_src=extra` yazar (plandaki `jitter=extra:N` yerine bu biçim). GL yolunda (`--es render gl`) tampon zaten 0 (`jitter_src=gl`).
  - Geçerli bir `--es audio_out` başlatma ayarı varsa oyun modu ses çıkışını değiştirmez; bu, panelden ses çıkışı seçilene kadar sürer. Kartta yazmıyor, jitter kuralına benzetildi.
  - Log: `ev=game_mode action=enter|exit overrides=bitrate,audio,pen jitter=0|adaptive [jitter_src=extra|gl] bitrate_kbps=N audio_out=auto|track`; açılıştaki girişte sonuna ` at=start` eklenir. `overrides` her zaman katmandaki üç grubu listeler.
- **Test edilmedi (cihaz gerekir):**
  - jitter 0'da akıcılık ve takılma;
  - 120 fps / %66 / 60 Mbps'in host'ta gerçekten uygulanması;
  - ses çıkışı geçişinde (Uyumlu → Düşük gecikme) çalışan akışın yeniden açılması;
  - Wi-Fi'de 60 Mbps.
- **Tablette kontrol:**
  1. Ayarlarda Kalem izi/noktası açık, Ses çıkışı "Uyumlu", bit hızı Otomatik iken akışta Ctrl+Shift+7 ile Oyun'a geç. Toast "Oyun: 120 fps, %66" çıkmalı. Log'da `ev=game_mode action=enter ... jitter=0 bitrate_kbps=60000 audio_out=auto` ve tek `stream_prefs_sent` görünmeli. `stream_config_bitrate bitrate_kbps≈60000`, istatistik katmanında "Tampon 0" olmalı.
  2. Ctrl+Shift+6 ile yan panel: Bit hızı / Ses çıkışı / Kalem izi / Kalem noktası "(oyun modu)" işaretli olmalı, değerler 60 Mbps / Düşük gecikme / kapalı / kapalı. Birini değiştir, sonra Akıcı'ya geç: kayıtlı değerler (Otomatik, Uyumlu, iz/nokta açık) geri gelmeli, işaretler kalkmalı, log `action=exit ... jitter=adaptive`.
  3. Tekrar Oyun'a geç: oyun varsayılanları yeniden gelmeli (panelde az önce yapılan değişiklik değil).
  4. Oyun modundayken uygulamayı kapatıp aç: `game_mode action=enter ... at=start` görünmeli, bağlantı panelinde işaretler olmalı.
  5. Witcher 2'de USB ve Wi-Fi ile gecikme ve akıcılık; jitter 0'da takılma varsa karar 0014'teki 1 kare seçeneği.
- **Open questions:** yok.
