---
id: T-004
title: Mac sanal ekran probu — 2800×1840 sanal ekran oluştur ve yakala
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
