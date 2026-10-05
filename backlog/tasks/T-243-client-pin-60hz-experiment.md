---
id: T-243
title: Client experiment — keep the panel at 60 Hz in Oyun 60 despite touch (preferredRefreshRate and other platform hints), knob first
status: done
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

- [x] [JVM] Knob ayrıştırma; varsayılan yolda çağrılar bit-bit aynı; varyant → çağrılacak ipuçları listesi saf fonksiyon.
- [x] `ev=hz_pin`, `hz_switches=` docs/LOGGING.md'de.
- [x] `./scripts/check.sh` geçer. APK kurma ve tablete dokunma yok; cihaz A/B'sini orkestratör yapar.

## Plan

1. **Saf mantık `stream/HzPin.kt`** (JVM testli):
   - `HzPinVariant { OFF, LP, ALL }`, `parse(raw)` (bilinmeyen/yok = `OFF`), `IDS`.
   - `HzPinHint { LP_RATE, LP_MINMAX, HW_LP, REAPPLY }` (log kimlikleri `lp_rate`, `lp_minmax`, `hw_lp`, `reapply`).
   - `HzPin.plan(variant, isGame, streamFps): List<HzPinHint>`: yalnız Oyun + fps 60'ta; `OFF` ya da başka mod → boş liste (= bugünkü çağrılar). `LP` → `lp_rate, lp_minmax`; `ALL` → dördü.
   - `HzPin.setFloatField(target, name, value)`: yansıma ile public float alan yazma → `OK/MISSING/ERROR` (sahte sınıfla test edilir; tablette API 31'de `preferredMin/MaxDisplayRefreshRate` yok → `missing`).
   - `HzPin.extensionFields(cls)`: LayoutParams'ta AOSP dışı `refresh|framerate|fps` adlı public alanlar (yalnız okunur keşif; yazılmaz) + Huawei `com.huawei.android.view.LayoutParamsEx` sınıfı var mı. Bulunursa `ok` ve adlar loglanır, yoksa `missing`.
   - `HzPin.logFields(variant, state, results)` → `variant=<id> state=on|off applied=<hint>:<ok|missing|error>,…|-`.
   - `HzSwitchCounter`: `display_rate` raporları arasındaki değişim sayısı; log penceresinde `take()` ile sıfırlanır.
2. **`DevKnobs`**: `--es hz_pin off|lp|all` (debugOnly, `ids` = `HzPinVariant.IDS`), alan `hzPin: HzPinVariant = OFF`. Testler: geçit, varsayılan, bilinmeyen değer.
3. **`MainActivity`** (varsayılan yolda platform çağrıları bit-bit aynı):
   - `applyRefreshRate`: plan boş değilse aynı `window.attributes` atamasında `preferredRefreshRate=60f` ve min/max (yansıma); Oyun 60'tan çıkınca/`releaseRefreshRate`'te temizler (0f). `ev=hz_pin` her açma/kapamada bir satır. Erken dönüş koşulu yalnız pin durumu değişince ek olarak geçilir.
   - `REAPPLY`: her debounced `display_rate` raporunda ve her `ACTION_DOWN`'da `setSurfaceFrameRate(true, log=false)`.
   - `writeStatsLog`: `MB/render ev=stats` satırının sonuna `hz_switches=<n>` (her zaman; A/B tabanı için).
4. **`docs/LOGGING.md`**: `ev=hz_pin`, `hz_switches=`.
5. `./scripts/check.sh`, Handoff, `status: review`.

## Handoff

- **Commit:** `f44371b` (uygulama), plan `b716a3a`; dal `task/T-243-pin-60hz`.
- **Dosyalar:** `stream/HzPin.kt` (yeni: `HzPinVariant`, `HzPinHint`, `HzPinResult`, `HzPin`, `HzSwitchCounter`), `session/DevKnobs.kt` (`hz_pin`), `MainActivity.kt`, test: `stream/HzPinTest.kt` (yeni), `session/DevKnobsTest.kt`; `docs/LOGGING.md`.
- **`./scripts/check.sh`:** ALL OK (HzPinTest 9, DevKnobsTest 26 test geçti).
- **Varsayılan yol:** `hz_pin` yoksa/`off`/geçitsizse `HzPin.plan` boş → `applyRefreshRate`/`releaseRefreshRate` aynı `window.attributes` atamalarını yapar, ek `setFrameRate` yok, `ev=hz_pin` yazılmaz. Tek görünür fark: `MB/render ev=stats` sonunda her zaman `hz_switches=<n>`.
- **Varsayımlar:**
  - `lp` = yalnız pencere ipuçları (`lp_rate`, `lp_minmax`); `all` = bunlar + `hw_lp` + `reapply`.
  - `hw_lp` yalnız keşif (kart: "yalnız okunur"): `LayoutParams`'ta AOSP dışı `refresh|framerate|fps|hz` public alan adları ve `com.huawei.android.view.LayoutParamsEx` varlığı loglanır; hiçbir şey yazılmaz. Bir alan bulunursa ona yazmak ayrı bir kart olmalı.
  - `hz_switches` = log penceresinde debounced `display_rate` raporlarının değişim sayısı (düşüş 500 ms kararlılık ister, yani < 500 ms'lik 120 sıçramaları sonrasında tek düşüşle sayılır; ham Choreographer geçişleri değil).
  - Pin hızı sabit 60 (`HzPin.PIN_HZ`); kapsam: `streamMode.isGame && streamConfig.fps == 60`. Pin, `installConfig` → `applyRefreshRate` ile açılır; Oyun 60'tan başka moda geçince ya da akış bitince kaldırılır (`state=off`).
- **Test EDİLMEDİ (tablet gerekli):** hiçbir ipucunun panel hızına etkisi; API 31'de `lp_minmax` `missing` beklentisi; Huawei alan keşfinin sonucu; `reapply`'nin dokunma gecikmesine etkisi.
- **Tablette kontrol (orkestratör A/B, Oyun modu, 60 fps):**
  1. Varsayılan (extra yok): `adb logcat -s MB:*` → `ev=hz_pin` yok, `MB/render ev=stats ... hz_switches=N` var; periyodik `adb shell input swipe` ile N tabanını kaydet.
  2. `am start ... --ez dev true --es hz_pin lp`: `ev=hz_pin variant=lp state=on applied=lp_rate:ok,lp_minmax:missing` beklenir; `hz=`/`display_hz=`/`vsync_ms_p50=` ve `hz_switches` tabanla karşılaştır.
  3. `--es hz_pin all`: `applied=` içinde `hw_lp:<ok|missing>`, `reapply:ok`; `hw_fields=`/`hw_ex=` değerlerini NOTES'a yaz; aynı swipe A/B.
  4. Oyun 60'tan Günlük'e geç: `ev=hz_pin ... state=off applied=-` görülmeli; Günlük'te ipucu yok.
  5. Kalem/dokunmada `reapply` ile hissedilir gecikme ya da `W set_frame_rate_failed` olmamalı.

## Open questions

- `docs/KNOBS.md` kartın `files:` listesinde yok; `hz_pin` anahtarı orada listelenmedi. Orkestratör deney sonucu kalıcı olursa ekleyebilir.

**Orkestratör (2026-10-05):** cihaz A/B olumsuz (NOTES 2026-10-05 ~13:25): üç varyantta da panel dokunmayla 120 Hz'e çıktı. Knob varsayılan kapalı kalır; Huawei uzantı alanı bulunmadığı için takip kartı yok.
