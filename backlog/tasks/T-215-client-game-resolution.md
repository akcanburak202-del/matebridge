---
id: T-215
title: Client: "Oyun çözünürlüğü" setting and game display prefs (decision 0029)
status: in_progress
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

1. `stream/GameResolution.kt`: enum `R1400(1400×920)`, `R1848(1848×1214)`, `R2100(2100×1380)`; `id` = `"<w>x<h>"`, `label` = `"<w>×<h>"`; `DEFAULT = R1848`; `parse()` bilinmeyende varsayılan.
2. `Settings.kt`: `KEY_GAME_RESOLUTION = "game_resolution"`, `gameResolution()/setGameResolution()`, `USER_KEYS`'e ekle.
3. `DevKnobs.kt`: debug-only `Spec("game_display", INT)`; `gameDisplay: Boolean` (yalnız `dev` ile ve değer 0 → false). `StreamProfile`'a `display` alanı: `display=<w>x<h>|native` (`scale_permille`'den sonra) ve istenmişse `display_applied=0|1` (`width_pt == display_width_px`).
4. `GameMode.kt`: `GameModeSettings(settings, gameDisplay = true)`; `display(mode): GameResolution?` (oyun modu ve `gameDisplay` iken ayar, yoksa null); `prefs(mode)` oyun modunda `StreamPrefs(fps, scale, bitrate, w, h)`, diğerlerinde `mode.toPrefs(bitrate)` (bugünkü baytlar); `selectGameResolution(r, mode): StreamPrefs?` saklar, yalnız oyun modunda (ve `gameDisplay`) gönderilecek tam prefs döner.
5. `StreamMode.kt`: `toastText(display: GameResolution? = null)` oyun boyutunu gösterir; `VideoLayout.surfaceSize(rootW, rootH, config): Pair<Int,Int>?` — null = MATCH_PARENT (config yok/boş kök, ya da sığdırılan dikdörtgen kökten iki eksende ≤ 2 px farklı).
6. `SettingsCatalog.kt`: `SettingsHost.gameResolution/selectGameResolution`; "Görüntü"de `stream_mode`'dan sonra Choice `game_resolution` "Oyun çözünürlüğü".
7. `MainActivity.kt`: `GameModeSettings(settings, devKnobs.gameDisplay)`; settingsHost uygulaması; toast ve `ev=profile` alanı; `layoutVideo()` `surfaceSize` kullanır.
8. JVM testleri (GameModeTest, StreamModeTest, SettingsCatalogTest, SettingsResetTest, DevKnobsTest, yeni GameResolutionTest), `docs/KNOBS.md` satırı. `docs/LOGGING.md` listede yok → `display=` alanı Açık sorular'a.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
