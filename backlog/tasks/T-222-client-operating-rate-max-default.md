---
id: T-222
title: Decoder operating rate "max" by default (device A/B result of T-217)
status: todo
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

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
