---
id: T-386
title: İstemci — BuildConfig.GIT_SHA/BUILD_TIME_UTC artımlı derlemede eskide kalmasın
status: done
phase: 7
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/build.gradle.kts
  - client-android/app/src/main/kotlin/dev/matebridge/client/BuildInfo.kt
  - client-android/app/src/test/
  - backlog/tasks/T-386-client-buildconfig-sha-stale.md
---

## Amaç

NOTES 2026-10-27: daily 50df229e kuruluyken `app_start sha=8f56a36b built=2026-10-25` loglandı (versionName doğru: 0.1-50df229e). `clean` sonrası doğru. Olası sebep: `BuildConfig.GIT_SHA` / `BUILD_TIME_UTC` Java `static final String` sabitleri; Kotlin derleyicisi bunları `BuildInfo.kt`'ye satır içi gömüyor ve artımlı derleme `BuildInfo.kt`'yi yeniden derlemiyor. Tam renk öz testinin build anahtarı (`sha@builtUtc`) buna bağlı, bu yüzden yeni APK'da test yeniden koşmadı.

## Kabul

1. Sebep doğrulanır (Plan'da kanıt: ör. iki ardışık commit arasında artımlı `assembleDaily` + dex'te sabit; ya da Gradle görev girdileri).
2. Düzeltme: değerler satır içi gömülemeyecek bir yoldan okunur (ör. BuildConfig alanı yerine `resValue`/asset, ya da Kotlin tarafında sabit gömmeyi engelleyen okuma) veya derleme girdisi doğru bağlanır. Configuration cache geçerli kalır (T-301 notu).
3. Doğrulama: commit A'da `assembleDaily`, boş bir commit B, `clean` OLMADAN `assembleDaily` → APK'daki sha = B. Komutlar Handoff'ta.
4. `./scripts/check.sh` geçer. Cihaza kurulmaz.

## Plan

1. Sebebi baz kodda yeniden uret: A'da `assembleDaily`, bos commit B, `clean` olmadan `assembleDaily`, APK dex'inde sha'ya bak.
2. Duzeltme: BuildConfig alanlarinin Java ifadesi sabit olmayan `new String("...")` olur; derleyici bunu compile-time constant saymaz, bu yuzden BuildInfo.kt'ye gomulmez, her zaman BuildConfig sinifindan okunur. Gradle girdileri/configuration cache degismez.
3. Ayni A / bos commit B / clean'siz build dizisini duzeltmeyle tekrarla (JVM testinde sabit gomme gozlenemez; mevcut BuildInfoTest davranisi korur).
4. check.sh.

## Handoff

- Kod commit: 41b3975a (fix); plan d0cbca6b. Dosya: `client-android/app/build.gradle.kts` (BuildInfo.kt ve testler degismedi).
- Sebep: javap ile dogrulandi: baz kodda `BuildInfo.class` SHA ve zamani `ldc` ile gomulu tutuyor (BuildConfig.GIT_SHA/BUILD_TIME_UTC `static final String` literal = compile-time constant). Baz kodda eski-sha belirtisi bu makinede yeniden uretilemedi (A -> bos commit B -> clean'siz build: B dogru cikti; Kotlin IC o durumda BuildInfo'yu yeniden derledi). Yani gomme mekanizmasi kanitli, stale tetikleyicisi IC durumuna bagli ve burada tetiklenmedi.
- Duzeltme: BuildConfigField degeri `new String("...")` (sabit degil) -> javap: `getstatic BuildConfig.GIT_SHA/BUILD_TIME_UTC`, BuildInfo'ya gomulmez. Configuration cache/girdiler degismedi. Not: `VERSION_NAME` AGP'nin urettigi literal olarak kaliyor (hala gomulur); loglarda versionName hep dogruydu, dokunulmadi.
- Dogrulama (client-android icinde, ANDROID_HOME/JAVA_HOME ayarli): commit A -> `./gradlew assembleDaily`; `git commit --allow-empty -m x` (B); `./gradlew assembleDaily` (clean YOK); `unzip -p app/build/outputs/apk/daily/*.apk 'classes*.dex' | grep -a -c <A>` = 0, B bulunur. Sonuc fix ile: A=41b3975a, B=fdfd0080 -> APK'da yalniz B.
- Branch'te iki dogrulama bos commit'i var (1589953f baz tekrar, fdfd0080 fix kontrol).
- check.sh: ALL OK. Cihaza kurulmadi.
- Tablette: yeni daily kurup sonraki artimli build'den sonra `app_start sha=` degeri HEAD SHA ile eslesmeli.

## Open questions
