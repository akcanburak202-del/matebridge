---
id: T-146
title: Log and show the client build commit
status: review
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

- [x] [JVM] `BuildInfoTest`: `logFields()` has exactly the fields `version= sha= built= sdk= os_build=` in that order; an empty or missing SHA becomes `sha=unknown`.
- [x] [build] `./gradlew assembleDebug` succeeds from a copy of `client-android/` without `.git` (SHA `unknown`, `versionCode` 1).
- [x] [build] `versionCode` follows the commit count when git is available (`aapt2 dump badging` output quoted in Handoff); `versionName` stays human-readable.
- [ ] [device] `adb logcat -s 'MB/*'` shows exactly one `ev=app_start version= sha= built= sdk= os_build=` line per cold start, and the settings panel "Sürüm" row shows the same SHA. No serial number and no device ID appear in the line.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. `build.gradle.kts`: `buildFeatures { buildConfig = true }`. Git values come from one `ValueSource` (injected `ExecOperations`, `isIgnoreExitValue`, exceptions caught) so a tree without `.git` or without a `git` binary falls back instead of failing. They are wired lazily in `androidComponents.onVariants`: `GIT_SHA` (`git rev-parse --short HEAD`, `-dirty` when `git status --porcelain` is non-empty, else `unknown`), `BUILD_TIME_UTC` (`yyyy-MM-ddTHH:mmZ`), and every output's `versionCode` = `git rev-list --count HEAD` (fallback 1). Nothing runs at configuration time, so the configuration cache stays valid. `versionName` stays `"0.1"`.
2. `BuildInfo.kt`: pure class over the raw values (`versionName`, `sha`, `builtUtc`); `logFields(sdk, osBuild)` → `version=… sha=… built=… sdk=… os_build=…` (blank → `unknown`, whitespace inside a value → `_` so the key=value line stays parseable); `settingsText()` → `Sürüm: 0.1 (<sha>, <built>)`; `BuildInfo.current` reads `BuildConfig`.
3. `MainActivity.onCreate`: one `MbLog.i("app_start", BuildInfo.current.logFields(Build.VERSION.SDK_INT, Build.DISPLAY))` right after `super.onCreate`, before the bench redirect, guarded by `BuildInfo.claimAppStart()` (process-wide once flag) so an activity recreation does not log it again.
4. `SettingsCatalog`: `SettingItem.Info("version") { BuildInfo.current.settingsText() }` as the last row of "Diğer".
5. `BuildInfoTest`: field order, `unknown` fallback, whitespace, settings text.
6. Verify: `./scripts/check.sh`, `aapt2 dump badging` for `versionCode`, `assembleDebug` from a copy of `client-android/` outside the repo.

Risk: the new "version" row changes the key list asserted in `SettingsCatalogTest.kt`, which is not in `files:` (see *Açık sorular*).

## Handoff

- **Commit:** `1e16cc2` (implementation), `bcace59` (settings test key list), plan `1acc430`; branch `task/T-146-client-build-identity`. The card update is the last commit on the branch.
- **Dokunulan dosyalar:**
  - `client-android/app/build.gradle.kts`: `buildConfig = true`; `BuildIdentity` `ValueSource` (git via `ExecOperations`, `isIgnoreExitValue`, exceptions → fallback); `androidComponents.onVariants` sets `GIT_SHA`, `BUILD_TIME_UTC` and `versionCode` lazily.
  - `client-android/app/src/main/kotlin/dev/matebridge/client/BuildInfo.kt` (new): `logFields(sdk, osBuild)`, `settingsText()`, `current`, `claimAppStart()`.
  - `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt`: one line (+comment) after `super.onCreate`.
  - `client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsCatalog.kt`: `Info("version")` as the last "Diğer" row, plus its import.
  - `client-android/app/src/test/kotlin/dev/matebridge/client/BuildInfoTest.kt` (new).
  - **Outside `files:`:** `client-android/app/src/test/kotlin/dev/matebridge/client/settings/SettingsCatalogTest.kt`, one line: `"version"` appended to the expected key list. Without it check.sh fails, because the test pins every settings key. It is kept in its own commit (`bcace59`) so it can be reviewed or dropped separately.
- **Doğrulama (Mac):**
  - `./scripts/check.sh`: ALL OK at `bcace59`.
  - `aapt2 dump badging` at `bcace59` (`git rev-list --count HEAD` = 880): `package: name='dev.matebridge.client' versionCode='880' versionName='0.1' platformBuildVersionName='17' platformBuildVersionCode='37' compileSdkVersion='37' compileSdkVersionCodename='17'`. `BuildConfig`: `GIT_SHA = "bcace59"`, `BUILD_TIME_UTC = "2026-10-03T16:44Z"`. A dirty tree gave `1acc430-dirty`.
  - A copy of `client-android/` in the scratchpad (no `.git` above it): `assembleDebug` OK, `versionCode='1'`, `GIT_SHA = "unknown"`. In the same copy, `--configuration-cache assembleDebug` stored the entry and reused it on the second run.
- **Varsayımlar:**
  - `versionName` stays `"0.1"`. The SHA and the commit count identify the build.
  - `built=` is UTC at minute precision (`2026-10-03T16:44Z`). It changes on every build in a new minute, so `BuildConfig` and its users recompile then (small cost).
  - `os_build` = `Build.DISPLAY`. Whitespace inside any value becomes `_`, and blank becomes `unknown`, so each value stays one key=value token.
  - "Exactly one per cold start" is enforced per process (`BuildInfo.claimAppStart()`, an atomic once flag). An activity recreation, and the `net_bench` redirect after the line, do not log it again.
  - The dirty check covers the whole repo (`git status --porcelain`, untracked files included).
  - **Version downgrade:** daily APKs now have `versionCode` ≈ 880+. A fallback build (`versionCode` 1, no `.git`) or a shallow-clone CI APK with a small count fails with `adb install -r` (`INSTALL_FAILED_VERSION_DOWNGRADE`). If it really has to be installed, use `adb install -r -d`. **Never uninstall to work around it**: uninstalling deletes `matebridge_pairkeys`, which loses the pairing. The first install of this branch over the current APK (`versionCode` 1) is an upgrade, so plain `-r` works.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  1. `adb install -r` the branch APK (an upgrade from 1, no `-d` needed). Check that pairing is still there.
  2. Cold start (`am force-stop dev.matebridge.client`, then launch). `adb logcat -s 'MB/*'` shows exactly one `I session … ev=app_start version=0.1 sha=<sha> built=<…Z> sdk=<n> os_build=<Build.DISPLAY>` line. Check what `os_build` looks like on HarmonyOS 4.3. No serial, ANDROID_ID or host name.
  3. Rotate, attach or detach the keyboard, or toggle dark mode. No second `app_start` line until the next cold start.
  4. Settings panel, both connect and in-stream: the last "Diğer" row reads `Sürüm: 0.1 (<same sha>, <built>)`.
- **Açık sorular:**
  - `SettingsCatalogTest.kt` is not in `files:` but had to change (see above). Accept `bcace59` or tell me the alternative.
  - `docs/LOGGING.md` needs the `I session ev=app_start version= sha= built= sdk= os_build=` line (orchestrator).
