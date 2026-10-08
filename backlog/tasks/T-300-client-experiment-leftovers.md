---
id: T-300
title: Tablet — kararı verilmiş deneylerin kodunu kaldır (tos/wifi_ll + Wi-Fi kilidi, hz_pin, renk geçersiz kılma, dec_lowlat/dec_oprate varyantları, VideoTestActivity)
status: done
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
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/OperatingRate.kt  # (orkestratör düzeltmesi: DecoderLatencyKnobs bu dosyadaydı)
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/OutputFormatReport.kt  # (orkestratör, Codex P3)
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

1. Her kaldırma adayının kullanımını kodda doğrula (grep), sonra sil: WifiKnobs (tos/wifi_ll/kilit), HzPin, ColorOverrides, DecoderLatencyKnobs, VideoTestActivity.
2. `HzSwitchCounter` ve `OutputFormatReport`/`OutputFormatLogGate` yeni dosyalara taşınır.
3. `VideoRenderer`: `decoderTuning`/`colorOverrides` parametreleri gider; biçim `OperatingRate.MAX` + bir kerelik fps yedeği.
4. Testler: yalnız kaldırılan yolları sınayanlar silinir, kalanlar yeniden adlandırılır.

## Handoff

- **Commit:** `git log task/T-300-experiment-leftovers` (tek commit, "T-300: ...").
- **check.sh:** ALL OK.
- **Silinen:** `WifiLockPolicy`/`WifiLockHolder`, `tos_ctl`/`tos_video`/`wifi_ll` (+ MainActivity kilit kurulumu ve 5 `syncWifiLock` çağrısı, SessionController `trySet`/`traffic_class` log dalları, `WAKE_LOCK` izni); `HzPin.kt` (+ `hz_pin`, `hw_fields`/`hw_ex` probu, ACTION_DOWN ve `display_rate` yeniden uygulaması, `clearHzPin`/`applyHzPinHints`); `ColorOverrides` ve 3 Spec; `DecoderLatencyKnobs` + `dec_lowlat`/`dec_oprate`; `src/debug/.../VideoTestActivity.kt` ve manifest girdisi.
- **Taşınan:** `HzSwitchCounter` -> `stream/HzSwitchCounter.kt`; `OutputFormatReport`/`OutputFormatLogGate` -> `video/OutputFormatReport.kt`. `OperatingRate` (`MAX`, `resolve`) `OperatingRate.kt`'te kaldı.
- **Kalan:** `ping_ms`, `RttStats`, `TrafficClass.trySet` (dosya soketleri). `applyRefreshRate`/`releaseRefreshRate` düz `preferredDisplayModeId` + `setSurfaceFrameRate` (log parametresi gitti).
- **Testler:** `DecoderLatencyKnobsTest` -> `DecoderFormatTest`, `ColorOverridesTest` -> `OutputFormatReportTest`, `HzPinTest` -> `HzSwitchCounterTest` (yeniden adlandırıldı, yalnız kalan davranış); `WifiKnobsTest`, `DevKnobsTest`, `Hdr10DecoderFormatTest`, `LatencyStageStatsTest` düzeltildi. Yeni test `removedExperimentKnobsAreUnknownAndNeverListed`: kaldırılan anahtarlar tanınmaz, `ignored` listesine girmez, çökme yok.
- **Varsayımlar / davranış notları:**
  - `VideoRenderer` artık her yerde üretim varsayılanını (`operating-rate=32767`, configure/start hatasında bir kerelik fps yedeği) kullanır. Eskiden constructor varsayılanı "yedek yok" idi, ama MainActivity zaten STANDARD veriyordu; üretim yolu aynı.
  - `ev=codec_start` hâlâ `lowlat=off oprate=max` yazar (yedekte `oprate=rejected`); `ev=dec_lowlat_rejected` olayı ve alanları (`lowlat=off oprate=max keys=operating-rate`) korundu.
  - `wifi_knobs` log satırı artık yalnız `ping_ms=N`. `tools/` ve `scripts/` kaldırılan alanları grep'te kullanmıyor.
  - `ev=profile` `knobs=` listesinden kaldırılan anahtarlar çıktı.
- **Tablette kontrol:**
  1. Anahtarsız açılış, USB ve Wi-Fi: görüntü + ses akar; `ev=codec_start` satırında `lowlat=off oprate=max`, `operating_rate=32767`.
  2. Oyun 60: `display_mode` satırı, panel 60 Hz'e iner, `ev=set_frame_rate` bir kez yazılır, `ev=stats` içinde `hz_switches=` hâlâ var.
  3. `--ez dev true --es hz_pin all --ei tos_ctl 184 --ez wifi_ll true --es color_range limited` ile açılış çökmez, hiçbir etkisi yok.
  4. Wi-Fi'da dosya (WebDAV) bağlantısı çalışır (`TrafficClass.trySet`).
  5. Debug APK'da `.debug.VideoTestActivity` artık yok (beklenen).
- **Önerilen belge metni (orkestratör):**
  - `docs/KNOBS.md`: `tos_ctl`, `tos_video`, `wifi_ll`, `hz_pin`, `color_range`, `color_standard`, `color_transfer`, `dec_lowlat`, `dec_oprate` satırlarını "removed T-300" işaretle (tanınmaz, hata vermez). `ping_ms` kalır.
  - `docs/LOGGING.md`: `wifi_knobs` tek alan `ping_ms=`; `traffic_class`, `wifi_lock`, `hz_pin` olayları kaldırıldı; `codec_start` `lowlat=`/`oprate=` sabit (`off`/`max`, yedekte `oprate=rejected`); `dec_lowlat_rejected` yalnız operating-rate yedeğini anlatır.
  - Decision 0026: sınıf tablosundan bu 9 anahtar çıkar; debug kaynak setindeki VideoTestActivity kaldırıldı notu.

## Open questions

- Yok. T-197 (`ctl_lowat_kb`) ileride `WifiKnobs.kt`'ye dokunacaksa dosya şimdi yalnız `pingMs` taşıyor.
