---
id: T-130
title: Mac — uygulama ikonu ve menü çubuğu simgesi (öneri C "M çizgisi")
status: review
phase: 5
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Resources/
  - host-mac/Sources/MateBridgeApp/main.swift
  - scripts/bundle-host.sh
  - scripts/make-mac-icon.swift
  - backlog/tasks/T-130-host-app-icon.md
---

## Amaç

Kullanıcı 2026-10-02'de ikon önerisi **C "M çizgisi"**ni seçti. Ana geometri ve renkler: `docs/design/icon-master.svg` (yorum satırında tüm ölçüler). Şu an menü çubuğunda metin "MateBridge" var, uygulamanın ikonu yok.

## Kabul kriterleri

- [x] `scripts/make-mac-icon.swift` (yalnız sistem çerçeveleri: CoreGraphics/AppKit/ImageIO; bağımlılık yok) ana SVG'deki geometriyi kodda çizer ve `host-mac/Resources/AppIcon.icns` üretir (`iconutil`; 16…1024, @1x/@2x). Mac ikon ızgarası: 1024 tuvalde ortalı ~824 px yuvarlatılmış kare (köşe yarıçapı ~%22,5; macOS 26+ simge tablası ile uyumlu, dışı saydam), gradyan ve glif ana SVG oranlarıyla. Üretilen `.icns` commit edilir; betik yeniden üretilebilir (aynı girdi → aynı çıktı, tarih/rastgelelik yok).
- [x] `Info.plist`'e `CFBundleIconFile = AppIcon`; `bundle-host.sh` `.icns`'i `Contents/Resources`'a kopyalar. Uygulama Finder / Etkinlik Monitörü / izin pencerelerinde bu ikonla görünür.
- [x] Menü çubuğu: metin başlık yerine **template** `NSImage` (ana SVG'deki menü çubuğu ölçüleri: aynı yol, tam 100 kutusu, çizgi 10, nokta r 7,5), ~18 pt yükseklik, `isTemplate = true`, `accessibilityDescription = "MateBridge"`. Açık/koyu menü çubuğunda sistem rengiyle görünür. Menü içeriği ve davranışı değişmez.
- [x] `./scripts/check.sh` geçiyor.

## Kapsam dışı

Durum göstergesi (bağlı/bağlı değil simge değişimi) — gerekirse ayrı kart. Host'u çalıştırma (orkestratör bundle edip kullanıcıya gösterir).

## Plan

1. `scripts/make-mac-icon.swift` (CoreGraphics + ImageIO + Foundation): 1024 tuvalde (100,100)'den başlayan 824 px karo, Apple "continuous corner" Bezier yaklaşımıyla köşe yarıçapı 0,225·824 ≈ 185,4; dikey gradyan #121820 → #050608 (sRGB); glif ana SVG'deki `translate(17 17) scale(0.66)` ile 100'lük karo birimlerinden piksele (8,24 px/birim) eşlenir, çizgi 9, nokta r 6,75, renk #7FE0D0, yuvarlak uç/birleşim. Her boyut (16…512, @1x/@2x) vektörden doğrudan çizilir (küçültme yok), geçici `.iconset`e PNG yazılır, `iconutil -c icns` ile `host-mac/Resources/AppIcon.icns` üretilir. İsteğe bağlı `--preview DIR` 1024 PNG'yi de bırakır. Tarih/rastgelelik yok; iki çalıştırmada hash aynı olmalı.
2. `Info.plist`: `CFBundleIconFile = AppIcon`. `bundle-host.sh`: `AppIcon.icns`'i `Contents/Resources`'a kopyalar (imzalamadan önce).
3. `main.swift`: `button.title` yerine 18×18 pt template `NSImage` (çizim kapanışı, flipped, 100 kutusu → 18 pt; aynı yol, çizgi 10, nokta r 7,5; siyah dolgu/çizgi), `isTemplate = true`, `accessibilityDescription = "MateBridge"`. Menü dokunulmaz.
4. Önizleme: 1024 ikon, 16/32 px ve menü glifi (18 pt @1x/@2x, açık/koyu zemin) scratch'te PNG olarak çizilip gözle kontrol.
5. `./scripts/check.sh`, commit.

## Handoff

- **Commit:** `77c5136` (uygulama) + plan `143715b`; bu handoff ayrı commit. Dal: `task/T-130-host-app-icon`.
- **Dosyalar:** `scripts/make-mac-icon.swift` (yeni, çalıştırılabilir), `host-mac/Resources/AppIcon.icns` (yeni, üretilmiş, 365 KB, 10 temsil 16…512 @1x/@2x), `host-mac/Resources/Info.plist` (`CFBundleIconFile = AppIcon`), `scripts/bundle-host.sh` (`.icns`'i imzadan önce `Contents/Resources`'a kopyalar), `host-mac/Sources/MateBridgeApp/main.swift` (`menuBarGlyph()` + `button.image`, `imagePosition = .imageOnly`; menü değişmedi).
- **Yeniden üretim:** `swift scripts/make-mac-icon.swift [--out X.icns] [--preview DIR]`. İki çalıştırma bayt bayt aynı `.icns` verdi (sha1 `3b1ec44f…`). Her boyut vektörden doğrudan çizilir.
- **Varsayımlar:** Karo köşesi Apple "continuous corner" Bezier yaklaşımı (yaygın PaintCode katsayıları), r = 0,225·824 ≈ 185 px; gölge yok, dışı saydam (karttaki gibi). Gradyan karonun üst→alt kenarına göre, sRGB. Menü glifi 18×18 pt, tam 100 kutusu (kart gereği); görünür glif ≈ 14,5×10 pt ve kutunun biraz altında (yol y 25…81,5) — çubukta yeterli göründü ama küçük gelirse kutu kırpılabilir (ayrı karar).
- **Gözle kontrol (scratch PNG):** 1024 ikon ana SVG ile örtüşüyor (nokta merkezi ≈ (697, 642) hesapla aynı); 16/32 px okunaklı; menü glifi açık/koyu simüle çubukta @1x/@2x doğru yönde ve doğru renkte.
- **Test edilmedi:** Uygulama çalıştırılmadı/bundle edilmedi (kart gereği). Gerçek menü çubuğunda (açık/koyu, vurgulu durum) görünüm; Finder / Etkinlik Monitörü / izin pencerelerinde ikon; macOS 27'nin eski `.icns`'i "gri tabla" içine alıp almadığı (karo şekli Apple ızgarasına uyuyor ama Icon Composer `.icon` değil). Finder ikon önbelleği eski ikonu gösterebilir (`touch build/MateBridge.app` veya `killall Dock`).
- **Open questions:** yok.
