---
id: T-002
title: Geliştirme araçlarını ve tableti hazırla
status: done
phase: 0
owner: user
depends_on: []
decisions: []
files: []
---

## Amaç

Ajanların Android projelerini derleyebilmesi ve orkestratörün APK'yı tablete yükleyip log/ekran görüntüsü alabilmesi.

## Kabul kriterleri

Kullanıcı:
- [x] Android Studio (Quail 4, Apple chip) kuruldu, ilk açılışta **Standard** kurulum tamamlandı. (2026.1, JBR 25, SDK platform android-37, build-tools 36.0.0, adb 37.0.1)
- [x] MatePad: Geliştirici seçenekleri açık, **USB hata ayıklama** açık, "Saf mod" kapalı.
- [x] Tablet USB ile Mac'e takılı, "USB hata ayıklamaya izin ver" onaylandı (her zaman izin ver).
- [x] Krita Mac'e kuruldu (krita.org).

Orkestratör doğrular:
- [x] `adb devices` tableti `device` olarak görüyor.
- [x] `adb exec-out screencap -p` ile tabletten ekran görüntüsü alınabiliyor.
- [x] Tablet modeli/Android API seviyesi/ekran çözünürlüğü `docs/NOTES.md`'ye yazıldı.
- [ ] Kablosuz adb (`adb pair`/`adb connect`) çalışıyor mu? (Wi-Fi testleri için faydalı, zorunlu değil.) → Ertelendi; ilk Wi-Fi testinde denenecek.

## Handoff

- **Açık sorular:**
