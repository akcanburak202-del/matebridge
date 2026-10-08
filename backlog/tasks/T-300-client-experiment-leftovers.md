---
id: T-300
title: Tablet — kararı verilmiş deneylerin kodunu kaldır (tos/wifi_ll + Wi-Fi kilidi, hz_pin, renk geçersiz kılma, dec_lowlat/dec_oprate varyantları, VideoTestActivity)
status: todo
phase: 7
owner: android-client-dev
depends_on: []
decisions: [0026]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/WifiKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/HzPin.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/ColorOverrides.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/DecoderLatencyKnobs.kt
  - client-android/app/src/main/AndroidManifest.xml
  - client-android/app/src/debug/
  - client-android/app/src/test/
  - backlog/tasks/T-300-client-experiment-leftovers.md
---

## Amaç

T-297 ortak ayıklaması, parti 2 (`docs/reviews/2026-10-08/simplification.md`). Kanıt ve dosya:satır ajan özetlerinde:
- `docs/reviews/2026-10-08/agents/simp-d-client-session.md` (D1, D2);
- `simp-c-client-video.md` (C5);
- `simp-f-knobs.md` (`dec_lowlat`/`dec_oprate`, `VideoTestActivity`);
- astra S1.

Her deneyin sonucu kayıtlı:
- T-127 (KNOBS satır 15: "etkisiz → kaldır");
- T-243 (NOTES 2026-10-05 ~13:25, olumsuz);
- T-231 (NOTES 2026-10-05: çözücü anahtarları yok sayıyor);
- T-217/T-222 (`max` benimsendi).

## Kabul

1. **`tos_ctl`, `tos_video`, `wifi_ll`:** `WifiLockPolicy`/`WifiLockHolder`, MainActivity'deki kilit kurulumu ve `syncWifiLock` çağrıları, SessionController'daki trafik sınıfı dalları ve `WAKE_LOCK` izni kaldırılır.
   - **Kalanlar:** `ping_ms`, `RttStats` ve `TrafficClass.trySet`. Dosya soketleri bunu kullanıyor (`SessionController.kt` ~702).
2. **`hz_pin`:** `HzPin.kt`, DevKnobs girdileri, MainActivity'deki yansıma, `hw_fields` probu ve her ACTION_DOWN'daki yeniden uygulama kaldırılır.
   - `HzSwitchCounter` (`hz_switches=` alanı) yeni bir dosyaya taşınıp kalır.
   - `applyRefreshRate`/`releaseRefreshRate` düz `preferredDisplayModeId`/`setFrameRate` davranışına döner. Varsayılan yolda bugün ne yapılıyorsa o.
3. **`color_range`/`color_standard`/`color_transfer`:** `ColorOverrides` ve üç Spec kaldırılır. `colorKeys()`, `ColorMapping` değerlerini doğrudan kullanır; bu bugünkü AUTO ile bayt bayt aynı.
   - `OutputFormatReport` ve `OutputFormatLogGate` kalır.
4. **`dec_lowlat`/`dec_oprate`:** varyant kolları kaldırılır.
   - **Kalan:** varsayılan `max` işletim hızı ve onun bir kerelik yeniden deneme yedeği.
   - **Log alanları:** `lowlat=off oprate=max` alanları sabit değerle yazılmaya devam eder, çünkü `tools/measure` ayrıştırıyor.
5. **`src/debug/.../VideoTestActivity.kt` (T-013):** manifest girdisiyle birlikte kaldırılır.
6. **Bilinmeyen anahtarlar:** kaldırılan anahtarlar artık tanınmaz; DevKnobs'un genel kuralı uygulanır, çökme olmaz. Bir test bunu gösterir.
7. **Testler:** yalnız kaldırılan yolu sınayan testler silinir; kalan davranışın testleri kalır.
8. **Varsayılan davranış değişmez.** Anahtarsız açılış bugünküyle aynı yolları izler.
9. **Belgeler:** `docs/KNOBS.md`, `docs/LOGGING.md` ve decision 0026'yı orkestratör günceller; önerilen metni Handoff'a yaz.
10. **Kapsam dışı:** T-197 (`ctl_lowat_kb`) ileride WifiKnobs.kt'ye dokunabilir; bugün yok sayılır.

## Plan

## Handoff

## Open questions
