---
id: T-004
title: Mac sanal ekran probu — 2800×1840 sanal ekran oluştur ve yakala
status: review
phase: 0
owner: mac-host-dev
depends_on: []
decisions: [0002]
files:
  - probes/vdisplay-probe/
---

## Amaç

Projenin en kritik Mac varsayımını doğrulamak: macOS 27'de `CGVirtualDisplay` ile tabletin çözünürlüğünde (HiDPI) bir ekran oluşturulabilir ve ScreenCaptureKit ile yakalanabilir.

## Kapsam dışı

- Kodlama (VideoToolbox), ağ, menü çubuğu uygulaması.

## Kabul kriterleri

- [ ] Swift paketi, komut satırı aracı: `swift run vdisplay-probe --width 2800 --height 1840 --hidpi --seconds 30`.
- [ ] Sanal ekran oluşur. Aktif ekran listesinde ID, piksel boyutu ve nokta boyutu (HiDPI ise 1400×920 pt) yazdırılır.
- [ ] Mevcut modlar listelenir (HiDPI 2x modu dahil). Hangi modun seçildiği yazdırılır.
- [ ] ScreenCaptureKit ile bu ekran yakalanır: ilk kare PNG olarak `probes/vdisplay-probe/out/` altına kaydedilir. 10 saniye boyunca kare sayısı/FPS ölçülür (ekranda hareket yokken ve varken).
- [ ] Screen Recording izni yoksa anlaşılır hata mesajı verilir, çökmez.
- [ ] Süre dolunca veya Ctrl+C'de sanal ekran temizce kaldırılır.
- [ ] Private API tek bir `VirtualDisplay.swift` dosyasında. android-display'den uyarlanan kısımlar yorumla kaynak gösterir.
- [ ] `out/` dizini `.gitignore`'da.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

SwiftPM paketi `probes/vdisplay-probe`: `ProbeCore` (arg parse, mod seçimi, kare sayacı; test edilir), `vdisplay-probe` (VirtualDisplay.swift = tek private API dosyası, runtime `NSClassFromString`+KVC ile, başlık gerekmez; Capture.swift = SCK; main.swift = akış). Akış: izin preflight, sanal ekran, liste/mod seçimi, SCK yakalama, ilk kare PNG, 10 sn pencerelerle FPS, temiz kaldırma (SIGINT/SIGTERM dahil).

## Handoff

- **Commit:** son commit of `task/T-004-vdisplay-probe` (`git log -1`)
- **Dokunulan dosyalar:** `probes/vdisplay-probe/` (Package.swift, Sources/ProbeCore, Sources/vdisplay-probe/{VirtualDisplay,Capture,main}.swift, Tests/ProbeCoreTests), bu kart. `out/` zaten `probes/**/out/` ile .gitignore'da.
- **Varsayımlar:** CGVirtualDisplay runtime'da `CGVirtualDisplayDescriptor/Settings/Mode/CGVirtualDisplay` sınıfları ve KVC anahtarlarıyla (name, maxPixelsWide/High, sizeInMillimeters, vendorID/productID/serialNum, queue, hiDPI, modes) sürülüyor. HiDPI için modlar 1400x920 (2x) + 2800x1840 (1x), hiDPI=1. macOS 27'de bu değişmiş olabilir.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Sanal ekran oluşturma, mod seçimi, SCK yakalama, FPS, temiz kaldırma HİÇ çalıştırılmadı (paralel T-005 nedeniyle). Yalnızca build, 4 birim testi ve `--bogus` hata yolu çalıştı. Orkestratör çalıştırmalı (Screen Recording izni terminal uygulamasında verilmiş olmalı):
  1. `cd probes/vdisplay-probe && swift run vdisplay-probe --width 2800 --height 1840 --hidpi --seconds 30`
  2. Beklenen: `virtual display created`, aktif ekran listesinde 2800x1840 px / 1400x920 pt, HiDPI 1400x920 modu seçili, `out/first-frame.png`, 3 pencere FPS (1. pencerede boşta; sonrakilerde sanal ekranda pencere sürükle).
  3. Ctrl+C ile de dene; ekran kaybolmalı (System Settings > Displays).
  4. İzin kapalıyken çalıştır: çıkış kodu 77 ve açıklayıcı mesaj beklenir.
  Olası sorunlar: applySettings false dönerse mod/hiDPI kombinasyonunu ayarla; SCK ekranı görmezse bekleme süresini (1 sn) artır; CGDisplaySetDisplayMode başarısız olabilir.
- **Açık sorular:** Yok.
