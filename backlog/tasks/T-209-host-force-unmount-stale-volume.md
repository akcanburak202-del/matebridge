---
id: T-209
title: Force-unmount a stale tablet files volume when its token is dead, then remount
status: in-progress
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

Karar mantığı `TabletFilesPlanner`'da (saf, test edilir); köprü yalnız yürütür ve sonucu bildirir.

1. **Token takibi:** bağlanan birimin token'ı (`FilesSecret`, yalnız bellekte) `mountedPath` ile birlikte tutulur; `ReplacedMount` da token taşır.
2. **Oturum sınırını aşan sonuç:** bugün `sessionEnded`/`sessionStarted` `replacedMounts`'u siler, ama teardown'ın `unmount` sonucu ondan sonra gelir. Artık oturum sınırında silinmez, `inSession=false` işaretlenir: eject çıkarımı, izlenen yol ve yeniden bağlama kapısı yalnız `inSession` olanlara bakar (T-206 davranışı aynı). Kapanışta silinir.
3. **Artık birim (leftover):** `unmountFinished`'ta `stillMounted` içinde olan değiştirilmiş birim (EBUSY) `leftovers`'a geçer (yol, port, token; en çok 4, oturumlar arası, kapanışta silinir). Aynı porttaki sonraki `unmount` sonucunda `detached` ya da hiç bulunmayan artık silinir; bizim yeni bağlamamız aynı yola düşerse de silinir.
4. **Ölü = token farklı:** bir artık, bilinen READY token'ı onun token'ından farklıysa ölüdür. READY yoksa (OFF, oturum yok) bilinmez → zorla çıkarma yok. Aynı token → canlı → asla zorla çıkarma.
5. **Hemen zorla çıkarma (bir kez):** ölü ve henüz denenmemiş artık için `forceUnmount(path:localPort:)` aksiyonu; `unmountFinished` (aynı oturumda token değişimi + EBUSY) ve yeni READY (oturumlar arası, cihazdaki durum) anında. Yeniden bağlama (`autoMountIfArmed`) bekleyen zorla çıkarma sonuçlarını bekler. Sonuç: `forceUnmountFinished(path:localPort:gone:)`.
6. **EEXIST:** köprü NetFS `status == EEXIST`'te `mountCollided(generation:localPort:mountedNow:)` çağırır (`mountedNow`: o porttaki bizim WebDAV birimlerimiz). `mountedNow` içinde ölü artığımız varsa → zorla çıkar + başarılıysa bir kez yeniden bağla (yeniden deneme de EEXIST alırsa hata görünür, döngü yok). Yoksa (kullanıcının kendi "MatePad"i, canlı token'lı birim, bilinmeyen) → zorla çıkarma yok, `lastMountFailed`.
7. **Eject sayılmaz:** artıklar `watchedPaths`'te yok; zorla çıkarma bildirimi `volumeUnmounted`'da eject sayılmaz.
8. **Köprü:** `forceUnmount` yalnız yol hâlâ `127.0.0.1:<port>` WebDAV birimiyse `unmount(2)` `MNT_FORCE`; log `ev=unmount result=ok|error|gone force=1`, EEXIST kararı `ev=mount_exists dead_ours=N`. Yol/token loglanmaz.
9. **Testler** (`TabletFilesPlannerTests.swift`): dört XCTest kriteri + sınır durumları. T-206 testi `busyOldVolumeIsOursAndItsLaterUnmountIsNotAnEject` yeni davranışa (önce zorla çıkarma) göre güncellenir; iddiaları korunur.
10. `docs/LOGGING.md`: T-209 bölümü.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
