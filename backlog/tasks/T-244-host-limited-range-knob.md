---
id: T-244
title: Host experiment — encode limited (video) range (SCK 420v, VUI full=0, STREAM_CONFIG full_range=0) to fix the black lift when the tablet scales the picture
status: done
phase: 6
owner: mac-host-dev
depends_on: [T-230]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-244-host-limited-range-knob.md
---

## Amaç

NOTES 2026-10-05 ~13:40: siyah seviyesi kalkması (Mac 33,39,52 → tablet 47,52,63; 0 → 16) yalnız tablet görüntüyü **büyüttüğünde** oluyor: Oyun modunun 1x oyun ekranı (1848×1214, 2240×1472) panelde 2800×1840'a ölçekleniyor. Günlük (2800×1840, ölçek yok) doğru. Bit akışı doğru (T-230: Y=0, VUI full=1). Hipotez: tablet HWC ölçekleyicisi tam aralık YUV'yi sınırlı aralığa sıkıştırıp tam aralık gibi gösteriyor. Sınırlı aralık akış (yaygın video biçimi) bu yolda doğru işlenebilir.

## Bağlam

- Geliştirici anahtarı `MATEBRIDGE_RANGE=full|limited|auto` (varsayılan `full` = bugünkü yol bit-bit aynı). `auto` = oyun ekranı (1x, kodlanan ≠ panel boyutu) ya da `scale_permille < 1000` iken `limited`, aksi `full`.
- `limited`: SCK `pixelFormat = 420v` (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`), VT etiketleri aynı (709/sRGB/709) ama VUI `video_full_range_flag=0` (T-230 probunda 420v girişte VT bunu kendisi yazdı), `STREAM_CONFIG.full_range = 0` → istemci `KEY_COLOR_RANGE = LIMITED` (istemci değişmez). T-113 yeniden etiketleme 420v için de doğru çalışmalı (`ev=input_retag`).
- Keskin renk (T-235 `sharp_*`, Metal 420f üretir) ve HDR (zaten limited) ile etkileşim: `limited` + `sharp_*` → Metal çıktısı video range yazmalı ya da bu birleşimde knob yok sayılıp loglanmalı (planda seç, test et).
- Log: `ev=range_config requested= applied= reason=` ve `hdr_config`/`profile` satırına `full_range=`.
- Pencere, sanal ekran, çalışan host, adb yok. Kısa sentetik VT denemesi serbest (420v girişle VUI ve geri çözülmüş Y bantları: 0→16, 255→235 beklenir).

## Kabul kriterleri

- [ ] [XCTest] Knob ayrıştırma ve `auto` kararı (oyun ekranı / ölçek / doğal); STREAM_CONFIG `full_range` değeri; sharp/HDR etkileşimi.
- [ ] Varsayılan yol değişmez.
- [ ] `./scripts/check.sh` geçer.
- [ ] [device, orkestratör] Oyun modu 2240×1472'de `limited` ile eşli yakalama: siyah 0 → ~0–3, terminal Mac rengine yakın; Günlük'te `auto` = full ve doğru kalır.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

**Orkestratör (2026-10-05 ~14:00):** iptal, uygulanmadı. Ölçekleme hipotezi yanlış çıktı: kalkma ölçeksiz Günlük'te de var ve APK yeniden kurulunca düzeliyor (NOTES 2026-10-05 ~14:00). Ajan durduruldu.
