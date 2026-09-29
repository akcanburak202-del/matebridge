---
id: T-005
title: Mac kalem alıcı probu — sentetik tablet olayları enjekte et ve doğrula
status: done
phase: 0
owner: mac-host-dev
depends_on: []
decisions: [0002]
files:
  - probes/pen-sink-probe/
---

## Amaç

Tablete ihtiyaç duymadan Mac tarafının kalem yolunu doğrulamak: `CGEvent` ile basınç, eğim ve yakınlık içeren tablet olayları üretildiğinde macOS uygulamaları (kendi test penceremiz + Krita) bunları basınçlı kalem olarak görüyor mu?

## Kapsam dışı

- Ağ, tablet, sanal ekran.

## Kabul kriterleri

- [x] `pen-view` modu: küçük bir AppKit penceresi. Gelen her `NSEvent` için tip, subtype, pressure, tilt, rotation, proximity (enter/leave, pointerType), deviceID gösterilir. Basınca göre kalınlaşan çizgi çizer.
- [x] `inject` modu: `swift run pen-sink-probe inject --pattern ramp|circle|tilt` → yakınlık girişi, basıncı 0→1→0 değişen, eğimi taranan bir vuruş, yakınlık çıkışı. Kalem olayları android-display'deki yöntemle (proximity + `kCGEventMouseSubtypeTabletPoint`) üretilir.
- [x] Accessibility izni yoksa anlaşılır mesaj verilir, çökmez.
- [x] `pen-view` açıkken `inject` çalıştırıldığında pencerede basınç/eğim değerleri beklenen aralıkta görülür (kullanıcı/orkestratör doğrular).
- [x] Krita'da basınçlı fırçayla `inject --pattern ramp` çizgisinin kalınlaşıp inceldiği kontrol edilir (kullanıcı doğrular).
- [x] Enjeksiyon mantığı (olay alanlarını dolduran kısım) ileride `MateBridgeHost`'a taşınabilecek şekilde ayrı bir dosyada.
- [x] `./scripts/check.sh` geçiyor.

## Plan

SwiftPM paketi `probes/pen-sink-probe`: `PenInjection` kütüphanesi (alan eşlemesi + injector + desenler, host'a taşınabilir), `pen-sink-probe` çalıştırılabilir (pen-view / inject), XCTest ile alan eşlemesi testleri. Enjeksiyon: tabletProximity olayı, sonra kTabletPoint alt tipli mouse olayları (basınç/eğim alanları), en sonda proximity-out. SIGINT/SIGTERM'de basılı olan her şey bırakılır.

## Handoff

- **Commit:** bkz. git log, dal task/T-005-pen-sink-probe
- **Dokunulan dosyalar:** probes/pen-sink-probe/** (Package.swift, Sources/PenInjection/{PenInjection,Patterns}.swift, Sources/pen-sink-probe/main.swift, Tests/), bu kart
- **Varsayımlar:** Basınç/eğim CGEvent double alanlarına 0..1 / -1..1 yazılır (CG kuantize eder, testte ±0.005 tolerans). Proximity olayı `CGEvent.type = .tabletProximity` + tabletProximityEvent* alanlarıyla kuruluyor; NSEvent'e proximity olarak ulaşıp ulaşmadığı çalışma zamanında doğrulanmadı. Varsayılan enjeksiyon dikdörtgeni ana ekranın ortası 800x300 (pen-view penceresi 1000x600 ortada açılır).
- **Test edilmeyenler / cihazda doğrulanacaklar:** `inject` hiç çalıştırılmadı (paralel T-004 ajanı; imleç + Accessibility). check.sh geçti (build + 5 test). Orkestratör sırayla çalıştırsın:
  1. `cd probes/pen-sink-probe && swift build`
  2. Terminal 1: `swift run pen-sink-probe pen-view` (pencere ortada açılır)
  3. Terminal 2 (terminal uygulamasına Accessibility izni gerekir): `swift run pen-sink-probe inject --pattern ramp`, sonra `--pattern circle`, `--pattern tilt`
  4. Beklenen: pencerede `tabletProximity enter=true`, sonra `sub=1` ile p 0->1->0, tilt aralığı -1..1, çizgi kalınlaşıp incelir; sonda `enter=false`. Ctrl-C ile yarıda kesince buton/proximity bırakılmalı.
  5. Krita: `inject --pattern ramp --x N --y N --w N --h N` ile tuval üzerine; çizgi kalınlaşıp incelmeli.
  Accessibility yoksa çıkış kodu 3 ve açıklayıcı mesaj beklenir (AXIsProcessTrusted, prompt tetiklemez).
- **Açık sorular:** Yok. NSEvent.pressure ile CGEvent tablet pressure eşlemesi macOS 27'de farklı çıkarsa yalnızca PenEventFields düzeltilir.

- **Düzeltme turu (review):** PenSession tüm postları tek kilit altında serileştirir, cancel() bayrağı + gerçek durumdan bırakma; SIGHUP/SIGQUIT eklendi; drag/move temas durumundan; proximity yeteneği maskesi + buttonNumber/clickState eklendi; pen-view sınırlandı. Yetenek maskesi SDK IOLLEvent.h:316-329 değerleriyle (0x25C7) sabitlendi, testle pinli; VendorPointerType set edilmiyor (satıcıya özel değer); android-display alan listesiyle karşılaştırılmadı (kaynağa erişilmedi). Test: 9 test geçti.

## Orkestratör cihaz testi (2026-09-29)

- `pen-view` + `inject --pattern ramp` → `tabletProximity IN`, `leftMouseDragged sub=1`, basınç 0→1→0, çizgi kalınlaşıp inceliyor. `--pattern tilt` → eğim −1…+1 taranıyor. Vuruş sonu: `leftMouseUp` ardından `tabletProximity enter=false pointerType=1 deviceID=1`.
- Krita 5.3.4, "Basic-5 Size Opacity" fırçası: `ramp` ve `circle` desenleri basınca göre kalınlık ve opaklık değiştiriyor. Krita sentetik kalemi basınçlı kalem olarak tanıyor.
- İlk denemede pen-view önde değildi, olaylar öndeki Terminal'e gitti. Bu probun değil test kurulumunun hatası.

