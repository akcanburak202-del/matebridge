---
id: T-027
title: Çift dokunma Krita'da fırça değiştirmiyor — nedenini bul, karar 0006'yı doğrula ya da değiştir
status: done
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
- ~~Krita, Qt 5.15.7 ile geliyor; `qnsview_tablet.mm` yakınlık olayında `vendorPointingDeviceType` 0 olsa da cihazı `Stylus` sayıyor.~~ **Yanlış** (bkz. Kök neden). Bizim yakınlık olayımız `vendorPointerType` ve benzersiz kimlik (`uniqueID`) alanlarını doldurmuyor (ikisi de 0).
- Kullanıcı şu sırayı da denedi, olmadı: çift dokun → tuvalde çiz → silgi fırçası seç → çift dokun.
- `kritarc` içinde yalnızca `LastPreset_-1` var (fare cihazı); Krita kapanmadan yazılmadığı için kanıt değil.

## Kök neden (2026-09-30, Krita tablet olay günlüğü)

Tuvale gelen olaylar: işaretçi çift dokunmadan önce `Pen`, sonra `Eraser` (doğru); ama cihaz türü her olayda `NoDevice`, `id: 0`. Qt 5.15 macOS cihaz türünü `vendorPointingDeviceType`'tan çıkarıyor (0 → `NoDevice`); Krita `KoInputDevice::isMouse()` cihaz türü bilinmeyen girdiyi fare sayıyor, `switchInputDevice` fare→fare geçişini yok sayıyor, fırça değişmiyor. Ayrıntı: NOTES 2026-09-30 "Krita çift dokunma". Düzeltme: T-031 (host yakınlık olayına `vendorPointerType` + `uniqueID`).

## Yapılacaklar

- [x] Krita'da tablet olay günlüğünü açıp (Log Viewer / tablet olay hata ayıklama) tuvale gelen olayların cihaz, işaretçi türü ve kimliğini oku: tuval gerçekten silgi işaretçisi görüyor mu, `switchInputDevice` neden tetiklenmiyor?
- [x] (T-031) Yakınlık olayına `vendorPointerType` (kalem 0x0802, silgi 0x080A) ve sıfırdan farklı bir benzersiz kimlik eklemenin etkisini dene (`--inject-test --fixture pen_eraser` ile, kullanıcı varken).
- [x] Sonuca göre: host düzeltmesi için kart aç (mac-host-dev) → T-031. ~~**ya da** karar 0006'yı güncelle. Alternatif: çift dokunma eylemi ayarlanabilir olur (silgi ucu / uygulamaya tuş gönder, ör. Krita'da `E`; tuş enjeksiyonu Faz 3'te geliyor).~~ Karar 0006 geçerli kalıyor; T-031 cihazda doğrulanınca karara not düşülecek.
- [x] Bulguları `docs/NOTES.md`'ye yaz.
- [x] T-031 merge edildikten sonra cihazda (kullanıcı, 2026-09-30: çalışıyor): çift dokunma → silgi fırçası, tekrar çift dokunma → önceki fırça; Krita kapanıp açılınca hatırlanıyor mu.

## Plan

1. Kök neden: Krita tablet günlüğü (yapıldı). 2. T-031 (mac-host-dev, Codex incelemesi). 3. Cihazda doğrulama, karar 0006'ya not, kart kapanışı.

## Handoff

- **Commit:** 56ee1fa (kök neden, kart), T-031 merge 611c8f7
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
