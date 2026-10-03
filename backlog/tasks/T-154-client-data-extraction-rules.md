---
id: T-154
title: Exclude app data from device-to-device and cloud transfer
status: todo
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/AndroidManifest.xml
  - client-android/app/src/main/res/xml/data_extraction_rules.xml
  - backlog/tasks/T-154-client-data-extraction-rules.md
---

## Amaç

The app sets `android:allowBackup="false"` to keep its data on this tablet, but with `targetSdk = 31` that no longer blocks Android 12+ device-to-device transfer. A phone-clone style transfer could copy the cleartext `device_id` and settings to another device, which then presents itself to the Mac as the paired tablet. This card adds explicit data-extraction rules that exclude all of the app's preferences from both cloud backup and device transfer, so the backup policy matches its intent.

Source: external architecture review 2026-10-03 (SE1); verification: docs/reviews/2026-10-03/verify-A-security.md (SE1 correction, additional issue A5) and docs/reviews/2026-10-03/verify-A2-adversarial.md (§4).

## Bağlam

- **Evidence (HEAD a30c769):**
  - `client-android/app/build.gradle.kts:14` `targetSdk = 31` (`minSdk = 29`, :13). `client-android/app/src/main/AndroidManifest.xml:17` `android:allowBackup="false"`; there is no `android:dataExtractionRules` or `android:fullBackupContent`, and `client-android/app/src/main/res/xml/` does not exist.
  - Android 12 behaviour change for apps targeting 31+: `allowBackup="false"` still disables cloud backup but no longer disables device-to-device (D2D) transfer; excluding D2D needs `android:dataExtractionRules` with a `<device-transfer>` section.
  - Preference files in use: `matebridge` (settings and `device_id`, `MainActivity.kt:454`), `matebridge_pairkeys` (Keystore-wrapped pair keys, `MainActivity.kt:474`; after T-150 also pending records), `matebridge_audio` (`audio/SharedPrefsOutBufStore.kt:21`, `audio/SharedPrefsSafetyStore.kt:24`).
- **Impact if left alone (Low):** wrapped pair keys do not unwrap on another device (KEY_MISSING), but the clear `device_id` migrates; the new device then gets a PAIRED answer from the Mac, which before T-152 also triggered one pre-proof `sessionStarted`. Whether HarmonyOS 4.3 (Huawei Phone Clone) follows AOSP D2D semantics is unknown (manifest §5 Q17).
- **Plan hints:** `data_extraction_rules.xml` with `<cloud-backup>` and `<device-transfer>`, each excluding `domain="sharedpref" path="."` (all preference files, including future ones); excluding `file`, `database` and `root` too is acceptable and simpler to reason about. Keep `allowBackup="false"` (it still governs API 29/30 devices). If lint asks for `fullBackupContent` because `minSdk < 31`, `allowBackup="false"` already covers those versions; suppress with a comment rather than adding a second rules file.
- Batched into D2 per the coordinator although it is Low. No wire change; `docs/PROTOCOL.md` is not affected.

## Kapsam dışı

- Changing what is stored or how keys are wrapped; any runtime behaviour.

## Kabul kriterleri

- [ ] [build] `AndroidManifest.xml` sets `android:dataExtractionRules="@xml/data_extraction_rules"` and keeps `android:allowBackup="false"`.
- [ ] [build] `data_extraction_rules.xml` excludes all shared preferences (`matebridge`, `matebridge_pairkeys`, `matebridge_audio`) from both `<cloud-backup>` and `<device-transfer>`.
- [ ] [build] `./gradlew assembleDebug` passes, and `aapt2 dump xmltree --file AndroidManifest.xml <app-debug.apk>` shows the `dataExtractionRules` attribute on `<application>` (output quoted in Handoff).
- [ ] [device] Not verifiable on the tablet (would need a HarmonyOS Phone Clone transfer to a second device): state "not run" in Handoff.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
