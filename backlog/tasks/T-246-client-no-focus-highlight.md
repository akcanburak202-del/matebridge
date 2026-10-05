---
id: T-246
title: Client — disable Android's default focus highlight on the video SurfaceView (the intermittent "grey" black lift)
status: in_progress
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

- [ ] `video.defaultFocusHighlightEnabled = false` (ve kök `FrameLayout` ile odaklanabilir diğer tam ekran görünümler için aynısı, ucuz güvence); layout XML'de ya da kodda, planda seç.
- [ ] Odak davranışı (pointer capture, klavye olayları) değişmez.
- [ ] [JVM/Robolectric yoksa] en azından görünümlerin bayrağını kuran yardımcı için birim test ya da Handoff'ta gerekçe.
- [ ] `./scripts/check.sh` geçer.
- [ ] [device, orkestratör] `adb shell input keyevent KEYCODE_SHIFT_LEFT` sonrası `mInTouchMode=false` iken eşli yakalamada siyah 0→0–2 kalır.

## Plan

- Yer: layout XML (`res/layout/activity_main.xml`), kod değil. `android:defaultFocusHighlightEnabled="false"` API 26+, minSdk 29 → koşulsuz. `MainActivity.kt`'ye dokunulmaz (T-245/T-247 ile çakışma yok); odaklanabilirlik (`isFocusable`/`isFocusableInTouchMode`, `requestFocus()`) aynen kalır, yalnızca vurgu çizimi kapanır.
- Bayrak: `@id/root` (FrameLayout), `@id/video` (SurfaceView) ve tam ekran odaklanabilir `@id/panel` (ScrollView, bağlantı paneli; ucuz güvence).
- Test: Robolectric yok → JVM testi `FocusHighlightLayoutTest` layout XML'ini (`src/main/res/layout/activity_main.xml`) DOM ile ayrıştırır ve bu üç id'de bayrağın `false` olduğunu doğrular (gelecekte biri silerse kırılır).
- `./scripts/check.sh`.

## Handoff

_(Ajan bitirince doldurur.)_
