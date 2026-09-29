---
id: T-005
title: Mac kalem alıcı probu — sentetik tablet olayları enjekte et ve doğrula
status: todo
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

- [ ] `pen-view` modu: küçük bir AppKit penceresi. Gelen her `NSEvent` için tip, subtype, pressure, tilt, rotation, proximity (enter/leave, pointerType), deviceID gösterilir. Basınca göre kalınlaşan çizgi çizer.
- [ ] `inject` modu: `swift run pen-sink-probe inject --pattern ramp|circle|tilt` → yakınlık girişi, basıncı 0→1→0 değişen, eğimi taranan bir vuruş, yakınlık çıkışı. Kalem olayları android-display'deki yöntemle (proximity + `kCGEventMouseSubtypeTabletPoint`) üretilir.
- [ ] Accessibility izni yoksa anlaşılır mesaj verilir, çökmez.
- [ ] `pen-view` açıkken `inject` çalıştırıldığında pencerede basınç/eğim değerleri beklenen aralıkta görülür (kullanıcı/orkestratör doğrular).
- [ ] Krita'da basınçlı fırçayla `inject --pattern ramp` çizgisinin kalınlaşıp inceldiği kontrol edilir (kullanıcı doğrular).
- [ ] Enjeksiyon mantığı (olay alanlarını dolduran kısım) ileride `MateBridgeHost`'a taşınabilecek şekilde ayrı bir dosyada.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
