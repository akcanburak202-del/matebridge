---
id: T-246
title: Client — disable Android's default focus highlight on the video SurfaceView (the intermittent "grey" black lift)
status: review
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/res/layout/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-246-client-no-focus-highlight.md
---

## Amaç

NOTES 2026-10-05 (siyah kalkması) ve araştırma: kalkma tam olarak `out = in·(1−a) + 255·a`, a = 16/255 (gamma uzayında ~%6 beyaz karışım). Neden: dokunma kipi dışında (klavye/fare/gamepad sonrası `mInTouchMode=false`) Android 8+ odaklı `SurfaceView`'in (`app:id/video`, `MainActivity.kt:631-632` `isFocusable`/`isFocusableInTouchMode` + `syncPointerCapture` içinde `requestFocus()`) üstüne varsayılan odak vurgusunu çiziyor; pencere video üstünde DEVICE katmanı olarak birleşiyor. Dokunuş (APK kurulumundaki onay dokunuşları dahil) dokunma kipine sokup düzeltiyordu.

## Kabul kriterleri

- [x] `video.defaultFocusHighlightEnabled = false` (ve kök `FrameLayout` ile odaklanabilir diğer tam ekran görünümler için aynısı, ucuz güvence); layout XML'de ya da kodda, planda seç.
- [x] Odak davranışı (pointer capture, klavye olayları) değişmez.
- [x] [JVM/Robolectric yoksa] en azından görünümlerin bayrağını kuran yardımcı için birim test ya da Handoff'ta gerekçe.
- [x] `./scripts/check.sh` geçer.
- [ ] [device, orkestratör] `adb shell input keyevent KEYCODE_SHIFT_LEFT` sonrası `mInTouchMode=false` iken eşli yakalamada siyah 0→0–2 kalır.

## Plan

- Yer: layout XML (`res/layout/activity_main.xml`), kod değil. `android:defaultFocusHighlightEnabled="false"` API 26+, minSdk 29 → koşulsuz. `MainActivity.kt`'ye dokunulmaz (T-245/T-247 ile çakışma yok); odaklanabilirlik (`isFocusable`/`isFocusableInTouchMode`, `requestFocus()`) aynen kalır, yalnızca vurgu çizimi kapanır.
- Bayrak: `@id/root` (FrameLayout), `@id/video` (SurfaceView) ve tam ekran odaklanabilir `@id/panel` (ScrollView, bağlantı paneli; ucuz güvence).
- Test: Robolectric yok → JVM testi `FocusHighlightLayoutTest` layout XML'ini (`src/main/res/layout/activity_main.xml`) DOM ile ayrıştırır ve bu üç id'de bayrağın `false` olduğunu doğrular (gelecekte biri silerse kırılır).
- `./scripts/check.sh`.

## Handoff

- **Commit:** `745b12d` (uygulama), `958deb5` (plan); dal `task/T-246-no-focus-highlight`.
- **Dosyalar:** `client-android/app/src/main/res/layout/activity_main.xml` (`android:defaultFocusHighlightEnabled="false"` → `@id/root`, `@id/video`, `@id/panel` + açıklama yorumu), `client-android/app/src/test/kotlin/dev/matebridge/client/FocusHighlightLayoutTest.kt` (yeni; layout XML'ini DOM ile ayrıştırıp üç id'de bayrağı ve `video`'nun hâlâ `SurfaceView` olduğunu doğrular), bu kart.
- **`MainActivity.kt` değişmedi** → T-245/T-247 ile çakışma yok. Odaklanabilirlik ve `requestFocus()` aynen kalıyor; yalnızca vurgu çizimi kapalı.
- **Varsayımlar:** kalkmanın kaynağı gerçekten varsayılan odak vurgusu (NOTES 2026-10-05 araştırması). Vurgu sadece odaklı görünümde çizilir; diğer odaklanabilir görünümler (Button/EditText, ayar paneli) tam ekran değil, onlara dokunulmadı. In-stream yan panel koddan kuruluyor; tam ekran değil, kapsam dışı.
- **check.sh:** ALL OK (yeni test: 2/2 geçti).
- **Test edilmeyen (tablet gerekli):**
  1. Akış açıkken `adb shell input keyevent KEYCODE_SHIFT_LEFT` → `adb shell dumpsys window | grep mInTouchMode` = `false`; eşli yakalamada siyah 0→0–2 kalmalı (önceden 16).
  2. Bir fiziksel klavye tuşu / fare tıklaması / gamepad tuşu sonrası (dokunmadan) siyah hâlâ siyah mı.
  3. Odak davranışı: trackpad pointer capture hâlâ alınıyor, klavye tuşları Mac'e gidiyor (T-247'deki "dokunuştan sonra ilk gezinme tuşu" durumu bu kartla değişmemeli).
  4. Bağlantı panelinde (akış öncesi) klavyeyle gezinme: düğmelerin kendi odak durumu görünür kalmalı (yalnızca kök/ScrollView vurgusu kapalı).
