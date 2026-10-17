---
id: T-351
title: Host deneme — OBS sanal kamera sink akışına dışarıdan kare yazılabiliyor mu?
status: review
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

Tek dosyalık Swift CLI (`tools/obs-cam-probe/Sources/obs-cam-probe/main.swift`): CMIO cihaz listesi, OBS cihazını plist'teki `OBSCameraDeviceUUID` (yoksa ad) ile bul, yön=1 (sink) akışı seç (yoksa indeks 1), `CMIOStreamCopyBufferQueue` + `CMIODeviceStartStream`, BGRA CVPixelBuffer havuzu, desen çiz, `CMSimpleQueueEnqueue`, çıkışta `CMIODeviceStopStream`.

## Handoff

- Dosyalar: tools/obs-cam-probe/{Package.swift,README.md,Sources/obs-cam-probe/main.swift}, bu kart.
- Çalıştır: `cd tools/obs-cam-probe && swift build -c release && .build/release/obs-cam-probe --list` ; `.build/release/obs-cam-probe --pattern --seconds 60` (varsayılan 1920x1080 @30, BGRA; OBS 32.2.2 uzantısı bu biçimi sabit kullanıyor, `--size/--fps` deneme için).
- Varsayımlar: OBS cihaz UUID'si `/Applications/OBS.app/Contents/PlugIns/mac-virtualcam.plugin/Contents/Info.plist` içindeki `OBSCameraDeviceUUID` (7626645E-4425-469E-9D8B-97E0FA59AC75); sink akışı `kCMIOStreamPropertyDirection==1`, yoksa OBS'teki gibi indeks 1. Örnek tampon enqueue'da +1 retain'le devredilir.
- Doğrulanan: build geçti; uzantı henüz onaylı değilken `--list` 0 cihaz + "NOT FOUND" ipucu yazıp 0 ile çıkıyor, `--pattern` kısa hata + çıkış kodu 2. Kamera izni istenmedi, pencere açılmadı.
- Doğrulanmadı: gerçek sink'e yazım (uzantı onayı + OBS'te sanal kamera bir kez başlatma gerekir), FaceTime/Photo Booth'ta görüntü, OBS açık/kapalı farkı. Uzantının sink akışı OBS başlatılana kadar var olmayabilir (CameraNotStarted yolu).

## Open questions
