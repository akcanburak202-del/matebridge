---
id: T-388
title: İstemci — geliştirici anahtarları `decoder=<ad>` ve `wifi_ll` (Xiaomi düşük gecikme A/B)
status: done
phase: 7
owner: android-client-dev
depends_on: [T-381]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/WifiLatencyLock.kt
  - client-android/app/src/main/AndroidManifest.xml
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-388-client-decoder-wifi-latency-knobs.md
---

## Amaç

Xiaomi Pad Mini (MTK Dimensity 9400) üzerinde düşük gecikme yolunu ölçmek için, varsayılanı değiştirmeyen iki geliştirici anahtarı (T-381 `audio_out` ile aynı düzen: `--ez dev true` olmadan yok sayılır, kalıcı değil, panelde yok).

1. **`--es decoder <ad>`:** Ana video çözücüsü `createDecoderByType` yerine `MediaCodec.createByCodecName(<ad>)` ile açılır (örnek: `c2.mtk.hevc.decoder.lowlatency`). Bugünkü varsayılan çözücü `c2.mtk.hevc.decoder`, `FEATURE_LowLatency` desteklemiyor; `.lowlatency` varyantı listede var ama seçilmiyor (T-384 tek karede açılabildiğini gösterdi). Ad açılamazsa ya da istenen MIME'yi desteklemiyorsa bugünkü yola döner ve bunu loglar. Mevcut `lowLatencySupport` / `KEY_LOW_LATENCY` mantığı seçilen çözücünün yeteneğine göre çalışır.
2. **`--ez wifi_ll true`:** Yayın sürerken `WifiManager.createWifiLock(WIFI_MODE_FULL_LOW_LATENCY, …)` tutulur (ön planda ve oturum boyunca; arka plana geçince/oturum bitince bırakılır). API desteklemiyorsa loglar, hiçbir şey yapmaz. Gerekli izin (`WAKE_LOCK`) manifestte yoksa eklenir; başka izin gerekmez. Kilit kodu `session/WifiLatencyLock.kt`.

## Kabul

1. Anahtarlar `DevKnobs`'ta, `ev=dev_knobs` satırında ve `docs/KNOBS.md`'de. Anahtarsız davranış bayt bayt aynı.
2. Video başlangıç logu (bugünkü çözücü adı/`low_latency` satırı) seçilen çözücü adını, `FEATURE_LowLatency` desteğini, `KEY_LOW_LATENCY` uygulanıp uygulanmadığını ve geri düşüşü (`decoder_fallback reason=`) gösterir. `wifi_ll` için `ev=wifi_lock mode=low_latency state=held|released|unsupported`. `docs/LOGGING.md` güncel.
3. Yardımcı çözücü (Tam renk, `AuxDecoder`) ve öz test bu anahtardan etkilenmez.
4. Birim testleri: anahtar ayrıştırma (dev kapısı dahil), çözücü seçimi/geri düşüş (sahte fabrika ile).
5. `./scripts/check.sh` geçer. Cihaz denemesi bu kartta YOK (orkestratör yapar); tablete kurulum yapma.

## Plan

1. `DevKnobs`: `decoder` (STRING, ad kalıbı `[A-Za-z0-9._-]{1,64}`, değilse yok sayılır) ve `wifi_ll` (BOOL), ikisi debugOnly; `knobs=` içinde `decoder:<ad>` / `wifi_ll:1`.
2. `video/DecoderSelect.kt`: `NamedDecoderFactory` (createByCodecName; kodlayıcı/MIME uyuşmazlığı/istisna -> `decoder_fallback reason=` + varsayılan fabrika). Yalnız ana çözücü fabrikası (MainActivity `mainDecoderFactory`); AuxDecoder ve öz test `MediaCodecDecoder.FACTORY` ile kalır. Mevcut `codec_start` satırı (low_latency=, low_latency_fmt=) seçilen çözücüye göre zaten çalışır.
3. `session/WifiLatencyLock.kt`: saf durum makinesi + `WifiManager` kilidi; `onStart` acquire, `onStop`/`onDestroy` release. Manifeste `WAKE_LOCK`.
4. Testler: DevKnobsTest, NamedDecoderFactoryTest, WifiLatencyLockTest. Docs: KNOBS 23n/23o, LOGGING.

## Handoff

- Commit: `git log task/T-388-latency-knobs` (T-388 commit on top of main f1887bbf).
- Dosyalar: `session/DevKnobs.kt` (+`decoder`, `wifi_ll`, `DECODER_NAME`, `Spec.pattern`), `video/DecoderSelect.kt` (yeni, `NamedDecoderFactory`), `video/DecoderCodec.kt` (`MediaCodecDecoder.wrap`), `session/WifiLatencyLock.kt` (yeni), `MainActivity.kt` (`mainDecoderFactory`, `wifiLatencyLock`; onStart/onStop/onDestroy), `AndroidManifest.xml` (`WAKE_LOCK`), testler (`DevKnobsTest`, `NamedDecoderFactoryTest`, `WifiLatencyLockTest`), `docs/KNOBS.md` (23n/23o), `docs/LOGGING.md`.
- Varsayımlar: `isLowLatencyModeSupported` genel API değil (@SystemApi), destek sorgusu yok; `createWifiLock(FULL_LOW_LATENCY)` + `acquire()`, atarsa ya da `isHeld` false ise `state=unsupported` (bir kez). Kilit "ön plan" = `onStart`..`onStop` (oturum durumuna ayrıca bağlanmadı). `decoder` adı `[A-Za-z0-9._-]{1,64}` değilse yok sayılır; `ev=profile knobs=decoder:<ad>`. `wifi_ll` T-300'de kaldırılmıştı; `removedExperimentKnobsAreUnknown...` testinden çıkarıldı. Anahtarsız yol değişmedi (`mainDecoderFactory` = `MediaCodecDecoder.FACTORY`).
- check.sh: Gradle adımı yalnız `DecoderWaitTest.inputParksWithFewWakeUpsAndTheOutputThreadKeepsPolling` ve `OutputParkTest.withParkOffTheGapsKeepBeingPolled` yüzünden kırmızı (bilinen T-367 zamanlama kırılganlığı; makine load 6-8; 2446/2448 yeşil, T-388 testleri yeşil). Sakin makinede yeniden koşulmalı.
- Cihazda bak (orkestratör): `--ez dev true --es decoder c2.mtk.hevc.decoder.lowlatency` -> `MB/decoder ev=decoder_select requested=… name=…`, ardından `ev=codec_start name=… low_latency=on|unsupported low_latency_fmt=1|unset`; `--es decoder nope` -> `W decoder ev=decoder_fallback reason=create_failed`, akış varsayılan çözücüyle sürer; HEVC olmayan ad -> `reason=mime_unsupported`. Tam renk (Aux) çözücüsü değişmez. `--ez wifi_ll true` -> `MB/session ev=wifi_lock mode=low_latency state=held` ön planda, arka plana geçince `released`; `dumpsys wifi` ile kilit doğrulanabilir. `dev` yokken `dev_knobs ignored=` içinde `decoder,wifi_ll`, yeni satır yok.
- Cihazda hiçbir şey denenmedi (kart gereği).

## Open questions
