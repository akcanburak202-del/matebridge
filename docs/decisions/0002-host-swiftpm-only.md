# 0002 — Mac tarafı yalnızca Swift Package Manager

- **Durum:** kabul
- **Tarih:** 2026-09-29

## Bağlam
Birden fazla ajan paralel çalışacak. `.xcodeproj/project.pbxproj` makine tarafından üretilen, okunması zor bir dosya ve her dosya eklemede değişiyor. Paralel dallarda sürekli birleştirme çakışması üretir. Ayrıca ajanlar `swift build`/`swift test` ile Xcode arayüzü olmadan derleyip test edebilmeli.

## Karar
`host-mac/` bir Swift paketi: `MateBridgeCore` (saf mantık, test edilir), `MateBridgeHost` (sistem API'leri), `MateBridgeApp` (menü çubuğu girişi). `.app` paketi ve imzalama `scripts/bundle-host.sh` ile yapılır: Info.plist ve entitlements `Resources/` altında. Minimum macOS 15.

## Sonuçlar
- Tüm proje dosyaları düz metin, birleştirmesi kolay.
- Xcode yine de `Package.swift`'i açıp hata ayıklamak için kullanılabilir.
- TCC izinlerinin kalıcı olması için imza kimliği sabit olmalı. Apple Development sertifikası T-006'da kurulur.
- Tekrar düşünülme koşulu: SwiftPM ile çözülemeyen bir paketleme/entitlement ihtiyacı çıkarsa XcodeGen gibi metin tabanlı bir üretici değerlendirilir.
