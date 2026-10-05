---
id: T-243
title: Client experiment — keep the panel at 60 Hz in Oyun 60 despite touch (preferredRefreshRate and other platform hints), knob first
status: todo
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0016, 0030]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/LOGGING.md
  - backlog/tasks/T-243-client-pin-60hz-experiment.md
---

## Amaç

HDR araştırması (NOTES 2026-10-05 ~13:00): Oyun 60'ta düşen karelerin önemli bir kısmı panelin dokunmayla 60→120 Hz geçişlerinde (geçişten sonraki 3 sn'de 1,9/sn, sabit panelde 0,6/sn). İstemci bugün `preferredDisplayModeId` (60 Hz modu) ve `Surface.setFrameRate(60, FIXED_SOURCE, CHANGE_FRAME_RATE_ALWAYS)` istiyor (`MainActivity.kt:1535-1580`), ama Huawei dokununca 120'ye çıkarıyor (`render ev=stats hz=120 target_hz=60`). Kullanıcı Oyun 60'ta panelin 60'ta sabit kalmasını istiyor.

## Bağlam

- Denenecek ek ipuçları (geliştirici anahtarı `--es hz_pin off|lp|all`, `--ez dev true` kapısı; varsayılan `off` = bugünkü davranış):
  - `WindowManager.LayoutParams.preferredRefreshRate = 60f` (modla birlikte);
  - `preferredMinDisplayRefreshRate`/`preferredMaxDisplayRefreshRate` (API 34; tablet API 31 → yansıma ile varsa, yoksa logla ve atla);
  - pencere `LayoutParams` Huawei uzantı alanları varsa (yansıma, yalnız okunur sınıf/alan kontrolü, bulunmazsa sessiz);
  - `Surface.setFrameRate` çağrısını her `display_rate` değişiminde ve her dokunma başlangıcında yeniden vermek (tek seferlik isteğin dokunma oyu tarafından ezilip ezilmediğini görmek için).
- Yalnız Oyun 60'ta (stream fps 60, Oyun modu). Diğer modlar değişmez.
- Log: `ev=hz_pin variant= applied=<her ipucu için ok/missing/error>` ve mevcut `ev=display_rate` geçişleri; 10 sn'de geçiş sayısı (`ev=stats`'a `hz_switches=`).
- Kullanıcı yokken orkestratör A/B yapacak: aynı ekranda adb `input swipe` ile periyodik dokunma, `hz` / `display_hz` ve geçiş sayısı.

## Kabul kriterleri

- [ ] [JVM] Knob ayrıştırma; varsayılan yolda çağrılar bit-bit aynı; varyant → çağrılacak ipuçları listesi saf fonksiyon.
- [ ] `ev=hz_pin`, `hz_switches=` docs/LOGGING.md'de.
- [ ] `./scripts/check.sh` geçer. APK kurma ve tablete dokunma yok; cihaz A/B'sini orkestratör yapar.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
