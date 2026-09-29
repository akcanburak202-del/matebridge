---
id: T-011
title: Mac görüntü hattı — sanal ekran, yakalama, HEVC kodlama, sınırlı kuyruk
status: todo
phase: 1
owner: mac-host-dev
depends_on: [T-008]
decisions: [0002]
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/VirtualDisplay.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
---

## Amaç

Sanal ekrandan `VIDEO_FRAME` mesajlarına kadar olan hat. Ağa bağlanmaz: çıkışı sınırlı bir kuyruk/sink arayüzüdür; T-014 oturumla bağlar.

## Kabul kriterleri

- [ ] `VirtualDisplay.swift`: `probes/vdisplay-probe`'daki çalışan yaklaşımın ürün sürümü (HiDPI'da yalnız nokta boyutlu mod, NOTES 2026-09-29). Private API yalnızca bu dosyada.
- [ ] ScreenCaptureKit → VideoToolbox **HEVC** (düşük gecikme: real-time, B-frame yok, ayarlanabilir bitrate/FPS, keyframe isteğe bağlı) → Annex-B. İlk çıktı `CODEC_CONFIG`, sonra keyframe. Renk etiketleri `STREAM_CONFIG` ile tutarlı (sRGB/BT.709, tam aralık).
- [ ] Kodlayıcı → sink arasında en çok 2 kare (PROTOCOL.md §5). Politika saf ve `MateBridgeCore/Video`'da birim testli: taşmada eski keyframe olmayan kareler atılır, sonraki kare keyframe istenir.
- [ ] `requestKeyframe()`, `STREAM_CONFIG` değerlerini üreten yapı, temiz durdurma (sanal ekran ve akış kapanır).
- [ ] Doğrulama aracı: `MateBridgeApp --dump-video <dosya> --seconds N` (veya ayrı bir alt komut) Annex-B `.h265` dosyası yazar ve kare sayısı / ortalama boyut / keyframe sayısı / kodlama süresi yazdırır. Bu dosya T-013'te tablette çözme testi için kullanılacak.
- [ ] Ekran Kaydı izni yoksa anlaşılır hata, çökme yok.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
