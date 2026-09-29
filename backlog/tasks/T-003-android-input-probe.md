---
id: T-003
title: Android girdi probu — kalem, klavye, trackpad olaylarını kaydet
status: review
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

- [x] Tek ekranlı uygulama, tam ekran, yatay. Ekranın bir yarısı kalemle çizim alanı (basınca göre kalınlaşan çizgi), diğer yarısı canlı olay listesi.
- [x] Kalem: her `MotionEvent` için toolType, action, x, y, pressure, `AXIS_TILT`, `AXIS_ORIENTATION`, `AXIS_DISTANCE`, buttonState, eventTime, `historySize` ve tüm historical örnekler kaydedilir.
- [x] Hover olayları (`onGenericMotionEvent`, ACTION_HOVER_*) kaydedilir.
- [x] Klavye: `KeyEvent` için keyCode, scanCode, metaState, repeatCount, action, deviceId/device adı. Karakter **kaydedilmez**, sadece kodlar (AGENTS.md gizlilik kuralı).
- [x] Trackpad: ekrandaki bir düğmeyle `requestPointerCapture()` açılıp kapanır. Captured ve normal modda gelen olaylar (source, action, x/y veya relative, AXIS_VSCROLL/HSCROLL, AXIS_RELATIVE_X/Y, pointerCount, buttonState) kaydedilir.
- [x] Tüm olaylar JSON Lines olarak `getExternalFilesDir(null)/probe-<zaman>.jsonl` dosyasına yazılır. Ekranda "Dışa aktar/yeni oturum" düğmesi olur.
- [x] Ekranın üstünde canlı özet: kalem örnekleme hızı (Hz), son basınç/eğim, son scan code.
- [x] `./scripts/check.sh` geçiyor. Olay → JSON dönüştürücü için JVM birim testi var.

## Plan

Gradle projesi (AGP 9.4.1 yerleşik Kotlin, Gradle 9.8.0 wrapper) `probes/input-probe/`. Saf mantık: `EventJson` (kayıt -> JSON Lines) ve `RateMeter` (Hz), JVM testli. Android adaptörü `EventMapper` MotionEvent/KeyEvent'i düz kayıtlara çevirir (tüm historical örnekler; KeyEvent'ten karakter okunmaz). `ProbeActivity` olayları dispatchTouchEvent / dispatchGenericMotionEvent / dispatchKeyEvent üzerinden kaydeder; captured olaylar çizim view'ının captured listener'ından gelir. `JsonlSink` tamponlu yazar, 100 ms'de flush.

## Handoff

- **Commit:** son `T-003:` commit'i (`git log task/T-003-input-probe`)
- **Dokunulan dosyalar:** `probes/input-probe/**` (Gradle wrapper dahil) ve bu kart
- **Varsayımlar:** compileSdk 37 (yüklü tek platform), targetSdk 31 (cihaz API 31), minSdk 29. `local.properties` (sdk.dir) gitignore'lu; check.sh'ın çalışması için ANDROID_HOME veya `probes/input-probe/local.properties` (`sdk.dir=...`) gerekir. ERASER tool type da kalem sayılıp Hz'e katılır.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Cihazda hiçbir şey denenmedi. Kur, çıktıyı `adb pull /sdcard/Android/data/dev.matebridge.probe.input/files/` ile al. Kontrol: (1) kalemle çizim kalınlığı basınca göre değişiyor, üst özette Hz/basınç/eğim/scan code güncelleniyor; (2) jsonl'de STYLUS hover (ACTION_HOVER_*, distance) ve historySize>0 var; (3) Huawei klavyede tuş basınca keyCode/scanCode kaydediliyor, karakter yok; (4) "Pointer capture" açılınca trackpad/fare hareketinde captured olaylarda relX/relY, iki parmak kaydırmada vscroll/hscroll geliyor; (5) uygulama arka plana atılınca capture bırakılıyor.
- **Açık sorular:** Yok.
