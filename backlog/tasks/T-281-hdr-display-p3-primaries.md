---
id: T-281
title: Host — HDR sanal ekranı Display P3 primerleriyle kur (Safari/YouTube HDR)
status: done
phase: 6
owner: mac-host-dev
depends_on: []
decisions: [0032]
files:
  - host-mac/Sources/MateBridgeHost/VirtualDisplay.swift
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/KNOBS.md
  - backlog/tasks/T-281-hdr-display-p3-primaries.md
---

## Amaç

Karar 0032 güncellemesi (2026-10-06): HDR10 için `tf=1` ile kurulan sanal ekran, descriptor'da Display P3 primerlerini alsın. Böylece macOS `MTShouldPlayHDRVideo` geniş gamut şartını geçer ve Safari/YouTube HDR sunar. Ayrıntı ve doğrulama sorgusu: `docs/research/2026-10-06-safari-hdr-virtual-display.md` (§2, §4 deney 1). Protokol değişmez.

## Kabul

1. Sanal ekran HDR için (`transfer.requested == 1`: HDR10 akış ya da `MATEBRIDGE_VD_TRANSFER=1`) kurulurken `initWithDescriptor:`'dan **önce** descriptor'a primerler verilir: kırmızı (0,68, 0,32), yeşil (0,265, 0,69), mavi (0,15, 0,06), beyaz (0,3127, 0,329). Sidecar'ın kullandığı anahtarlar/seçiciler kullanılır (`redPrimary`/`greenPrimary`/`bluePrimary`/`whitePoint`, `CGPoint`). Seçici ya da anahtar yoksa ekran primersiz kurulur, `ev=vd_transfer`'e `primaries_fallback=` yazılır. Kurulum başarısız olmaz.
2. SDR ekran (requested 0) bugünkü gibi primersiz kurulur, bit bit aynı.
3. Özel API yalnız `VirtualDisplay.swift`'te kalır. Karar ve ortam değişkeni ayrıştırma saf olarak `MateBridgeCore`'da yapılır (`VirtualDisplayTransfer` deseni, test edilebilir).
4. Primerler yalnız kurulumda verilebiliyor (`applySettings:` değiştirmez, [Tahmin]). SDR ↔ HDR10 geçişi bugün ekranı yeniden kuruyor (`DisplayReuse` aktarımı karşılaştırıyor); bunun sürdüğünü doğrula. Ekran yeniden kullanımı primerleri de hesaba katmalı: farklı primerli ekran yeniden kullanılmaz. `tf=1` reddedilip eski kipe düşülürse ekran P3 primerli SDR kalabilir; bunu logla (`applied=0 primaries=p3`), ek yeniden kurma gerekmez.
5. Geliştirici anahtarı `MATEBRIDGE_VD_PRIMARIES=default|p3`. Varsayılan: HDR'de `p3`, SDR'de yok. `default` P3'ü kapatır. Geçersiz değer `p3` sayılır ve uyarı logu yazılır. `ev=profile knobs=`'ta görünür. `docs/KNOBS.md`'ye satır ekle.
6. `ev=vd_transfer` satırına `primaries=default|p3` ve `wide_gamut=0|1` eklenir. `wide_gamut`: kurulumdan sonra `CGDisplayCopyColorSpace(id)` → `CGColorSpaceIsWideGamutRGB`; kısa bir gecikmeyle bir kez okunur, ana iş parçacığını bloklamaz.
7. Testler: anahtar ayrıştırma, karar (HDR→p3, SDR→yok, `default`→yok), ekran yeniden kullanım karşılaştırması, log alanları.
8. `./scripts/check.sh`. Host'u çalıştırma, Mac'te pencere açma, tablete dokunma. Cihaz denemesini orkestratör yapar.

## Plan

1. `MateBridgeCore/Video/VirtualDisplayPrimaries.swift` (yeni, saf): `MATEBRIDGE_VD_PRIMARIES` ayrıştırma (`unset|default|p3`, geçersiz = `p3` + `invalid`), karar (`transfer requested != 0` ve knob `default` değil -> `p3`; SDR her zaman `default`), P3 değerleri ve KVC anahtar/seçici adları (`redPrimary`, `greenPrimary`, `bluePrimary`, `whitePoint`; seçici `setRedPrimary:` ...), seçici eksikse `selector_missing` ile primersiz kurulum (`Applied`), log alanları.
2. `VirtualDisplayTransfer.Outcome`'a `primaries` (`Applied`) eklenir (varsayılanlı, mevcut çağıranlar bozulmaz); `logFields(_:edr:wideGamut:)` sonuna `primaries=... wide_gamut=0|1|na` yazar.
3. `DisplayMode`'a `primaries: Choice` (varsayılan `.default`) eklenir; `DisplayReuse.decide` farklı primerli ekranı yeniden kullanmaz (yeni `Reason` eklenmez: `transferChange` altında karşılaştırılır, `StreamCoordinator`'daki kapsamlı `switch` bozulmasın). `VideoSettings` knob'u `applyingExperimentKnobs`'ta okur, `displayMode.primaries` hesaplar. `knobAllowList`'e anahtar eklenir (`ev=profile knobs=`).
4. `VirtualDisplay.swift`: `initWithDescriptor:`'dan once, karar P3 ise ve 4 setter varsa descriptor'a `NSValue(point:)` ile KVC; `transferOutcome.primaries` ve `mode.primaries` doldurulur. `wide_gamut` okuyucusu (`CGDisplayCopyColorSpace` -> `CGColorSpaceIsWideGamutRGB`, kisa `Task.sleep` sonrasi, bir kez) yine bu dosyada statik async fonksiyon.
5. Tek gerekli dis dosya: `StreamCoordinator.logDisplayTransfer` icin ~3 satir (wide_gamut'u okuyup `logFields`'e vermek). Kartin `files:` listesinde yok; ev=vd_transfer'e `wide_gamut` (kabul 6) baska turlu yazilamaz. Handoff/Open questions'ta belirtilir.
6. Testler: ayrıştırma, karar, `resolve`/seçici eksikliği, log alanları, `DisplayReuse` primer farkı, `VideoSettings.displayMode`. `docs/KNOBS.md`'ye satır.

## Handoff

- **Commit:** bkz. `git log task/T-281-hdr-display-p3-primaries` (T-281: implement ...; Plan commiti 2337c817). `./scripts/check.sh`: ALL OK.
- **Dosyalar:**
  - Yeni: `MateBridgeCore/Video/VirtualDisplayPrimaries.swift` (ayrıştırma, karar, P3 değerleri, seçici çözümü, log alanları), `Tests/.../Video/VirtualDisplayPrimariesTests.swift` (23 test).
  - Değişen (Core): `VirtualDisplayTransfer.swift` (`Outcome.primaries`, `logFields(_:edr:wideGamut:)`: sona `primaries=… [primaries_fallback=…] [primaries_reason=invalid_value] wide_gamut=0|1|na`), `GameDisplayPolicy.swift` (`DisplayMode.primaries`, `DisplayReuse` farklı primeri `transferChange` ile yeniden kurar; yeni `Reason` eklenmedi), `VideoSettings.swift` (`vdPrimariesKnob`, `displayMode.primaries`), `EncoderKnobs.swift` (`knobAllowList`'e `MATEBRIDGE_VD_PRIMARIES`), `VirtualDisplayTransferTests.swift` (beklenen log satırları).
  - Değişen (Host): `VirtualDisplay.swift` (descriptor'a `initWithDescriptor:` öncesi KVC ile `redPrimary`/`greenPrimary`/`bluePrimary`/`whitePoint` = `NSValue(point:)`; dört `set…:` seçicisi descriptor'da yoksa primersiz kurar; `primariesKnob` parametresi varsayılan olarak süreç ortamından okunur; `static readWideGamut(displayID:) async`, 0,5 s `Task.sleep` sonra bir kez `CGDisplayCopyColorSpace(id).isWideGamutRGB`).
  - `docs/KNOBS.md` satır 45.
  - **Kart `files:` listesi dışı tek dosya:** `MateBridgeHost/Session/StreamCoordinator.swift` (`logDisplayTransfer` içinde 2 satır: `wide_gamut`'u okuyup `logFields`'e geçirir). Kabul 6 (`ev=vd_transfer`'e `wide_gamut`) başka türlü yazılamıyordu. `VideoPipeline.swift` ve `DisplayEDR.swift`'e dokunulmadı.
- **Varsayımlar:**
  - KVC ile `NSValue(point:)` yazmak `CGPoint` özelliğine `sizeInMillimeters`'taki gibi çalışır ([Tahmin]; cihazda ilk HDR kurulumunda `ev=vd_transfer primaries=p3 wide_gamut=1` görülmeli).
  - Açık `MATEBRIDGE_VD_PRIMARIES=p3` SDR ekranı (requested 0) P3 yapmaz: P3 yalnız `transfer.requested != 0` ekranda (kabul 2, SDR bit bit aynı). `p3` anahtarı bu yüzden otomatik davranışla aynıdır; `default` HDR'de kapatır.
  - `DisplayMode.primaries` **istenen** seçimi taşır (uygulanan değil); seçici eksikse ekran her pipeline başlangıcında yeniden kurulmasın diye.
  - SDR ↔ HDR10 geçişi ekranı yeniden kurmaya devam eder (`DisplayReuse` transfer farkı; testle doğrulandı: `testSDRHDRSwitchStillRecreatesTheDisplay`). Primerler `tf` ile aynı anda değiştiği için ayrı bir yeniden kurma yolu yok.
  - `tf=1` reddedilirse ekran P3 primerli SDR kalır, `ev=vd_transfer applied=0 primaries=p3` yazılır, ek yeniden kurma yok (`testLogFieldsTransferFallbackKeepsP3`).
  - `VirtualDisplay` ortam anahtarını kendisi okur (VideoPipeline değiştirilmedi); `VideoSettings.vdPrimariesKnob` aynı süreç ortamından okunur, ikisi üretimde aynı değeri görür.
- **Test edilmeyenler (cihaz/Mac gerekir, ben host çalıştırmadım, sanal ekran kurmadım):**
  - Gerçek `CGVirtualDisplay`'de `redPrimary`… özelliklerinin kabulü ve `wide_gamut=1` çıkması (ICC denemesiyle tutarlı beklenti).
  - Araştırma §4 ortak doğrulama: salt okuma sorgusunda `MTShould=1`, `canRepresent(.p3)=true`; Safari'yi tamamen kapatıp yeni sekmede YouTube HDR dişli menüsü.
  - HDR10 akışta masaüstü renkleri (P3 birleştirme, önce/sonra), SDR akışta değişiklik olmadığı (primer verilmez).
  - Kullanıcı Ekranlar'da Display P3 profilini elle atadıysa o öncelikli olabilir; deneyden önce profil "Display" varsayılanına döndürülmeli, yoksa `wide_gamut=1` yanlış olumlu verir.
  - `wide_gamut` okumasının 0,5 s gecikmesi yeterli mi (log `na`/`0` çıkarsa gecikme artırılır).
- `docs/LOGGING.md` (kartın `files:` listesinde yok) `ev=vd_transfer` alan listesini güncellemedi; orkestratör eklemeli: `primaries=`, `primaries_fallback=`, `primaries_reason=`, `wide_gamut=`.

## Open questions

- `StreamCoordinator.swift` düzenlemesi `files:` dışındaydı (yukarıda gerekçe); kabul edilmezse `wide_gamut` okuması `VideoPipeline`/`StreamCoordinator` dışında bir yere taşınmalı (mümkün değil: log noktası orası).
- `docs/LOGGING.md` güncellemesi orkestratörde.

- Orkestratör: `StreamCoordinator.swift` (`logDisplayTransfer`, 2 satır) kapsam dışı düzenlemesi kabul edildi; LOGGING.md güncellendi.
