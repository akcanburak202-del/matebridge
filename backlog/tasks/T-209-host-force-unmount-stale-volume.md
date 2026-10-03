---
id: T-209
title: Force-unmount a stale tablet files volume when its token is dead, then remount
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-206]
decisions: [0015, 0028]
files:
  - host-mac/Sources/MateBridgeCore/Files/TabletFilesPlanner.swift
  - host-mac/Sources/MateBridgeHost/Files/TabletFilesBridge.swift
  - host-mac/Tests/MateBridgeCoreTests/Files/TabletFilesPlannerTests.swift
  - docs/LOGGING.md
  - backlog/tasks/T-209-host-force-unmount-stale-volume.md
---

## Amaç

Cihaz 2026-10-04 ~01:10: tablet uygulaması birkaç kez yeniden başlatıldı (her başlangıç yeni WebDAV token'ı demek). Mac eski "MatePad" birimini çıkarmaya çalıştı ama birim meşguldü (Finder'da açıktı): `ev=unmount result=error code=16` (EBUSY). Ölü birim `/Volumes/MatePad`'de kaldı (`ls`: Permission denied), sonraki bağlamalar `ev=mount result=error code=17` (EEXIST) ile başarısız oldu. Kullanıcı: "Tablet dosyalarını aç" → "bağlanamadı"; Finder'da MatePad'e girince "öğesinin özgünü bulunamadı". `diskutil unmount force /Volumes/MatePad` ile düzeldi.

## Bağlam

- Token değişince eski birimdeki kimlik bilgisi geçersizdir; birimde yazılmayı bekleyen veri sunucuya zaten ulaşamaz. Bu yüzden **ölü token'lı** birimi zorla çıkarmak veri kaybı yaratmaz (tablet tarafı açısından); normal (geçerli token'lı) kullanıcı birimine zorla çıkarma uygulanmaz.
- T-206 eject mantığı: kendi başlattığımız çıkarma kullanıcı "Çıkar"ı sayılmamalı; zorla çıkarma da kendi çıkarmamızdır.
- EEXIST'te: bağlama noktası bizim ölü birimimizse (yol, bilinen önceki bağlama yolumuz ve mount listesinde `http://127.0.0.1:<eski port>/MatePad/`), önce zorla çıkar, sonra bağla. Başka bir şeyse (kullanıcının kendi "MatePad"i) dokunma, hata göster.
- Zorla çıkarma `diskutil unmount force` ya da `unmount(2)` `MNT_FORCE`; arayüz açmaz.

## Kapsam dışı

- Tablet tarafı, protokol.

## Kabul kriterleri

- [ ] [XCTest] Token değişti + çıkarma EBUSY → bir kez zorla çıkarma → başarılıysa yeni token ile bağlama (yeniden bağlama niyeti varsa) ya da kullanıcı açtığında bağlama başarılı.
- [ ] [XCTest] Bağlama EEXIST ve yol bizim ölü birimimiz → zorla çıkar + bir kez yeniden dene; yol bizim değilse zorla çıkarma yok, hata görünür.
- [ ] [XCTest] Geçerli token'lı birimde zorla çıkarma asla yok (oturum sonu teardown'da EBUSY → normal yeniden deneme, bugünkü gibi).
- [ ] [XCTest] Zorla çıkarma kullanıcı "Çıkar"ı (T-206 eject) sayılmaz.
- [ ] [device] MatePad Finder'da açıkken tablet uygulamasını yeniden başlat (force-stop + start): birim birkaç saniyede yeni token ile geri gelir; "Tablet dosyalarını aç" çalışır; `ev=unmount … force=1` bir kez.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
