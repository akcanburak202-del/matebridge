---
id: T-231
title: Black level lifted on the tablet — client dev knobs to override colour range/standard/transfer and a logged output-format report (A/B on device)
status: todo
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/LOGGING.md
  - backlog/tasks/T-231-client-color-override-knobs.md
---

## Amaç

Belirti ve ölçüm T-230 Amaç bölümünde (Mac 0,0,0 → tablet 16,16,16; beyaz doğru). Tablet ACodec: `color aspects (R:1(Full), P:1(BT709_5), M:1(BT709_5), T:2(SRGB)) dataspace 0x201`. İstemci `VideoRenderer.kt:367-369` STREAM_CONFIG'den `KEY_COLOR_STANDARD/TRANSFER/RANGE` koyuyor; SurfaceView'a MediaCodec doğrudan çıkış veriyor (T-184).

Orkestratörün cihazda A/B yapabilmesi için geliştirici düğmeleri (decision 0026 sınıfı, `--ez dev true` kapısı arkasında, varsayılan davranış değişmez):

- `--es color_range auto|full|limited|unset`: `KEY_COLOR_RANGE` ezilir (`unset` = anahtar hiç konmaz).
- `--es color_standard auto|bt709|bt601|unset`, `--es color_transfer auto|srgb|sdr_video|unset`: aynı mantık.
- Çözücü `INFO_OUTPUT_FORMAT_CHANGED` aldığında çıkış biçimindeki `color-range/standard/transfer` ve varsa `hdr-static-info`'yu bir `ev=decoder_output_format` satırıyla logla (bir kez/format değişiminde).

İzin verilen değerler `Spec.ids` ile sınırlı (log güvenliği, DevKnobs düzeni).

## Kabul kriterleri

- [ ] [JVM] Düğme ayrıştırma: her değer → beklenen MediaFormat davranışı; `dev` kapısı yokken yok sayılır (`ignored=` listesinde).
- [ ] [JVM] Varsayılan (düğme yok) yol bit-bit aynı MediaFormat anahtarlarını koyar.
- [ ] `ev=decoder_output_format` docs/LOGGING.md'de.
- [ ] `./scripts/check.sh` geçer. APK kurma, tablete dokunma: cihaz A/B'sini orkestratör yapar.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
