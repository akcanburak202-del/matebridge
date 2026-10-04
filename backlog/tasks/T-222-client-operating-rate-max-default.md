---
id: T-222
title: Decoder operating rate "max" by default (device A/B result of T-217)
status: review
phase: 6
owner: android-client-dev
depends_on: [T-217]
decisions: [0026]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/OperatingRate.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/DevKnobsTest.kt
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-222-client-operating-rate-max-default.md
---

## Amaç

T-217 cihaz A/B'si (docs/NOTES.md 2026-10-04 ~11:00–11:50): `KEY_OPERATING_RATE = 32767` ("ihtiyaçtan hızlı çalış") HiSilicon HEVC decoder'ın 60 fps'teki düşük saat (DVFS) gecikmesini kaldırıyor.
- RE4 (native) Oyun 60: çözme p50 18,0 → 13,4 ms; `cb_skip_pct` p90 %24,5 → %1,7; eksik kare/sn 0,59 → 0,01 (yavaş çözmede tablet kuyruğu kare atıyordu).
- Ori (GameHub) Oyun 60 1848×1214: çözme 17,5 → 14,1 ms, yakalama→gösterim −5 ms.
- Akıcı çizim 120 fps: çözme aynı (9,0 ms), `cb_skip_pct` p90 %6,2 → %1,7, gösterim p95 16,7 → 8,3 ms; gerileme yok. Sıcaklık ~40 °C.
- `hisi` vendor anahtarları ek ~0,2 ms; `vdec-lowlatency` decoder tarafından reddediliyor.

## Kabul kriterleri

- [ ] [JVM] Ayar yokken `createCodec` operating rate'i 32767 yazar (`oprate=max`); `--ez dev true --es dec_oprate fps` eski davranışı (akış fps'i) verir. Configure reddederse T-217'nin tek seferlik geri düşüşü (anahtarsız) korunur.
- [ ] [JVM] `dec_lowlat` varsayılanı `off` kalır.
- [ ] [doc] KNOBS satır 23d ve LOGGING (`codec_start oprate=max` varsayılan) güncellenir.
- [ ] [device] Normal açılışta `codec_start … oprate=max requested_rate=32767`, görüntü ve kalem normal.

## Plan

1. `DecoderLatencyKnobs` kurucu varsayılanı `opRate = MAX`; `parse` yok/bilinmeyen `dec_oprate` → `max`. Yeni `STANDARD` (= `off`, `max`) uygulama varsayılanı; `DevKnobs.decoderLatency` varsayılanı `STANDARD`.
2. `DEFAULT` adı korunur ama anlamı "T-217 öncesi format = createCodec'in tek seferlik geri düşüş formatı" (`off`, `fps`) olur: `VideoRenderer` dosya listesinde değil ve geri düşüşü `DEFAULT` + `isDefault` ile yapıyor; böylece `max` reddedilirse akış fps'li formata bir kez düşülür, `dec_oprate=fps` (eski davranış) reddi yeniden denenmez (T-217 öncesi gibi).
3. Testler: T-217 "varsayılan değişmedi" kilidi yeni varsayılanı (32767) sabitler; varsayılanın reddi → fps formatına tek geri düşüş testi; `fps` açıkça eski formatı verir. DevKnobsTest varsayılanları `STANDARD`.
4. KNOBS 23d, LOGGING `codec_start` varsayılanı `oprate=max`.

## Handoff

- **Commit:** `814ccea` (uygulama; plan `6ff0417`), dal `task/T-222-client-operating-rate-max-default`. `./scripts/check.sh`: ALL OK.
- **Dokunulan dosyalar:** `client-android/app/src/main/kotlin/dev/matebridge/client/video/OperatingRate.kt`, `…/session/DevKnobs.kt`, `client-android/app/src/test/kotlin/dev/matebridge/client/video/DecoderLatencyKnobsTest.kt`, `…/test/…/session/DevKnobsTest.kt`, `docs/KNOBS.md` (23d), `docs/LOGGING.md`, bu kart.
- **Ne değişti:**
  - `DecoderLatencyKnobs` kurucu varsayılanı `opRate = MAX`; yeni `STANDARD` (= `off`, `max`) uygulama varsayılanı. `parse` yok/bilinmeyen değerde `STANDARD`'ın değerini verir; `DevKnobs.decoderLatency` varsayılanı `STANDARD`. `dev` olmadan `dec_*` yine yok sayılır → `max`.
  - `DEFAULT` adı **korundu** ama artık "T-217 öncesi format = geri düşüş formatı" (`off`, `fps`) demek: `VideoRenderer` dosya listesinde değil ve tek seferlik geri düşüşü `DEFAULT`/`isDefault` ile yapıyor. Böylece varsayılan `max` configure/start'ta reddedilirse bir kez akış fps'li formata düşülür (`dec_lowlat_rejected lowlat=off oprate=max keys=operating-rate`, `codec_start … requested_rate=<fps> lowlat=off oprate=rejected`). `--ez dev true --es dec_oprate fps` T-222 öncesi formatı bayt bayt verir ve (T-217 öncesi gibi) reddi yeniden denenmez.
  - `dec_lowlat` varsayılanı `off`.
- **Testler:** T-217'nin "varsayılan değişmedi" kilidi (`withoutTheKnobTheFormatIsTodays`) **yeni varsayılanı sabitleyecek şekilde değiştirildi** → `withoutTheKnobTheOperatingRateIsMax` (format = T-217 öncesi, `operating-rate` yerinde 32767; `requested_rate=32767 … lowlat=off oprate=max`). Yeni: fps=0'da da 32767; varsayılanın start hatası → tek geri düşüş (akış fps'i); `dec_oprate=fps` → eski format; MainActivity zinciri (`DevKnobs.parse` boş/`dev` yok → `STANDARD`, `dev`+`fps` → `DEFAULT`). `hisi`/`all`/`vdec` testleri artık `max` oranla beklenir; `aRejectedLowLatKeepsTheDefaultOprateFieldAsFps` açıkça `FPS` kullanır. DevKnobsTest varsayılan beklentileri `STANDARD`.
- **Varsayımlar:** `VideoRenderer`'ın kendi kurucu varsayılanı (`decoderTuning = DEFAULT`) `fps` kaldı; uygulamada `MainActivity` her zaman `devKnobs.decoderLatency` geçtiği için etkisi yok, yalnız tuning vermeyen testler (ör. `LatencyStageStatsTest`) eski formatı görür.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  1. `dev` olmadan normal açılış: `adb logcat -s 'MB:*' | grep codec_start` → `requested_rate=32767 … lowlat=off oprate=max accepted … operating_rate=32767` (ya da codec'in yazdığı değer); `dec_lowlat_rejected` **yok**.
  2. Görüntü ve kalem normal; Oyun 60 (RE4) ve Akıcı çizim 120'de çözme süresi/`cb_skip_pct` T-217 A/B'deki `max` değerlerine yakın.
  3. `--ez dev true --es dec_oprate fps` ile açılış → `requested_rate=60 … oprate=fps` (eski davranış).
  4. `diag ev=dev_knobs` dev yokken `ignored=-` (hiç `dec_*` verilmediyse).
- **Açık sorular:** `DecoderLatencyKnobs.DEFAULT` adı artık uygulama varsayılanı değil (geri düşüş formatı). Okunurluk için ileride `VideoRenderer`'da `DEFAULT`→`FALLBACK`, `isDefault`→`isFallback` yeniden adlandırması yapılabilir (bu kartın dosya listesi dışında olduğu için yapılmadı).
