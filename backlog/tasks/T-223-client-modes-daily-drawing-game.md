---
id: T-223
title: Client — three modes (Günlük / Çizim / Oyun), per-mode frame rate setting, 2240×1472 game resolution
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-215, T-222]
decisions: [0030, 0029, 0014]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/StreamMode.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/GameMode.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/GameResolution.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsCatalog.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/res/values/strings.xml
  - client-android/app/src/test/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/test/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-223-client-modes-daily-drawing-game.md
---

## Amaç

Karar 0030'u uygulamak: beş mod (Netlik, Akıcı, Performans, Oyun 120, Oyun 60) yerine üç mod — **Günlük**, **Çizim**, **Oyun** — ve ayrı bir "Kare hızı: 60 / 120" ayarı (Günlük ve Oyun'da, mod başına hatırlanır; Çizim hep 120). Oyun çözünürlüğü listesine 2240×1472 eklenir. Performans kalkar.

## Bağlam

- `StreamMode` enum'u bugün fps + ölçek tablosu; `GameModeSettings` (0014 §3 geçici katman: bit hızı 60 Mbps, düşük gecikmeli ses, kalem izi/noktası kapalı) `isGame` ile bağlanıyor.
- Çizim katmanı aynı mekanizmayla (geçici, kayıtlı ayarların üstüne biner, moddan çıkınca geri döner): parmakla dokunma kapalı (`finger_off`), Otomatik bit hızıysa 60 Mbps.
- Kare hızı: Günlük varsayılan 120, Oyun varsayılan 60; ayar anahtarları ör. `fps_daily`, `fps_game` (T-191 sıfırlaması `USER_KEYS` ile kapsar).
- Kayıtlı `stream_mode` geçişi (0030 §5): `clarity`→Günlük 60, `smooth`→Günlük 120, `performance`→Günlük 120, `game`→Oyun 120, `game60`→Oyun 60 (eski `performance144` → Günlük 120).
- STREAM_PREFS: Günlük/Çizim `scale_permille = 1000`, `display_* = 0`; Oyun `scale_permille = 1000`, `display_* = oyun çözünürlüğü`. Tel biçimi ve host değişmez. Oyun + eski host: 0029 geri düşüşü (doğal ekran) — `scale 1000` ile tam boyut; kabul.
- Ctrl+Shift+7 döngüsü üç mod; panel ve toast metinleri (ör. "Oyun: 60 fps, 1848×1214", "Günlük: 120 fps", "Çizim: 120 fps").
- `ev=profile mode=` yeni kimlikler (`daily|drawing|game`) ve `fps=`; LOGGING/KNOBS güncellenir. Performans'a bağlı dev yolu kalırsa KNOBS'ta belirtilir.

## Kapsam dışı

- Host, protokol, pacer, 0029 ekran kurulumu.

## Kabul kriterleri

- [ ] [JVM] Üç mod; Günlük/Oyun kare hızı ayarı mod başına hatırlanır (Günlük 120 / Oyun 60 varsayılan); Çizim her zaman 120.
- [ ] [JVM] Kayıtlı eski mod kimlikleri 0030 §5'e göre eşlenir; bilinmeyen değer Günlük 120.
- [ ] [JVM] Çizim katmanı: girince parmak kapalı + (Otomatik ise) 60 Mbps; çıkınca kayıtlı değerler aynen geri gelir (0014 §3 kuralları).
- [ ] [JVM] STREAM_PREFS baytları: Günlük 120 = (120, 1000, auto, 0×0); Oyun 60 1848×1214 = (60, 1000, 60000, 1848, 1214); 2240×1472 geçerli seçenek.
- [ ] [JVM] Ctrl+Shift+7 üç mod arasında döner; ayar sıfırlama yeni anahtarları kapsar.
- [ ] [device] Her mod girişinde beklenen `ev=profile`; Günlük 60↔120 değişimi bir kez ekran yeniden kurulumu; Çizim'de avuç teması tıklamıyor, kalem çiziyor; Oyun'da 2240×1472 seçilebiliyor ve oyunda görünüyor.

## Plan

1. `StreamMode` -> üç değer (`DAILY daily`, `DRAWING drawing`, `GAME game`, bu sırayla; Ctrl+Shift+7 döngüsü). Kare hızı enum'dan çıkar: `defaultFps` (Günlük 120, Çizim 120, Oyun 60), `hasFpsSetting` (Çizim hariç), `resolveFps` (Çizim hep 120, geçersiz değer varsayılan), `toPrefs(fps, bitrate)` hep `scale_permille = 1000`. Eski kimlikler (`clarity|smooth|performance|performance144|game60`) `LegacyModes` ile 0030 §5'e göre eşlenir; bilinmeyen = Günlük.
2. `Settings`: `fps_daily` / `fps_game` anahtarları (`modeFps(mode)`, `setModeFps`), `USER_KEYS`'e eklenir (T-191 sıfırlaması kapsar). Tek seferlik geçiş `migrateModesOnce()` (bayrak `modes_migrated`, sıfırlamada korunur, T-096 gibi): eski `stream_mode` yeni kimliğe ve `fps_*` değerine yazılır (ör. `game` -> Oyun 120, `game60` -> Oyun 60). Getter eski kimlikleri de tolere eder.
3. `GameModeSettings` (isim korunur, "mod katmanı" olur): `Values`'a `fingerOff` eklenir; katman moda göre kurulur: Oyun = 0014 §3 (60 Mbps/ses/kalem), Çizim = parmak kapalı + Otomatik ise 60 Mbps (ses ve kalem kayıtlı kalır). Oyun<->Çizim geçişi katmanı baştan kurar (ENTER). `onModeChanged` artık `Transition(change, mode)` döner; `prefs(mode)` kare hızını `Settings.modeFps`'ten alır; `selectFrameRate`. Log: `ev=mode_layer mode= action= overrides= ...`.
4. `SettingsCatalog`/`SettingsHost`: mod listesi üç düğme; yeni "Kare hızı" (60/120) seçimi (`frameRate`, `selectFrameRate`), Çizim'de başlığı "(Çizim: hep 120)" olur ve seçim etkisizdir (gizleme `SettingsViews.kt` ister, kart dışı: Açık sorular). `gameDefaultsActive` -> `modeLayer: StreamMode?`; işaretler ayar bazında ("(oyun modu)" / "(çizim modu)"; parmak kapalı Çizim'de işaretlenir). Oyun çözünürlüğü listesine 2240×1472.
5. `MainActivity`: katman parmak durumunu da uygular (`capture.setFingersDisabled` ancak `gameSettings.fingerOff`'tan), açılış/sıfırlama/mod değişimi, `selectFrameRate`, `migrateModesOnce()` en başta, profil `mode=` yeni kimlik, toast metinleri.
6. JVM testleri: StreamModeTest, GameModeTest (katman), GameResolutionTest, SettingsCatalogTest, SettingsResetTest, BitrateSettingTest/SessionMachineTest uyarlaması, yeni geçiş testleri. Sonra docs/KNOBS.md ve docs/LOGGING.md.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
