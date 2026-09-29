---
id: T-003
title: Android girdi probu — kalem, klavye, trackpad olaylarını kaydet
status: todo
phase: 0
owner: android-client-dev
depends_on: [T-002]
decisions: [0003, 0004]
files:
  - probes/input-probe/
---

## Amaç

MatePad + M-Pencil + Huawei klavye/trackpad'in Android uygulamasına **gerçekte** ne verdiğini ölçmek. Protokol ve eşleme tabloları bu veriye göre tasarlanacak.

## Kapsam dışı

- Ağ, Mac tarafı, video. Sadece yerel kayıt.

## Kabul kriterleri

- [ ] Tek ekranlı uygulama, tam ekran, yatay. Ekranın bir yarısı kalemle çizim alanı (basınca göre kalınlaşan çizgi), diğer yarısı canlı olay listesi.
- [ ] Kalem: her `MotionEvent` için toolType, action, x, y, pressure, `AXIS_TILT`, `AXIS_ORIENTATION`, `AXIS_DISTANCE`, buttonState, eventTime, `historySize` ve tüm historical örnekler kaydedilir.
- [ ] Hover olayları (`onGenericMotionEvent`, ACTION_HOVER_*) kaydedilir.
- [ ] Klavye: `KeyEvent` için keyCode, scanCode, metaState, repeatCount, action, deviceId/device adı. Karakter **kaydedilmez**, sadece kodlar (AGENTS.md gizlilik kuralı).
- [ ] Trackpad: ekrandaki bir düğmeyle `requestPointerCapture()` açılıp kapanır. Captured ve normal modda gelen olaylar (source, action, x/y veya relative, AXIS_VSCROLL/HSCROLL, AXIS_RELATIVE_X/Y, pointerCount, buttonState) kaydedilir.
- [ ] Tüm olaylar JSON Lines olarak `getExternalFilesDir(null)/probe-<zaman>.jsonl` dosyasına yazılır. Ekranda "Dışa aktar/yeni oturum" düğmesi olur.
- [ ] Ekranın üstünde canlı özet: kalem örnekleme hızı (Hz), son basınç/eğim, son scan code.
- [ ] `./scripts/check.sh` geçiyor. Olay → JSON dönüştürücü için JVM birim testi var.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
