---
id: T-002
title: Geliştirme araçlarını ve tableti hazırla
status: todo
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
- [ ] Android Studio (Quail 4, Apple chip) kuruldu, ilk açılışta **Standard** kurulum tamamlandı.
- [ ] MatePad: Geliştirici seçenekleri açık, **USB hata ayıklama** açık, "Saf mod" kapalı.
- [ ] Tablet USB ile Mac'e takılı, "USB hata ayıklamaya izin ver" onaylandı (her zaman izin ver).
- [ ] Krita Mac'e kuruldu (krita.org).

Orkestratör doğrular:
- [ ] `adb devices` tableti `device` olarak görüyor.
- [ ] `adb exec-out screencap -p` ile tabletten ekran görüntüsü alınabiliyor.
- [ ] Tablet modeli/Android API seviyesi/ekran çözünürlüğü `docs/NOTES.md`'ye yazıldı.
- [ ] Kablosuz adb (`adb pair`/`adb connect`) çalışıyor mu? (Wi-Fi testleri için faydalı, zorunlu değil.)

## Handoff

- **Açık sorular:**
