---
id: T-215
title: Client: "Oyun çözünürlüğü" setting and game display prefs (decision 0029)
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-213]
decisions: [0029]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/GameResolution.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/GameMode.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/StreamMode.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsCatalog.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/test/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - docs/KNOBS.md
  - backlog/tasks/T-215-client-game-resolution.md
---

## Amaç

Karar 0029: tablette kalıcı bir "Oyun çözünürlüğü" ayarı (1400×920 · 1848×1214 · 2100×1380; varsayılan 1848×1214). Oyun 120 / Oyun 60'tayken STREAM_PREFS `display_*` bu boyutla gönderilir; diğer modlarda 0×0 (bugünkü baytlar).

## Bağlam (tasarım, 2026-10-04)

- Yeni `stream/GameResolution.kt` enum (`id`, `widthPx`, `heightPx`, `label`); bilinmeyen değer varsayılana döner.
- `Settings.kt`: `KEY_GAME_RESOLUTION = "game_resolution"`, getter/setter, `USER_KEYS`'e (T-191 sıfırlaması kapsar). Kalıcı kullanıcı ayarı; 0014'ün geçici oyun katmanının parçası değil.
- Tek prefs kurucusu `GameModeSettings.prefs` (`GameMode.kt` ~:78): oyun modunda `StreamPrefs(mode.fps, mode.scalePermille, bitrate, res.w, res.h)` (ölçek 660/1000 kalır → eski host geri düşüşü).
- Dev: `--ez dev true --ei game_display 0` → 0×0 (A/B tabanı); `DevKnobs.kt` + `docs/KNOBS.md` satırı.
- UI: `SettingsCatalog` "Görüntü" bölümünde `stream_mode`'dan sonra Choice `game_resolution` "Oyun çözünürlüğü"; `SettingsHost.gameResolution/selectGameResolution`; `MainActivity.settingsHost` değeri saklar, yalnız `streamMode.isGame` iken bir STREAM_PREFS gönderir. `StreamMode.toastText` oyun modunda boyutu gösterir; `ev=profile display=`.
- Yerleşim: 1848×1214 tam 35:23 değil (%0,03); `VideoLayout.aspectSize` pt ile çalıştığı için SurfaceView 2800×1839 olur → saf `VideoLayout.surfaceSize(rootW, rootH, config)`: sığdırılan dikdörtgen kökten iki eksende de ≤ 2 px farklıysa MATCH_PARENT.
- Girdi eşlemesi (PenTracker/TouchTracker görünüm dikdörtgenine normalize; göreli hareket `width_pt` ile) değişmez. VideoHealth/VideoDeliveryGate/CodecGeneration değişmez.

## Kabul kriterleri

- [ ] [JVM] `prefs(GAME)` = (120, 660, bitrate, 1848, 1214); `prefs(GAME60)` = (60, 1000, bitrate, 1848, 1214); oyun dışı modlar ve `game_display=0` bugünkü baytları üretir.
- [ ] [JVM] Çözünürlük değişimi yalnız oyun modundayken tam bir STREAM_PREFS gönderir; sıfırlama ayarı varsayılana döndürür.
- [ ] [JVM] 1848×1214 pt, 2800×1840 kökü bantsız doldurur; gerçek farklı en-boyda letterbox sürer.
- [ ] [doc] KNOBS satırı; `ev=profile display=`. `./scripts/check.sh` yeşil.
- [ ] [device] T-216.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
