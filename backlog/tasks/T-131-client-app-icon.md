---
id: T-131
title: Tablet — uygulama ikonu (öneri C "M çizgisi", adaptive icon)
status: in-progress
phase: 5
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/res/
  - client-android/app/src/main/AndroidManifest.xml
  - backlog/tasks/T-131-client-app-icon.md
---

## Amaç

Kullanıcı 2026-10-02'de ikon önerisi **C "M çizgisi"**ni seçti. Ana geometri ve renkler: `docs/design/icon-master.svg` (yorum satırında tüm ölçüler). Şu an uygulamanın ikonu yok (sistem varsayılanı).

## Kabul kriterleri

- [ ] Adaptive icon (`mipmap-anydpi-v26/ic_launcher.xml` + `ic_launcher_round.xml`): arka plan = dikey gradyan vektör (üst `#121820` → alt `#050608`), ön plan = glif vektörü (ana SVG yolu aynen `pathData`, çizgi `#7FE0D0`, round cap/join, uçta dolu nokta). 108 dp tuvalde görünür alan 72 dp = ana SVG'deki 100 birimlik karo; glif bu oranla ölçeklenir (karo 100 → glif 66 birim) ve 66 dp güvenli dairenin içinde kalır. `monochrome` katmanı (aynı glif) eklenir.
- [ ] `minSdk` < 26 ise eski cihazlar için yoğunluk başına PNG mipmap'leri (vektörden; elle çizim yok) ya da vektör `drawable` yedeği; seçimini Handoff'ta yaz. Yeni bağımlılık yok.
- [ ] Manifest: `android:icon="@mipmap/ic_launcher"`, `android:roundIcon="@mipmap/ic_launcher_round"`.
- [ ] `./scripts/check.sh` geçiyor (lint dahil).

## Kapsam dışı

Cihaza kurulum ve HarmonyOS ana ekranındaki görünüm (orkestratör kurar, kullanıcı bakar; Huawei kendi maskesini uygulayabilir).

## Plan

- `minSdk = 29` (≥ 26) → yalnızca adaptive icon; PNG mipmap / legacy yedek gerekmez.
- `res/drawable/ic_launcher_background.xml`: 108×108 vektör, tam kare, `aapt:attr` lineer gradyan `#121820` → `#050608`; gradyan y=18→90 (görünür 72 dp karo = ana SVG'deki 100 birimlik karo), dışı clamp.
- `res/drawable/ic_launcher_foreground.xml`: 108×108 vektör; `<group>` dönüşümü glif birimini tuvale taşır: karo ofseti 18 + ölçek 0,72 dp/birim, glif `translate(17 17) scale(0.66)` → toplam `translate = 18 + 0,72·17 = 30,24`, `scale = 0,72·0,66 = 0,4752`. Yol ana SVG'den aynen; çizgi `#7FE0D0`, genişlik 9 (grup ölçeği uygulanır → 4,28 dp), round cap/join; uçta r = 6,75 dolu daire (yay komutlarıyla). Güvenli daire kontrolü: en uzak nokta merkezden ≈ 23 dp < 33 dp.
- `res/mipmap-anydpi-v26/ic_launcher.xml` ve `ic_launcher_round.xml`: background + foreground + `monochrome` (= foreground).
- Manifest: `android:icon`, `android:roundIcon`.
- Doğrulama: `./scripts/check.sh` + `./gradlew lintDebug` (yeni lint uyarısı yok).

## Handoff

(ajan doldurur)
