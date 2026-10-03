---
id: T-146
title: Log and show the client build commit
status: todo
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/build.gradle.kts
  - client-android/app/src/main/kotlin/dev/matebridge/client/BuildInfo.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsCatalog.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/BuildInfoTest.kt
  - backlog/tasks/T-146-client-build-identity.md
---

## Amaç

The APK carries `versionCode = 1` and `versionName = "0.1"` forever, and no log line names the build, so a tablet log cannot be tied to a commit. Measurement, soak and recovery records (T-147, T-173, T-194) must name the exact client build. After this card every client log starts with one `app_start` line carrying the commit SHA and build time, and the settings panel shows the same SHA.

Source: external architecture review 2026-10-03 (L01, D1, M07); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (BUILDID-C, L01).

## Bağlam

- **Evidence (HEAD a30c769):**
  - `client-android/app/build.gradle.kts:15-16`: `versionCode = 1`, `versionName = "0.1"`. There is no `buildFeatures { buildConfig = true }`, and `grep BuildConfig` in `client-android/app/src/main` is empty (AGP 8+ disables BuildConfig by default).
  - `MainActivity.onCreate` starts at `MainActivity.kt:355`; nothing logs a version.
  - The settings panel is described once in `settings/SettingsCatalog.kt` (`sections(...)`, :132); a read-only row type already exists (`SettingItem.Info`, :116).
- **Plan hints:**
  - `build.gradle.kts`: `buildFeatures { buildConfig = true }`; `buildConfigField`s `GIT_SHA` (short SHA, `-dirty` when the tree is dirty), `BUILD_TIME_UTC`. Read git through `providers.exec { commandLine("git", "rev-parse", "--short", "HEAD"); isIgnoreExitValue = true }` so a tree without `.git` builds and falls back to `unknown`; keep it configuration-cache friendly (no eager `exec` at configuration time outside providers).
  - `versionCode` from the commit count (`git rev-list --count HEAD`), falling back to 1. Note: a shallow CI checkout (T-149) gives a small count; T-149 either fetches full history or accepts that the CI APK is not the daily APK.
  - A fallback build (`versionCode` 1, or a small shallow-clone count) must never be installed over a count-based APK: `adb install -r` fails with `INSTALL_FAILED_VERSION_DOWNGRADE`. If such an install is really needed, use `adb install -r -d`. **Never uninstall to work around it**: uninstalling deletes `matebridge_pairkeys`, i.e. the pairing. Record it in Handoff under *Varsayımlar*.
  - `BuildInfo.kt` (pure, testable): takes the raw values and formats `logFields()` = `version=… sha=… built=… sdk=… os_build=…` (`os_build` = `Build.DISPLAY`, `sdk` = `Build.VERSION.SDK_INT`, both passed in so the JVM test does not need Android).
  - `MainActivity.onCreate`: one `MbLog.i("app_start", BuildInfo.logFields(...))` near the top. Nothing else in `MainActivity.kt` changes.
  - `SettingsCatalog`: a `SettingItem.Info` "Sürüm: 0.x (<sha>, <built>)" row in the last ("Diğer") section.
  - **Privacy (AGENTS.md):** no serial number, no `ANDROID_ID`, no `device_id`, no host name in the line.
- **Serialize with:** T-150 and T-151 (same file `MainActivity.kt`; chain T-146 → T-150 → T-151 → T-153 → …) and T-151/T-191 (same file `SettingsCatalog.kt`). T-146 goes first.
- **Docs:** `docs/LOGGING.md` gets the `app_start` line from the orchestrator; list it under *Açık sorular*.
- No wire change; `docs/PROTOCOL.md` is not affected.

## Kapsam dışı

- Host side (T-145), any HELLO field (that would be a protocol change), release signing, a release build variant.

## Kabul kriterleri

- [ ] [JVM] `BuildInfoTest`: `logFields()` has exactly the fields `version= sha= built= sdk= os_build=` in that order; an empty or missing SHA becomes `sha=unknown`.
- [ ] [build] `./gradlew assembleDebug` succeeds from a copy of `client-android/` without `.git` (SHA `unknown`, `versionCode` 1).
- [ ] [build] `versionCode` follows the commit count when git is available (`aapt2 dump badging` output quoted in Handoff); `versionName` stays human-readable.
- [ ] [device] `adb logcat -s 'MB/*'` shows exactly one `ev=app_start version= sha= built= sdk= os_build=` line per cold start, and the settings panel "Sürüm" row shows the same SHA. No serial number and no device ID appear in the line.
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
