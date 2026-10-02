---
id: T-130
title: Mac — uygulama ikonu ve menü çubuğu simgesi (öneri C "M çizgisi")
status: todo
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

- [ ] `scripts/make-mac-icon.swift` (yalnız sistem çerçeveleri: CoreGraphics/AppKit/ImageIO; bağımlılık yok) ana SVG'deki geometriyi kodda çizer ve `host-mac/Resources/AppIcon.icns` üretir (`iconutil`; 16…1024, @1x/@2x). Mac ikon ızgarası: 1024 tuvalde ortalı ~824 px yuvarlatılmış kare (köşe yarıçapı ~%22,5; macOS 26+ simge tablası ile uyumlu, dışı saydam), gradyan ve glif ana SVG oranlarıyla. Üretilen `.icns` commit edilir; betik yeniden üretilebilir (aynı girdi → aynı çıktı, tarih/rastgelelik yok).
- [ ] `Info.plist`'e `CFBundleIconFile = AppIcon`; `bundle-host.sh` `.icns`'i `Contents/Resources`'a kopyalar. Uygulama Finder / Etkinlik Monitörü / izin pencerelerinde bu ikonla görünür.
- [ ] Menü çubuğu: metin başlık yerine **template** `NSImage` (ana SVG'deki menü çubuğu ölçüleri: aynı yol, tam 100 kutusu, çizgi 10, nokta r 7,5), ~18 pt yükseklik, `isTemplate = true`, `accessibilityDescription = "MateBridge"`. Açık/koyu menü çubuğunda sistem rengiyle görünür. Menü içeriği ve davranışı değişmez.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

Durum göstergesi (bağlı/bağlı değil simge değişimi) — gerekirse ayrı kart. Host'u çalıştırma (orkestratör bundle edip kullanıcıya gösterir).

## Plan

(ajan doldurur)

## Handoff

(ajan doldurur)
