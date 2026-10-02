---
id: T-131
title: Tablet — uygulama ikonu (öneri C "M çizgisi", adaptive icon)
status: review
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

- [x] Adaptive icon (`mipmap-anydpi-v26/ic_launcher.xml` + `ic_launcher_round.xml`): arka plan = dikey gradyan vektör (üst `#121820` → alt `#050608`), ön plan = glif vektörü (ana SVG yolu aynen `pathData`, çizgi `#7FE0D0`, round cap/join, uçta dolu nokta). 108 dp tuvalde görünür alan 72 dp = ana SVG'deki 100 birimlik karo; glif bu oranla ölçeklenir (karo 100 → glif 66 birim) ve 66 dp güvenli dairenin içinde kalır. `monochrome` katmanı (aynı glif) eklenir.
- [x] `minSdk` < 26 ise eski cihazlar için yoğunluk başına PNG mipmap'leri (vektörden; elle çizim yok) ya da vektör `drawable` yedeği; seçimini Handoff'ta yaz. Yeni bağımlılık yok.
- [x] Manifest: `android:icon="@mipmap/ic_launcher"`, `android:roundIcon="@mipmap/ic_launcher_round"`.
- [x] `./scripts/check.sh` geçiyor (lint dahil). — check.sh ALL OK; lint: ikon için yeni uyarı yok, ancak önceden var olan 2 hata var (bkz. Open questions).

## Kapsam dışı

Cihaza kurulum ve HarmonyOS ana ekranındaki görünüm (orkestratör kurar, kullanıcı bakar; Huawei kendi maskesini uygulayabilir).

## Plan

- `minSdk = 29` (≥ 26) → yalnızca adaptive icon; PNG mipmap / legacy yedek gerekmez.
- `res/drawable/ic_launcher_background.xml`: 108×108 vektör, tam kare, `aapt:attr` lineer gradyan `#121820` → `#050608`; gradyan y=18→90 (görünür 72 dp karo = ana SVG'deki 100 birimlik karo), dışı clamp.
- `res/drawable/ic_launcher_foreground.xml`: 108×108 vektör; `<group>` dönüşümü glif birimini tuvale taşır: karo ofseti 18 + ölçek 0,72 dp/birim, glif `translate(17 17) scale(0.66)` → toplam `translate = 18 + 0,72·17 = 30,24`, `scale = 0,72·0,66 = 0,4752`. Yol ana SVG'den aynen; çizgi `#7FE0D0`, genişlik 9 (grup ölçeği uygulanır → 4,28 dp), round cap/join; uçta r = 6,75 dolu daire (yay komutlarıyla). Güvenli daire kontrolü: en uzak nokta merkezden ≈ 23 dp < 33 dp.
- `res/mipmap-anydpi/ic_launcher.xml` (ilk planda `-v26`; lint `ObsoleteSdkInt` verdiği için niteleyicisiz klasöre taşındı, minSdk 29'da davranış aynı) ve `ic_launcher_round.xml`: background + foreground + `monochrome` (= foreground).
- Manifest: `android:icon`, `android:roundIcon`.
- Doğrulama: `./scripts/check.sh` + `./gradlew lintDebug` (yeni lint uyarısı yok).

## Handoff

- **Commit:** `task/T-131-client-app-icon` dalının ucu (plan commit'i `8a91a1e`, uygulama commit'i onun hemen ardından; SHA orkestratöre raporlandı).
- **Dokunulan dosyalar:**
  - `client-android/app/src/main/res/drawable/ic_launcher_background.xml` (yeni)
  - `client-android/app/src/main/res/drawable/ic_launcher_foreground.xml` (yeni; foreground + monochrome)
  - `client-android/app/src/main/res/mipmap-anydpi/ic_launcher.xml`, `ic_launcher_round.xml` (yeni)
  - `client-android/app/src/main/AndroidManifest.xml` (`android:icon`, `android:roundIcon`)
  - bu kart
- **Yedek seçimi:** `minSdk = 29` ≥ 26 olduğu için PNG mipmap veya legacy drawable yedeği **yok**; tüm cihazlar adaptive icon'u kullanır. Yeni bağımlılık yok.
- **Klasör sapması:** kart `mipmap-anydpi-v26` diyor, ancak lint minSdk 29'da bunu `ObsoleteSdkInt` olarak işaretlediği için `mipmap-anydpi` kullanıldı (işlevsel olarak aynı). aapt2 APK'da bunu `res/mipmap-anydpi-v21/ic_launcher.xml` olarak paketliyor (vektör için otomatik niteleyici). `aapt2 dump badging` çıktısı: `application: label='MateBridge' icon='res/mipmap-anydpi-v21/ic_launcher.xml'`.
- **Geometri:** grup `translate 30.24`, `scale 0.4752` (= 18 + 0.72·17 ve 0.72·0.66). Yol ana SVG'den birebir alındı; çizgi 9 birim (≈ 4,28 dp), nokta r 6,75 (≈ 3,21 dp). Glif tuvalde x ≈ 35,7–73,4 ve y ≈ 42,4–68,6 dp aralığını kaplıyor; merkezden en uzak nokta ≈ 23 dp, yani 33 dp'lik güvenli dairenin içinde. Gradyan y = 18→90 (görünür karo), dışı clamp.
- **Doğrulama:** `./scripts/check.sh` → ALL OK. check.sh lint çalıştırmadığı için `./gradlew lintDebug` elle çalıştırıldı: ikon, manifest ve res için yeni uyarı yok. Lint yine de **önceden var olan** 2 hata yüzünden başarısız oluyor (bkz. Open questions).
- **Test EDİLMEDİ:** cihaza kurulum, HarmonyOS ana ekranındaki görünüm, Huawei maskesi, monochrome/temalı ikon (HarmonyOS 4.3 bu katmanı büyük olasılıkla yok sayar).
- **Tablette kontrol:**
  1. Kurulumdan sonra ana ekrandaki MateBridge ikonu, sistem varsayılanı yerine koyu gradyan zemin üzerinde turkuaz "M çizgisi" ve sağ uçta bir nokta gösteriyor mu?
  2. Glif ortada mı ve Huawei'nin maskesinde kırpılmadan duruyor mu? Gradyan üstte hafif açık, altta neredeyse siyah mı?
  3. Son uygulamalar (recents) ekranında ve Ayarlar → Uygulamalar listesinde de aynı ikon görünüyor mu?
  4. Eski ikon önbellekte kalırsa uygulamayı kaldırıp yeniden kur.

## Open questions

- `./gradlew lintDebug`, bu dalla ilgisi olmayan önceden var olan 2 hata yüzünden başarısız oluyor. Bunlar kapsam dışı olduğu için dokunulmadı:
  - `MainActivity.kt:490`: `requestUnbufferedDispatch(InputDevice.SOURCE_STYLUS)` → `WrongConstant`
  - `app/build.gradle.kts:14` → `ExpiredTargetSdkVersion`
- Kabul kriterindeki "lint dahil" ifadesi gerçeği yansıtmıyor, çünkü `check.sh` lint çalıştırmıyor. Lint'in ayrı bir kartla check.sh'e eklenmesi ve bu iki hatanın düzeltilmesi ya da baseline'a alınması önerilir.
