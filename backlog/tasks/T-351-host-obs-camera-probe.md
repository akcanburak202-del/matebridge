---
id: T-351
title: Host deneme — OBS sanal kamera sink akışına dışarıdan kare yazılabiliyor mu?
status: todo
phase: 7
owner: mac-host-dev
depends_on: []
decisions: [0040]
files:
  - tools/obs-cam-probe/
  - backlog/tasks/T-351-host-obs-camera-probe.md
---

## Amaç

Karar 0040'ın ön koşulu: MateBridge, ücretli developer hesabı olmadan OBS Studio'nun imzalı kamera uzantısını webcam olarak kullanabilir mi? Bunun cevabını veren küçük, bağımsız bir Swift komut satırı aracı.

## Kapsam

1. `tools/obs-cam-probe/`: bağımsız SwiftPM paketi (host uygulamasına dokunmaz, yeni bağımlılık yok; yalnız CoreMediaIO, CoreMedia, CoreVideo).
2. `--list`: tüm CMIO cihazlarını (ad, UID, akış sayısı ve yönleri) yazar. OBS'in cihazını bulur (OBS kaynağındaki `plugins/mac-virtualcam` sabit cihaz UUID'si ya da ad "OBS Virtual Camera").
3. `--pattern [--seconds N] [--size 1280x720] [--fps 30]`: OBS'in eklentisinin yaptığı gibi sink akışını bulur (`kCMIODevicePropertyStreams`, çıkış yönlü akış), `CMIOStreamCopyBufferQueue` + `CMIODeviceStartStream`, ardından hareketli bir test desenini (renk çubukları + kayan kutu + kare sayacı) `CVPixelBuffer` (BGRA ya da OBS'in beklediği biçim: kaynağa bak) → `CMSampleBuffer` olarak `CMSimpleQueueEnqueue` ile yazar. Çıkışta `CMIODeviceStopStream`.
4. Hata yolları açık ve kısa: cihaz yok ("OBS kurulu mu, sanal kamera bir kez başlatıldı mı?"), sink akışı yok, izin hatası (OSStatus ile).
5. Referans: OBS kaynağı `plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm` (OBS 32.2.2). Kod kopyalama yok (GPLv2), yalnız API kullanım sırası.
6. Mac'te pencere açma (Mac'in tek ekranı tablet). Kameraya erişim izni isteyen bir şey yapma.

## Kabul

- `swift build` geçer; `--list` OBS kuruluysa cihazı gösterir (orkestratör çalıştırır).
- Görsel doğrulama kullanıcıda: araç `--pattern` ile çalışırken FaceTime/Photo Booth'ta "OBS Virtual Camera" seçilir, desen hareketli görünür. OBS uygulaması açık ve kapalıyken ayrı ayrı.
- `./scripts/check.sh` geçer (araç check.sh'e eklenmez, ayrı).

## Plan

## Handoff

## Open questions
