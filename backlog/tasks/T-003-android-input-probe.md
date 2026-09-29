---
id: T-003
title: Android girdi probu — kalem, klavye, trackpad olaylarını kaydet
status: done
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

- **Commit:** ilk uygulama 7b5e24e; review düzeltmeleri sonraki commit (`git log task/T-003-input-probe`, tepedeki `T-003:` commit'i). `./scripts/check.sh`: ALL OK (düzeltmelerden sonra tekrar çalıştırıldı).
- **Uyarı:** Tuş kodları (keyCode/scanCode) sırasıyla yazılan metni yeniden oluşturabilir. Jsonl'i kişisel veri sayıp commit'leme; klavyede sadece deneme metni yaz (parola/özel içerik yazma).
- **Bağımlılık:** `junit:junit:4.13.2` yalnızca `testImplementation` (test-only); karar kaydını orchestrator main'de ekleyecek.
- **Kabul kutuları:** cihaz davranışına bağlı maddeler işaretsiz; orchestrator cihaz testinden sonra işaretler.
- **Dokunulan dosyalar:** `probes/input-probe/**` (Gradle wrapper dahil) ve bu kart
- **Varsayımlar:** compileSdk 37 (yüklü tek platform), targetSdk 31 (cihaz API 31), minSdk 29. `local.properties` (sdk.dir) gitignore'lu; check.sh'ın çalışması için ANDROID_HOME veya `probes/input-probe/local.properties` (`sdk.dir=...`) gerekir. ERASER tool type da kalem sayılıp Hz'e katılır.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Cihazda hiçbir şey denenmedi. Kur, çıktıyı `adb pull /sdcard/Android/data/dev.matebridge.probe.input/files/` ile al. Kontrol: (1) kalemle çizim kalınlığı basınca göre değişiyor, üst özette Hz/basınç/eğim/scan code güncelleniyor; (2) jsonl'de STYLUS hover (ACTION_HOVER_*, distance) ve historySize>0 var; (3) Huawei klavyede tuş basınca keyCode/scanCode kaydediliyor, karakter yok; (4) "Pointer capture" açılınca trackpad/fare hareketinde captured olaylarda relX/relY, iki parmak kaydırmada vscroll/hscroll geliyor; (5) uygulama arka plana atılınca capture bırakılıyor.
- **Açık sorular:** Yok.

## Orkestratör cihaz testi (2026-09-29)

776b179 APK'sı MatePad'e kuruldu, kullanıcı kalem/klavye/trackpad/pointer capture senaryosunu uyguladı. İki oturum, ~4.850 hareket ve 120 tuş olayı. Tüm alanlar kaydedildi, çökme yok. Bulgular `docs/NOTES.md` → "2026-09-29 — Girdi probu sonuçları". Ham JSONL dosyaları repoya konmadı (tuş kodları içeriyor).

Tekrar testi yapıldı: Tab düzgün. Fn ve Huawei halka tuşu uygulamaya ulaşmıyor, klavyede Cmd/Meta yok. Backspace hâlâ test edilmedi (bkz. NOTES).

