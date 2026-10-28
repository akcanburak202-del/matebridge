---
id: T-388
title: İstemci — geliştirici anahtarları `decoder=<ad>` ve `wifi_ll` (Xiaomi düşük gecikme A/B)
status: todo
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

(boş — ajan yazar)

## Handoff

## Open questions
