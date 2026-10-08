---
id: T-301
title: Tablet — günlük kullanım için debug olmayan profileable derleme (aynı imza) ve minSdk 31 (karar 0037)
status: todo
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

## Handoff

## Open questions
