---
id: T-281
title: Host — HDR sanal ekranı Display P3 primerleriyle kur (Safari/YouTube HDR)
status: in_progress
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

## Open questions
