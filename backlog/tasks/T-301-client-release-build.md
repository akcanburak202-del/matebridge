---
id: T-301
title: Tablet — günlük kullanım için debug olmayan profileable derleme (aynı imza) ve minSdk 31 (karar 0037)
status: review
phase: 7
owner: android-client-dev
depends_on: []
decisions: [0037]
files:
  - client-android/app/build.gradle.kts
  - client-android/app/src/main/AndroidManifest.xml
  - client-android/app/src/main/cpp/CMakeLists.txt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - scripts/install-apk.sh
  - scripts/check.sh
  - client-android/AGENTS.md (orchestrator)
  - backlog/tasks/T-301-client-release-build.md
---

## Amaç

Karar 0037 ve T-298 CB1 (`docs/reviews/2026-10-08/agents/opt-b-client.md`). Günlük APK bugün debug: ART debuggable modda, yerel kod -O0.

## Kabul

1. **Yeni derleme türü** (ad önerisi `daily`; `release` de olur, gerekçeyi Handoff'a yaz):
   - `isDebuggable=false`, `isMinifyEnabled=false` (R8 kapsam dışı);
   - debug imzalama yapılandırması, böylece kurulu debug uygulamasının üstüne yerinde güncellenir. Kaldırma gerekmez; eşleşme anahtarları korunur;
   - yerel kod Release ya da RelWithDebInfo.
2. **Manifest:** `<profileable android:shell="true"/>` (simpleperf çalışmaya devam eder).
3. **`applicationId` ve `versionCode` kuralı** (T-146, commit sayısı) iki türde aynıdır.
4. **minSdk = 31.** API < 31 dallarının silinmesi T-303'te; burada yalnız değer değişir ve derleme geçer.
5. **`scripts/install-apk.sh`:** varsayılan olarak yeni türün APK'sını kurar; `--debug` (ya da yol argümanı) ile debug APK kurulur. Huawei onay dokunuşları aynı kalır.
6. **`scripts/check.sh`:** iki türü de derler (ya da en azından yeni türü). Birim testleri değişmez.
7. **`decoder_fault`:** `FLAG_DEBUGGABLE` kontrolü (MainActivity ~263) korunur; debug olmayan türde hata enjeksiyonu kapalı kalır.
8. **Handoff:** iki APK'nın yolu, boyutu, imza kontrolü (`apksigner verify --print-certs`, debug APK ile aynı sertifika) ve "debug → yeni tür → debug" yerinde güncellemenin `adb install -r` ile mümkün olduğunu gösteren bir not. Cihazda kurulum orkestratörün işi.

## Plan

Yeni tür `daily` (debug'dan initWith; isDebuggable/isJniDebuggable=false, debug imzası), manifestte profileable, minSdk 31, check.sh assembleDaily, install-apk.sh varsayılan daily + `--debug`.

## Handoff

- Commit: bkz. `git log task/T-301-release-build -1`.
- Dosyalar: build.gradle.kts, AndroidManifest.xml, scripts/install-apk.sh, scripts/check.sh, bu kart. CMakeLists.txt ve MainActivity.kt değişmedi: `isJniDebuggable=false` yerel kodu Release derler; `FLAG_DEBUGGABLE` kontrolü (decoder_fault) aynen duruyor, daily'de kapalı kalır.
- Tür adı `daily` (niyeti söylüyor; "release" Play/imza beklentilerini çağrıştırır).
- APK'lar (client-android/app/build/outputs/apk/): `debug/app-debug.apk` 5270903 B; `daily/app-daily.apk` 4055377 B. İkisi de aynı applicationId, minSdk 31, targetSdk 31.
- İmza: `apksigner verify --print-certs` iki APK için aynı sertifika, SHA-256 a8d0f914679da68aeb060954459feccb33b9c7d44dd75df3369cc291f54f734f. Bu yüzden debug → daily → debug `adb install -r -d` ile yerinde güncellenir (eşleşme anahtarları korunur).
- Ek: `lint { checkReleaseBuilds = false }` eklendi; yoksa lintVitalDaily bilinçli targetSdk 31'de ExpiredTargetSdkVersion (Play kuralı, uygulama sideload) ile derlemeyi kırar.
- `client-android/AGENTS.md` hâlâ "minSdk 29" diyor (kapsam dışı; orkestratör güncellesin).
- check.sh: ALL OK.
- Tablette kontrol: `scripts/install-apk.sh` (daily) debug üstüne kurulur ve eşleşme korunur mu; `dumpsys package dev.matebridge.client | grep -i flags` içinde DEBUGGABLE yok; `run-as` başarısız olmalı; simpleperf shell'den çalışmalı (profileable); `--debug` ile geri dönüş; decoder_fault daily'de etkisiz; 60 fps akış normal.

## Open questions

### Review turu 1 (Codex P2 x2)

- check.sh: `assembleDaily` yalnız client-android için istenir (probe'larda `daily` yok).
- versionCode artık derleme zamanı dakikası (2026-01-01 UTC'den beri), commit sayısı değil: debug olmayan uygulamada sürüm düşürme yapılamaz (`-d` yetmez) ve worktree dalları main'den az commit'e sahip. Böylece yeni derleme her zaman eskinin üstüne kurulur; eski bir APK'yı sonradan geri kurmak yine düşürmedir, yeniden derlemek gerekir. Commit SHA `versionName` ("0.1-<sha>"), `BuildConfig.GIT_SHA` ve `app_start`'ta kalır. T-146 kartındaki "versionCode = commit sayısı" bu kartla geçersizdir; ona bağlı test yok. Handoff'taki "iki yönlü yerinde güncelleme" iddiası bu sınırla okunmalı.
- install-apk.sh: VERSION_DOWNGRADE için açık mesaj. `client-android/AGENTS.md` minSdk 31 (orkestratör izniyle).
