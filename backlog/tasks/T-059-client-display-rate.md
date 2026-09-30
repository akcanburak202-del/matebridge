---
id: T-059
title: Tablet — panel hızını host'a bildir (DISPLAY_RATE)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-057]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-059-client-display-rate.md
---

## Amaç

PROTOCOL `0x07 DISPLAY_RATE` (`proto/display-rate`, `87e36db`) istemci tarafı. Host T-058 seyreltmeyi yapar. Bu kart T-057'den sonra (aynı video dosyaları).

## Kabul kriterleri

- [ ] Kodek + fixture `display_rate`.
- [ ] Panel hızı (mevcut `display_hz` / vsync ölçümü) değişince: yükseliş hemen, düşüş ~0,5 sn kararlıysa; saniyede en çok 4 mesaj; `ACCEPTED`'dan sonra bir kez ilk değer.
- [ ] Sunum zamanlaması akış fps'i yerine gelen kare aralığına/panel hızına uyar; MediaCodec yeniden yaratılmaz.
- [ ] Testler (debounce, sıra). `./scripts/check.sh` (T-058 ile birlikte) geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
