---
id: T-027
title: Çift dokunma Krita'da fırça değiştirmiyor — nedenini bul, karar 0006'yı doğrula ya da değiştir
status: todo
phase: 2
owner: orchestrator
depends_on: [T-023]
decisions: [0006]
files:
  - docs/NOTES.md
  - docs/decisions/
  - backlog/tasks/T-027-krita-eraser-switch.md
---

## Amaç

Karar 0006: kalemin çift dokunuşu host'ta silgi modunu açar; kalem Mac'e silgi ucu (`pointerType = eraser`) olarak bildirilir ve "Krita gibi uygulamalar silgi ucunu kendiliğinden silgiye çevirir". T-025 canlı denemesinde (2026-09-30) bu Krita 5.3.4'te **olmadı**: kullanıcı çift dokunduktan sonra çizmeye devam edebiliyor, fırça değişmiyor.

## Bilinenler (2026-09-30)

- Tablet çift dokunmayı algılıyor (`pen_gesture gesture=double_tap`), host aracı değiştiriyor: ölçüm penceresinde yakınlık olayları `pointerType` 1 ↔ 3 arasında gidip geliyor.
- Krita'nın Tablet Sınayıcı'sı çift dokunmadan sonra "eraser" gösteriyor; çizgi mavi (tablet olayı), tuvalde basınç çalışıyor. Yani Qt olayı tablet olayı ve silgi işaretçisi olarak görüyor.
- Krita kaynak kodu (master, `libs/ui/kis_paintop_box.cc`, `libs/flake/KoToolManager.cpp`, `KoToolProxy.cpp`): tuvale gelen her tablet olayında `KoInputDevice(cihaz, işaretçi, uniqueId)` ile `switchInputDevice` çağrılıyor; yeni cihazda `slotInputDeviceChanged` silgi için `LastEraser_<id>` ya da varsayılan "a) Eraser Circle" fırçasını seçiyor. Kâğıt üzerinde çalışması gerekir.
- Krita, Qt 5.15.7 ile geliyor; `qnsview_tablet.mm` yakınlık olayında `vendorPointingDeviceType` 0 olsa da cihazı `Stylus` sayıyor. Bizim yakınlık olayımız `vendorPointerType` ve benzersiz kimlik (`uniqueID`) alanlarını doldurmuyor (ikisi de 0).
- Kullanıcı şu sırayı da denedi, olmadı: çift dokun → tuvalde çiz → silgi fırçası seç → çift dokun.
- `kritarc` içinde yalnızca `LastPreset_-1` var (fare cihazı); Krita kapanmadan yazılmadığı için kanıt değil.

## Yapılacaklar

- [ ] Krita'da tablet olay günlüğünü açıp (Log Viewer / tablet olay hata ayıklama) tuvale gelen olayların cihaz, işaretçi türü ve kimliğini oku: tuval gerçekten silgi işaretçisi görüyor mu, `switchInputDevice` neden tetiklenmiyor?
- [ ] Yakınlık olayına `vendorPointerType` (kalem 0x0802, silgi 0x080A) ve sıfırdan farklı bir benzersiz kimlik eklemenin etkisini dene (`--inject-test --fixture pen_eraser` ile, kullanıcı varken).
- [ ] Sonuca göre: host düzeltmesi için kart aç (mac-host-dev) **ya da** karar 0006'yı güncelle. Alternatif: çift dokunma eylemi ayarlanabilir olur (silgi ucu / uygulamaya tuş gönder, ör. Krita'da `E`; tuş enjeksiyonu Faz 3'te geliyor).
- [ ] Bulguları `docs/NOTES.md`'ye yaz.

## Plan

_(Orkestratör doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
